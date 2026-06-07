# Chapter 6: Testing

The constitution makes one rule non-negotiable: the concurrency and capacity invariants must have
automated tests, and they're release-blocking. That single rule shaped the production code — the
service-object split (Chapters 2–5) and an unusual database-cleaning choice both exist so that
"never oversell" can be tested with *real threads*, not mocks. This chapter shows how the suite is
built and why a couple of deliberate choices matter.

## The shape of the suite

Three layers under [`backend/spec/`](../backend/spec/), mirroring the architecture:

| Layer | Directory | What it proves | Example |
|-------|-----------|----------------|---------|
| Service unit | `spec/services/` | one service's logic in isolation | [`reservations/claim_spec.rb`](../backend/spec/services/reservations/claim_spec.rb) |
| Request | `spec/requests/` | HTTP contract: status codes, JSON | [`reservations_spec.rb`](../backend/spec/requests/reservations_spec.rb) |
| Integration | `spec/integration/` | invariants under real concurrency / multi-step flows | [`no_oversell_spec.rb`](../backend/spec/integration/no_oversell_spec.rb) |

Because the logic lives in service objects that return a `ServiceResult` (Chapter 1), the unit tests
need no HTTP and no mocking — they call `Reservations::Claim.call(...)` and assert on `.ok?` and
`.code`. The thin controllers get covered by a handful of request specs that only check the
service-result-to-status-code mapping. This is the payoff of keeping controllers dumb.

Run it all (note the wide pool — explained below):

```bash
cd backend && RAILS_MAX_THREADS=60 bundle exec rspec
```

## The load-bearing choice: truncation, not transactions

By default RSpec wraps each example in a transaction and rolls it back — fast, but it makes a test's
writes invisible to *other* database connections. That's fatal here, because the no-oversell spec
spawns real threads, each with its own connection, that must see each other's committed rows. So the
suite turns transactional fixtures off and cleans with truncation instead:

```ruby
# backend/spec/rails_helper.rb:47
config.use_transactional_fixtures = false

config.around(:each) do |example|
  DatabaseCleaner.strategy = :truncation
  DatabaseCleaner.cleaning { example.run }
end

config.before(:each) do
  QueueRedis.with { |r| r.flushdb }      # Redis isolated per example (test DB 15)
end
```

Why this is necessary, concretely:

```
                          transactional fixtures        truncation (chosen)
                          ----------------------        -------------------
thread T1 INSERTs row     visible only to T1's conn     COMMITted, visible to all conns
thread T2 SELECTs         sees nothing (T1 uncommitted) sees T1's row
last-slot race            cannot be reproduced          reproduced faithfully
speed                     faster                        slightly slower (acceptable)
```

If you used transactional fixtures, the 40-thread oversell test would *pass for the wrong reason* —
threads wouldn't see each other, so contention never happens. The suite would be green and the
production invariant untested. Truncation trades a little speed for tests that exercise the real
thing. Redis gets the same isolation treatment: tests point at logical DB 15
([`rails_helper.rb:5`](../backend/spec/rails_helper.rb#L5)) and `FLUSHDB` before each example, so a
stray key never leaks between tests or into your dev data.

## Forcing a real race

The concurrency helper [`run_concurrently`](../backend/spec/support/queue_helpers.rb) doesn't just
spawn threads — it parks them all at a gate and releases them at once to maximize contention, and
releases each thread's DB connection afterward:

```ruby
# backend/spec/support/queue_helpers.rb
threads = (0...count).map do |i|
  Thread.new do
    ready << true
    mutex.synchronize { cond.wait(mutex) until start }   # park at the gate
    begin
      results[i] = yield(i)
    ensure
      ActiveRecord::Base.connection_pool.release_connection
    end
  end
end
count.times { ready.pop }                                # wait until all are parked
mutex.synchronize { start = true; cond.broadcast }       # fire simultaneously
```

The oversell spec uses it to assert the invariant directly:

```ruby
# backend/spec/integration/no_oversell_spec.rb:12
results = run_concurrently(contenders) do |i|
  Reservations::Claim.call(raid: raid, trainer: trainers[i])
end
expect(results.count(&:ok?)).to eq(capacity)          # exactly capacity win
expect(raid.reload.slots_remaining).to eq(0)          # never negative
```

This is why `RAILS_MAX_THREADS=60` is on every test command: 40 contending threads each check out a
connection, and the pool size is wired to `RAILS_MAX_THREADS` in
[`config/database.yml`](../backend/config/database.yml). A pool of 5 (the default) would deadlock the
spec, not fail it — a confusing hang. Surface this env var the first time you run the suite.

## Tests as a design check: the idempotency bug

The suite isn't just confirmation — it caught a real bug. The original `reservations_spec.rb`
"idempotent replay" test re-admitted the trainer between the two claims, which masked a defect: in
production a replay arrives *after* the first claim cleared the admitted flag, so it hit the gate and
wrongly returned `:not_admitted`. The fix was to check for an existing reservation *before* the gate
([`claim.rb:30`](../backend/app/services/reservations/claim.rb#L30)), and the spec was rewritten to
replay *without* re-admitting — the truer scenario:

```ruby
# backend/spec/requests/reservations_spec.rb
it "returns 200 (not 201) on idempotent replay, even without re-admission (FR-008)" do
  # ... claim once -> 201 ...
  post "/raids/#{raid.id}/reservations", params: { trainer_handle: "ash" }, as: :json
  expect(response).to have_http_status(:ok)            # the replay, with no re-admit
  expect(raid.reload.slots_remaining).to eq(4)         # no second slot consumed
end
```

A test that's too convenient hides bugs; this one was made deliberately inconvenient to match
reality.

## What's deliberately not tested, and why

- **SSE at scale / the streaming loop's long-poll.** One request spec
  ([`queue_stream_spec.rb`](../backend/spec/requests/queue_stream_spec.rb)) covers the terminating
  cases (admitted trainer → `admitted` event; a threaded waiting→admitted) but the infinite loop and
  thousands of concurrent streams aren't unit-tested — that's the deferred SSE-fleet concern, and
  it's exercised instead by the load simulator (Chapter 7).
- **The worker's infinite loop.** `AdmissionLoop.run`'s `while running` loop isn't tested; the
  per-tick logic is extracted into `tick_once` precisely so the behavior is testable without the loop
  ([`lib/admission_loop.rb:28`](../backend/lib/admission_loop.rb#L28)). The integration specs call
  `AdmitBatch` directly.
- **The frontend.** No component tests in this iteration — it's a thin client over a
  thoroughly-tested API; `npm run build` + `npm run lint` are the gate.
- **The graceful-degradation path** is tested, though:
  [`coordinator_down_spec.rb`](../backend/spec/integration/coordinator_down_spec.rb) proves admission
  falls back to the default batch when the pacing key is absent or garbage.

## Try it out

Try each step yourself first — expand the solution only when stuck.

1. Prove the truncation point: flip `use_transactional_fixtures` back to `true` and watch the
   oversell spec break or behave oddly.

   <details>
   <summary><b>Solution</b></summary>

   In [`spec/rails_helper.rb`](../backend/spec/rails_helper.rb#L47) set
   `config.use_transactional_fixtures = true`, then:

   ```bash
   cd backend && RAILS_MAX_THREADS=60 bundle exec rspec spec/integration/no_oversell_spec.rb
   ```

   You'll see errors/failures (threads on separate connections can't see the transaction's
   uncommitted rows; setup data created in the example isn't visible to the spawned threads). Revert.
   This is the concrete reason the suite uses truncation.
   </details>

2. Add a new request spec asserting that joining an unpublished raid returns 409.

   <details>
   <summary><b>Solution</b></summary>

   The case already exists — find and run it, then add a sibling:

   ```bash
   cd backend && bundle exec rspec spec/requests/queue_join_spec.rb -e "unpublished" --format documentation
   ```

   To add one for a *draft encounter*, append to
   [`spec/requests/raids_spec.rb`](../backend/spec/requests/raids_spec.rb) style using the
   `create_raid(..., status: "draft")` helper from
   [`spec/support/queue_helpers.rb`](../backend/spec/support/queue_helpers.rb) and assert
   `have_http_status(:conflict)` and `error == "not_published"`. The helpers exist so new specs stay
   one-liners.
   </details>

3. Run only the release-blocking specs (the ones that gate a merge).

   <details>
   <summary><b>Solution</b></summary>

   ```bash
   cd backend && RAILS_MAX_THREADS=60 bundle exec rspec \
     spec/integration/no_oversell_spec.rb spec/integration/fifo_admission_spec.rb \
     spec/services/reservations/claim_spec.rb spec/services/raid_queue/reconnect_spec.rb \
     spec/integration/coordinator_down_spec.rb spec/integration/elastic_encounters_spec.rb
   ```

   Expected: all green. These map directly to the constitution's NON-NEGOTIABLE principles —
   fairness, capacity, graceful degradation, and elastic correctness.
   </details>

Tests prove the code is correct at small scale with real threads. Chapter 7 cranks it to thousands:
a fiber-based load simulator that drives the *real HTTP API* with realistic trainer behavior — and
re-verifies no-oversell against live metrics under genuine load.
