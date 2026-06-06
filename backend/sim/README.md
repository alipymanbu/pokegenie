# Load & behavior simulator

`simulate.rb` spawns thousands of **fiber-based virtual trainers** (via the `async` gem) that
drive the **real HTTP API** — organizers create/publish raids, trainers arrive over time, queue,
get admitted or rejected, and either claim promptly, claim late, or go AFK until their hold
expires. A handful hold real SSE connections; some drop and reconnect mid-wait.

It exercises the whole system end-to-end (Puma, Redis, Postgres, the admission worker, the atomic
claim) and finishes with a **no-oversell integrity check** against live `/metrics`.

## Run

Start a backend tuned for load + the worker, then run the sim:

```bash
# 1. Tuned API (more Puma threads + Redis pool; short claim window so AFK resolves fast)
RAILS_MAX_THREADS=64 REDIS_POOL_SIZE=80 CLAIM_WINDOW_SECONDS=12 ADMISSION_TICK_MS=500 \
  bin/rails server -p 3002

# 2. Admission worker (same env)
RAILS_MAX_THREADS=64 REDIS_POOL_SIZE=80 CLAIM_WINDOW_SECONDS=12 ADMISSION_TICK_MS=500 \
  bin/rails admission:run

# 3. The simulation
SIM_TRAINERS=2000 SIM_RAIDS=25 SIM_DURATION=40 SIM_SSE=20 SIM_CONCURRENCY=200 \
  bundle exec ruby sim/simulate.rb
```

Watch it live in the operator UI too: http://localhost:3001/raids/<id>/metrics

## Knobs (ENV)

| Var | Default | Meaning |
|-----|---------|---------|
| `SIM_BASE` | `http://localhost:3002` | API base URL |
| `SIM_TRAINERS` | 2000 | total virtual trainers |
| `SIM_RAIDS` | 25 | raids created (≈20% are made "hot") |
| `SIM_DURATION` | 120 | arrival window in seconds (jittered) |
| `SIM_SSE` | 20 | how many trainers hold a real SSE connection |
| `SIM_CONCURRENCY` | 200 | cap on in-flight HTTP requests (models bounded server concurrency) |

## Behavior model

- **Arrivals**: jittered over `SIM_DURATION` (not a single thundering instant).
- **Raid choice**: ~60% pile into a hot raid (herd), else uniform.
- **On admission**: ~70% claim promptly, ~15% claim late (within window), ~15% AFK past the window.
- **While waiting**: ~5% abandon (disconnect forever), ~10% drop + reconnect (exercises US3).
- Joining a full raid → rejected; waiting in a raid that fills → drained (`raid_full`).

## Making queues deeper

Fast admission means most trainers are admitted within a poll or two (so `reconnect`/`abandon`
rarely trigger). To force deep, persistent lines (and exercise reconnect/abandon), **throttle the
control plane** — write a small admission rate per raid so the worker admits slowly:

```bash
# e.g. admit only 2 trainers/tick for raid 7
redis-cli set admission:rate:7 2
```

This is the same `admission:rate:{raid}` key the (deferred) adaptive controller would write —
the worker reads it and falls back to the default batch when it's absent.

## Notes

- SSE doesn't scale to thousands on a single dev Puma (each stream holds a thread — that's the
  deferred "SSE fleet"). The masses **poll**; a small `SIM_SSE` set holds real streams.
- The sim is a **client**; it needs no Rails env. `bundle exec` loads the `:sim` gem group.
