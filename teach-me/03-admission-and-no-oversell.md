# Chapter 3: Admission & the No-Oversell Transaction

This is the chapter the whole system exists for. Two pieces meet here: the **admission worker**
(control plane) that paces who gets let in, and the **claim transaction** (data plane) that turns an
admission into a confirmed reservation *without ever overselling a lobby*. The first is allowed to
be sloppy and crash; the second must be perfect under concurrency. Keeping those two standards
separate is the central design move.

## The worker: control plane, allowed to fail

The admission loop is a standalone process ([`lib/admission_loop.rb`](../backend/lib/admission_loop.rb)).
Every tick it sweeps published raids and calls
[`RaidQueue::AdmitBatch`](../backend/app/services/raid_queue/admit_batch.rb):

```ruby
# backend/app/services/raid_queue/admit_batch.rb:17
def call
  @raid.reload
  return drain_full if @raid.full? || @raid.status == "closed"

  batch = Admission::Pacing.batch_size(@raid.id)
  members = QueueRedis.with { |r| Array(r.zpopmin(QueueConfig.queue_key(@raid.id), batch)) }
  return { admitted: 0, drained: 0 } if members.empty?

  ids = members.map { |member, _score| member }
  QueueRedis.with do |r|
    r.pipelined do |p|
      ids.each { |id| p.set(QueueConfig.claimable_key(@raid.id, id), "1", ex: QueueConfig::CLAIM_WINDOW_SECONDS) }
      p.incrby(QueueConfig.metric_admitted_key(@raid.id), ids.size)
    end
  end
  ids.each { |id| publish(id, "admitted", claim_deadline: ..., claim_seconds_remaining: ...) }
  { admitted: ids.size, drained: 0 }
end
```

`ZPOPMIN` atomically removes the lowest-scored (earliest) `batch` members — FIFO admission for free.
Each admitted trainer gets a `claimable:{raid}:{trainer}` key with a TTL (the claim window), then an
`admitted` event is published over Redis pub/sub (Chapter 4 consumes it).

The "how many" comes from [`Admission::Pacing`](../backend/app/services/admission/pacing.rb), which is
the embodiment of concept #4:

```ruby
def self.batch_size(raid_id)
  QueueRedis.with do |r|
    v = r.get(QueueConfig.admission_rate_key(raid_id)).to_i
    v.positive? ? v : QueueConfig::ADMISSION_DEFAULT_BATCH
  end
rescue StandardError
  QueueConfig::ADMISSION_DEFAULT_BATCH   # never raises — fall back and keep going
end
```

A future adaptive controller would *write* `admission:rate:{raid}`; the worker only reads it, and if
the key is missing, unreadable, or Redis hiccups, it falls back to the default and keeps admitting.
The control plane influences the system but is never a hard dependency. (Chapter 7's simulator uses
this exact key to throttle admission and create deep queues.)

Crucially: **the worker does not reserve slots.** It only marks people "may claim." Capacity is
decided later, in the claim. That's why a worker crash is harmless — nothing it did is durable or
load-bearing for correctness.

## The claim: the invariant lives in Postgres

[`Reservations::Claim`](../backend/app/services/reservations/claim.rb) is the data plane. Its `call`
checks for an existing reservation *first* (idempotency), then the admitted gate, then runs the
transaction:

```ruby
# backend/app/services/reservations/claim.rb:25
def call
  record_metric(QueueConfig.metric_claims_key(@raid.id))

  existing = find_reservation
  return ServiceResult.success(code: :ok, reservation: existing, idempotent: true) if existing

  return ServiceResult.failure(code: :not_admitted) unless admitted?

  outcome = run_transaction
  # ...maps :created / :idempotent / :full to a ServiceResult
end
```

The idempotency-first ordering matters: a successful claim clears the admitted flag, so a retried
request would otherwise hit the gate and wrongly get `:not_admitted`. Checking for the existing
reservation before the gate makes replays return the same reservation. (This was a real bug found by
testing — see Chapter 6.)

Here is the invariant, all of it:

```ruby
# backend/app/services/reservations/claim.rb:69
def run_transaction
  outcome = nil
  ApplicationRecord.transaction do
    inserted = exec(<<~SQL, "claim_insert")
      INSERT INTO reservations (raid_id, trainer_id, status, created_at, updated_at)
      VALUES (#{@raid.id.to_i}, #{@trainer.id.to_i}, 'confirmed', now(), now())
      ON CONFLICT (raid_id, trainer_id) DO NOTHING
      RETURNING id
    SQL
    if inserted.rows.empty?
      outcome = :idempotent           # reservation already existed → no decrement
      next
    end

    updated = exec(<<~SQL, "claim_decrement")
      UPDATE raids SET slots_remaining = slots_remaining - 1, updated_at = now()
      WHERE id = #{@raid.id.to_i} AND slots_remaining > 0
      RETURNING slots_remaining
    SQL
    if updated.rows.empty?
      outcome = :full
      raise ActiveRecord::Rollback    # undo the just-inserted reservation
    end
    outcome = :created
  end
  outcome
rescue ActiveRecord::StatementInvalid => e
  Rails.logger.error("[OVERSELL ATTEMPT] raid=#{@raid.id} ...")
  :full
end
```

Two database facts do all the work:

1. A **`UNIQUE (raid_id, trainer_id)`** index (migration
   [`20260606000004_create_reservations.rb`](../backend/db/migrate/20260606000004_create_reservations.rb))
   makes `INSERT ... ON CONFLICT DO NOTHING` idempotent.
2. A **guarded conditional `UPDATE`** — `WHERE slots_remaining > 0` — is the atomic decrement. The
   row lock serializes concurrent claims; the predicate fails the loser. Backed by
   `CHECK (slots_remaining >= 0)` in
   [`20260606000003_create_raids.rb`](../backend/db/migrate/20260606000003_create_raids.rb) as a
   last-resort guard — if it ever fires, that's logged as an `[OVERSELL ATTEMPT]`.

## Concrete walkthrough: 40 trainers stab the last slot

Say capacity is down to `slots_remaining = 1` and trainers `T1` and `T2` both call `claim` at the
same instant. Postgres row-level locking serializes them on the `raids` row:

```
time  T1                                   T2                                   raids.slots_remaining
----  -----------------------------------  -----------------------------------  ---------------------
t0    INSERT reservation (T1) -> id 91     INSERT reservation (T2) -> id 92     1
t1    UPDATE ... WHERE slots_remaining>0   (blocks on T1's row lock)            1
t2    -> RETURNING 0; 1 row; COMMIT        (still blocked)                      0
t3                                         lock released; re-evaluate WHERE     0
t4                                         slots_remaining>0 is FALSE -> 0 rows 0
t5                                         raise Rollback -> reservation 92 gone 0
----  result: :created (confirmed)         result: :full (raid_full)            0
```

Both inserts succeed (different `trainer_id`s, so no unique conflict) — but T2's *decrement* sees a
post-T1 world where `slots_remaining` is already 0, updates zero rows, and rolls back, deleting its
own just-inserted reservation. Exactly one winner, zero oversell, no application-level locking. The
[`spec/integration/no_oversell_spec.rb`](../backend/spec/integration/no_oversell_spec.rb) fires 40
real threads at a capacity-5 raid and asserts exactly 5 win.

```mermaid
sequenceDiagram
  participant T1 as Claim (T1)
  participant T2 as Claim (T2)
  participant PG as PostgreSQL (raids row)
  T1->>PG: INSERT reservation(T1)
  T2->>PG: INSERT reservation(T2)
  T1->>PG: UPDATE ... WHERE slots_remaining>0 (locks row)
  T2-->>PG: UPDATE ... (waits for lock)
  PG-->>T1: 1 row, slots_remaining=0, COMMIT
  PG-->>T2: lock free; predicate now false → 0 rows
  T2->>PG: ROLLBACK (reservation deleted)
  Note over T1,T2: T1 :created, T2 :raid_full -- one slot, one winner
```

Caption: the lock + the `WHERE slots_remaining > 0` predicate are what serialize the race — there is
no mutex in Ruby anywhere.

## Why the DB, not Redis or an app check

| Approach | Oversell-safe under concurrency? | Durable? | Verdict |
|----------|----------------------------------|----------|---------|
| `if slots_remaining > 0` in Ruby then save | No — classic check-then-act race | — | Rejected |
| `DECR` a Redis counter | Yes, atomic | No — Redis loss = lost truth of who holds a slot | Rejected |
| Guarded Postgres `UPDATE` + `CHECK` (chosen) | Yes — row lock serializes | Yes — it's the SoR | Chosen |

Redis is fast but ephemeral; the one fact you can never lose is "who actually holds a slot," so that
fact lives in Postgres. Redis still does the *flow control* (who may attempt), which is allowed to be
lossy.

## Try it out

Try each step yourself first — expand the solution only when stuck.

1. Run the release-blocking concurrency spec and confirm the invariant holds.

   <details>
   <summary><b>Solution</b></summary>

   ```bash
   cd backend && RAILS_MAX_THREADS=60 bundle exec rspec spec/integration/no_oversell_spec.rb --format documentation
   ```

   Expected: both examples green. `RAILS_MAX_THREADS=60` matters — the spec spawns ~40 threads, each
   needing its own DB connection; the default pool of 5 would deadlock. The pool size is wired to
   `RAILS_MAX_THREADS` in [`config/database.yml`](../backend/config/database.yml).
   </details>

2. Break the invariant on purpose to see the guard catch it. Temporarily remove `AND slots_remaining > 0`
   from the decrement and watch a spec fail.

   <details>
   <summary><b>Solution</b></summary>

   In [`claim.rb`](../backend/app/services/reservations/claim.rb#L85), change the `UPDATE`'s `WHERE`
   to just `WHERE id = #{@raid.id.to_i}`, then run the spec from step 1. It will fail
   (`slots_remaining` goes negative / too many confirmed) — and you may see an `[OVERSELL ATTEMPT]`
   log from the `CHECK (slots_remaining >= 0)` backstop firing. Revert the change. This shows the
   predicate, not Ruby, is what enforces capacity.
   </details>

3. Throttle a raid's admission via the control-plane key and confirm the worker honors it without a
   coordinator.

   <details>
   <summary><b>Solution</b></summary>

   ```bash
   cd backend && bin/rails runner '
     raid = Raid.create!(boss:"X", gym_name:"G", starts_at:1.hour.from_now, capacity:100, slots_remaining:100, status:"published")
     QueueRedis.with { |r| r.set(QueueConfig.admission_rate_key(raid.id), 3) }
     p Admission::Pacing.batch_size(raid.id)
     QueueRedis.with { |r| r.del(QueueConfig.admission_rate_key(raid.id)) }
     p Admission::Pacing.batch_size(raid.id)'
   ```

   Expected: `3` then `50` (the default). The first is the coordinator's value; the second is the
   safe fallback when the key is absent — concept #4, the control plane never being a hard dependency.
   </details>

The claim confirms a slot, but trainers shouldn't have to poll to find out it's their turn. Chapter 4
picks up the `admitted` event the worker just published and pushes it to the browser in real time
over Server-Sent Events — plus the per-trainer claim window that gives that "You're up! 0:29" timer
its teeth.
