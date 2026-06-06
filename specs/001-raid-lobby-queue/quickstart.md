# Quickstart: Raid Lobby Queue (local)

Everything runs via docker-compose — Postgres, Redis, the Rails API, the admission worker, and
the Next.js frontend. No AWS needed (that phase is deferred).

## Prerequisites

- Docker + Docker Compose
- (For working outside containers) Ruby 3.3, Node 20

## Run it

```bash
docker compose up --build
```

Services:
| Service | Port | Role |
|---------|------|------|
| frontend | 3001 | Next.js UI |
| backend | 3000 | Rails API + SSE |
| worker | — | admission loop (`lib/admission_loop.rb`) |
| postgres | 5432 | system of record |
| redis | 6379 | queue + coordination |

First run, set up the DB:

```bash
docker compose exec backend bin/rails db:prepare db:seed
```

Seed creates a sample published raid (capacity 20) to queue for.

## Try the flow (curl)

```bash
# 1. See raids
curl localhost:3000/raids

# 2. Join the line
curl -XPOST localhost:3000/raids/1/queue/join \
  -H 'content-type: application/json' -d '{"trainer_handle":"ash"}'
# → {"token":"...","state":"waiting","position":1,"depth":1}

# 3. Watch your position live (SSE)
curl -N "localhost:3000/raids/1/queue/stream?token=PASTE_TOKEN"

# 4. Once 'admitted', claim a slot
curl -XPOST localhost:3000/raids/1/reservations \
  -H 'content-type: application/json' -d '{"trainer_handle":"ash"}'
# → 201 {"id":1,"status":"confirmed",...}

# 5. Operator view
curl localhost:3000/raids/1/metrics
```

Or open the UI at http://localhost:3001/raids/1.

## Run the tests (the core invariants)

```bash
docker compose exec backend bundle exec rspec
```

The release-blocking specs (constitution VI):
- `spec/integration/no_oversell_spec.rb` — N>capacity concurrent claims ⇒ exactly `capacity`
  reservations, zero oversell (SC-001).
- `spec/integration/fifo_admission_spec.rb` — admission order == join order (SC-002).
- `spec/services/reservations/claim_spec.rb` — duplicate claim ⇒ one reservation (SC-005).
- `spec/services/queue/reconnect_spec.rb` — reconnect within grace preserves rank (SC-004).
- `spec/integration/coordinator_down_spec.rb` — admission continues at default batch when
  `admission:rate` key absent (SC-006).

## Tuning knobs (env, see data-model.md)

`RECONNECT_GRACE_SECONDS=120`, `ADMISSION_DEFAULT_BATCH=50`, `ADMISSION_TICK_MS=1000`,
`CLAIM_WINDOW_SECONDS=120`, `POSITION_PUSH_MS=1500`.

## Deferred (not in this iteration)

Adaptive admission controller, section-based seat maps, durable (Kafka) recovery log, and the
production-scale multi-server SSE fleet + Terraform/AWS infra. `infra/` holds a placeholder only.
