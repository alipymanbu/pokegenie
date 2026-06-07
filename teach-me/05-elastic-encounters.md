# Chapter 5: Elastic Encounters & AFK Backfill

The fixed-capacity model (Chapters 2–4) makes trainers pick a specific room and rejects them when
it's full. Feature 002 takes the product insight from the source article — *don't make users pick a
seat; let them pick the thing they want and auto-assign the best available slot* — and runs with it.
Trainers queue for an **Encounter** ("Mewtwo @ 8pm"); the system **spawns rooms on demand** and
**backfills no-show slots**. The beautiful part: it reuses the exact no-oversell claim from Chapter 3
unchanged. The full spec is [`specs/002-elastic-encounters/spec.md`](../specs/002-elastic-encounters/spec.md).

## The data model: rooms are just Raids

An `Encounter` owns many rooms, and a "room" is a `Raid` with its `encounter_id` set. That reuse is
the whole trick — everything that worked on a `Raid` (the claim transaction, `slots_remaining`, the
`CHECK` constraints, reservations) works on a room with zero new code.

```mermaid
erDiagram
  ENCOUNTER ||--o{ RAID : "spawns rooms"
  RAID ||--o{ RESERVATION : "holds"
  TRAINER ||--o{ RESERVATION : "claims"
  ENCOUNTER { string boss; string label; int room_size; string status }
  RAID { int encounter_id "null = standalone (feature 001)"; int room_number; int capacity; int slots_remaining }
  RESERVATION { int raid_id; int trainer_id; string status }
```

Caption: a `Raid` with `encounter_id = NULL` is a standalone feature-001 raid; with it set, it's a
room. Same table, two roles — see the `standalone` scope in
[`app/models/raid.rb`](../backend/app/models/raid.rb).

The migration that made this possible is small —
[`20260607000002_add_encounter_to_raids.rb`](../backend/db/migrate/20260607000002_add_encounter_to_raids.rb)
just adds a nullable `encounter_id` and `room_number`. Backward compatible: feature-001 raids keep
working untouched.

## One worker, two modes

The admission loop now sweeps both standalone raids *and* encounters, carefully excluding rooms from
the standalone pass so they aren't double-admitted:

```ruby
# backend/lib/admission_loop.rb:28
def tick_once
  Raid.where(status: "published", encounter_id: nil).find_each do |raid|   # standalone only
    RaidQueue::AdmitBatch.call(raid: raid)
  end
  Encounter.where(status: "published").find_each do |enc|                  # elastic
    Encounters::AdmitBatch.call(encounter: enc)
  end
end
```

## Elastic admission with backfill

[`Encounters::AdmitBatch`](../backend/app/services/encounters/admit_batch.rb) pops the encounter's
FIFO line and assigns each trainer to the **earliest room with a free slot**, spawning a new room
only when none has space:

```ruby
# backend/app/services/encounters/admit_batch.rb:21
def call
  members = QueueRedis.with { |r| Array(r.zpopmin(QueueConfig.enc_queue_key(@encounter.id), batch_size)) }
  return { admitted: 0, rooms_spawned: 0, backfilled: 0 } if members.empty?

  now = Time.now.to_i
  rooms = @encounter.rooms.order(:room_number).map { |room| [ room, free_slots(room, now) ] }
  spawned = 0; backfilled = 0

  members.each do |member, _score|
    slot = rooms.find { |(_room, free)| free > 0 }
    if slot.nil?
      room = spawn_room; slot = [ room, @size ]; rooms << slot; spawned += 1
    else
      backfilled += 1 if slot[0].slots_remaining < @size   # reusing a partly-used room = a backfill
    end
    assign(member, slot[0], now)
    slot[1] -= 1
  end
  { admitted: members.size, rooms_spawned: spawned, backfilled: backfilled }
end
```

Because **only the single worker assigns**, this loop is race-free without locks — it computes free
slots once, fills greedily, and decrements a local counter as it goes.

The "free slots" calculation is where backfill lives. Each room tracks outstanding **holds** — a
sorted set of admitted-but-not-yet-claimed trainers, scored by their hold's expiry timestamp:

```ruby
# backend/app/services/encounters/admit_batch.rb:62
def free_slots(room, now)
  holds = QueueRedis.with do |r|
    r.zremrangebyscore(QueueConfig.room_holds_key(room.id), 0, now)   # prune lapsed (AFK) holds
    r.zcard(QueueConfig.room_holds_key(room.id))
  end
  room.slots_remaining - holds
end
```

Read that formula carefully: `slots_remaining` already accounts for *confirmed* claims (Chapter 3
decrements it). `holds` is the count of *outstanding* admissions. So `free_slots = slots_remaining -
holds` is "capacity minus confirmed minus pending." When a hold's score is in the past — an AFK
trainer whose claim window lapsed — `ZREMRANGEBYSCORE` prunes it, and its slot reappears as free,
ready to be **backfilled** to a later trainer instead of wasted. `assign` adds the hold
([line 82](../backend/app/services/encounters/admit_batch.rb#L82)) and the claim releases it (the
`ZREM` in [`claim.rb`'s `clear_admitted`](../backend/app/services/reservations/claim.rb#L60), a
no-op for standalone raids).

## Concrete walkthrough: a no-show gets backfilled

Room size 3. Three trainers admitted; two claim; one (A) goes AFK. Then trainer D arrives.

```
step                          slots_remaining  holds (active)   free_slots   rooms
----------------------------  ---------------  ---------------  -----------  -----
admit A,B,C -> room 1         3                {A,B,C} = 3      0            1
B claims                      2                {A,C} = 2        0            1
C claims                      1                {A} = 1          0            1
A's hold lapses (AFK, 120s)   1                {} (pruned)      1            1
D joins, AdmitBatch runs      1                {D} = 1          0            1   <- backfilled, NO new room
D claims                      0                {} = 0           0            1   <- room full, 3 confirmed
```

A's freed slot went to D — no new room spawned, and the room ends exactly full with zero oversell.
The
[`spec/integration/elastic_encounters_spec.rb`](../backend/spec/integration/elastic_encounters_spec.rb)
"backfills an AFK no-show's freed slot" example pins this exact sequence.

## Why elastic eliminates contention

In the fixed model, the dramatic case is 40 trainers stabbing the last slot (Chapter 3). Elastic
*designs that away*: the worker assigns exactly the right number of trainers to each room, so under
normal flow no two trainers ever fight for the same slot — supply is created to match demand. The
per-room claim transaction is still there as a hard safety net (a hold/claim can momentarily race
after a prune), but it rarely has to reject anyone. That's why the encounter load runs in Chapter 7
show `lost_on_claim = 0`.

| Model | Scarcity is... | Contention | When you'd pick it |
|-------|----------------|------------|--------------------|
| Fixed-capacity raid (001) | a hard wall — "raid full" | high near the last slot | A real lobby with a fixed cap you must honor |
| Elastic encounter (002) | wait time only | near zero | "Get everyone in eventually," unbounded lobbies (remote raids) |

## State, end to end

[`Encounters::Position`](../backend/app/services/encounters/position.rb) reports `waiting → admitted
(with room) → reserved (with room)` — note it can report a *reserved* state by joining reservations
to the encounter's rooms, so a returning trainer who already claimed sees their room. Claiming itself
reuses `POST /raids/:room_id/reservations` — the same endpoint, because the room is a `Raid`.

## Try it out

Try each step yourself first — expand the solution only when stuck.

1. Watch rooms spawn from the console: queue 50 trainers into a room-size-20 encounter and admit
   them.

   <details>
   <summary><b>Solution</b></summary>

   ```bash
   cd backend && bin/rails runner '
     enc = Encounter.create!(boss:"Mewtwo", label:"Park", starts_at:1.hour.from_now, room_size:20, status:"published")
     50.times { |i| Encounters::Join.call(encounter: enc, trainer: Trainer.find_or_create_by_handle!("t#{i}")) }
     p Encounters::AdmitBatch.call(encounter: enc)
     p enc.rooms.order(:room_number).pluck(:room_number)'
   ```

   Expected: `{:admitted=>50, :rooms_spawned=>3, :backfilled=>0}` then `[1, 2, 3]` — ceil(50/20)=3
   rooms (20+20+10), no rejections.
   </details>

2. Reproduce backfill: fill a room-size-3 encounter, claim two, lapse one hold, admit a newcomer.

   <details>
   <summary><b>Solution</b></summary>

   Run the focused spec that does exactly this:

   ```bash
   cd backend && RAILS_MAX_THREADS=60 bundle exec rspec spec/integration/elastic_encounters_spec.rb \
     -e "backfills an AFK no-show" --format documentation
   ```

   Expected: green. Read the example body — it `ZADD`s an expired-score hold to simulate the AFK
   lapse, then asserts `result[:backfilled] == 1` and `enc.rooms.count == 1` (no new room).
   </details>

3. Confirm standalone raids still work after the encounter changes (backward compatibility).

   <details>
   <summary><b>Solution</b></summary>

   ```bash
   cd backend && RAILS_MAX_THREADS=60 bundle exec rspec spec/integration/no_oversell_spec.rb spec/requests/raids_spec.rb
   ```

   Expected: all green. The `encounter_id: nil` filter in `tick_once` and the `standalone` scope keep
   feature-001 paths isolated from rooms — same table, no interference.
   </details>

You now understand every production path. Chapter 6 turns around and asks the harder question: how do
you *prove* a concurrency invariant like "never oversell"? The answer shaped the production code —
the service-object split and the truncation test strategy exist precisely so these guarantees can be
tested with real threads.
