# Implementation Plan: Raid Lobby Waiting Queue & Reservation

**Branch**: `001-raid-lobby-queue` | **Date**: 2026-06-06 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/001-raid-lobby-queue/spec.md`

## Summary

Build a virtual waiting-queue + reservation system for fixed-capacity Pokémon GO raid lobbies.
Trainers join a per-raid FIFO line, receive real-time position/admission updates, and — once
admitted — claim one of N slots with a hard no-oversell guarantee. The line is a Redis sorted
set (strict FIFO via a monotonic sequence score, idempotent re-entry, O(log N) ops). Admission
is a non-blocking background worker that pops batches at a tunable pace (with a safe default when
the deferred coordinator is absent) and publishes events over Redis Pub/Sub. Real-time delivery
to the browser is Server-Sent Events from Rails (`ActionController::Live`). The capacity
invariant lives in PostgreSQL: a single transaction inserts the reservation (unique per
trainer+raid for idempotency) and atomically decrements a guarded slot counter, so concurrent
last-slot claims cannot oversell. Everything runs locally via docker-compose; AWS/Terraform is a
documented, deferred phase.

## Technical Context

**Language/Version**: Ruby 3.2 + Rails 8.1 (API mode); TypeScript 5 + Node 22+

> **Amendment (2026-06-06)**: Originally pinned Ruby 3.3 / Rails 7.2 / Node 20. Reconciled to the
> host's current-stable toolchain (Ruby 3.2.2, Rails 8.1, Node 23) so the MVP runs and tests
> green locally against the already-running host Postgres 14 + Redis. Docker images pin matching
> versions. No principle impact — stack mandate (Rails/Next/Redis/Postgres) is unchanged.

**Primary Dependencies**: Rails API, `redis` + `connection_pool` gems, `pg`; Next.js 14 (App
Router) + React 18 on the frontend; RSpec for backend tests

**Storage**: PostgreSQL 16 (system of record: raids, trainers, reservations) + Redis 7 (FIFO
queue sorted set, admitted set, reconnect tokens, metric counters, Pub/Sub)

**Testing**: RSpec (unit + request + concurrency/integration) on the backend; lightweight
component/E2E (Playwright) on the frontend — backend correctness tests are the priority

**Target Platform**: Local docker-compose (Linux containers) for this iteration; managed AWS
deferred

**Project Type**: Web application — separate `backend/` (Rails API) and `frontend/` (Next.js),
plus a standalone admission worker process

**Performance Goals**: Queue ops O(log N) per operation; position/admission delivered to client
within 2s (SC-003); correctness validated under concurrent contention rather than raw throughput
in this iteration

**Constraints**: No oversell ever (hard invariant in the DB); strict FIFO; booking hot path must
not block on the admission coordinator; graceful degradation under coordinator loss

**Scale/Scope**: North-star design target is millions of concurrent waiters; this iteration
validates correctness + real-time behavior at representative local scale (thousands queued in
tests). Production-scale SSE fleet and load are deferred.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | How this plan satisfies it |
|-----------|----------------------------|
| I. Fairness First (NON-NEGOTIABLE) | Redis sorted set keyed by a monotonic per-raid sequence (`INCR`) as score → strict, unique FIFO. `ZADD NX` makes re-join/duplicate-join idempotent (position never changes). Reconnect token re-adds with the **original** score within the grace window. |
| II. Capacity Correctness (NON-NEGOTIABLE) | Single Postgres transaction: `INSERT ... ON CONFLICT DO NOTHING` on `reservations(raid_id, trainer_id)` (idempotency) then guarded `UPDATE raids SET slots_remaining = slots_remaining - 1 WHERE id = ? AND slots_remaining > 0`; 0 rows updated ⇒ rollback ⇒ "raid full". `CHECK (slots_remaining >= 0)` is the data-layer backstop. |
| III. Control / Data Plane Separation | Admission pace is read from Redis key `admission:rate:{raid}` with a hardcoded safe default when absent. The (deferred) controller only *writes* that key; the worker and claim path never block on it. |
| IV. Resilience Under Load | All hot-path queue ops are O(log N) (ZADD/ZRANK/ZPOPMIN). Admission is batched (backpressure) — the line is never released all at once. |
| V. Real-Time via SSE | `ActionController::Live` SSE endpoint, server→client only; subscribes to Redis Pub/Sub per raid for instant admission + periodic position. Reconnect uses a position-preserving token; SSE servers hold no per-user state beyond the open stream. |
| VI. Test-First for Core (NON-NEGOTIABLE) | RSpec concurrency specs written first and failing: N>capacity concurrent claims ⇒ exactly capacity reservations; duplicate claim ⇒ one reservation; reconnect preserves rank; admission order = join order. |
| VII. Observability | Redis counters (`metrics:claims`, `metrics:conflicts`, `ZCARD` depth); `GET /raids/:id/metrics`; any guarded-update failure that indicates a would-be oversell is logged at `error`. |
| VIII. Spec-Driven Development | This artifact set (spec → plan → tasks → implement); deferrals explicitly recorded here and in the spec. |

**Result**: PASS — no violations. Complexity Tracking left empty.

## Project Structure

### Documentation (this feature)

```text
specs/001-raid-lobby-queue/
├── plan.md              # This file
├── research.md          # Phase 0 — decisions & rationale
├── data-model.md        # Phase 1 — entities, schema, Redis keyspace, invariants
├── quickstart.md        # Phase 1 — run it locally
├── contracts/
│   ├── openapi.yaml     # REST API contract
│   └── sse-events.md    # SSE event stream contract
└── tasks.md             # Phase 2 — created by /speckit-tasks (NOT here)
```

### Source Code (repository root)

```text
backend/                         # Rails 7.2 API
├── app/
│   ├── controllers/
│   │   ├── raids_controller.rb
│   │   ├── queue_controller.rb          # join, status, claim
│   │   └── queue_streams_controller.rb  # SSE (ActionController::Live)
│   ├── models/
│   │   ├── raid.rb
│   │   ├── trainer.rb
│   │   └── reservation.rb
│   └── services/
│       ├── queue/
│       │   ├── join.rb                   # ZADD NX + token mint
│       │   ├── position.rb               # ZRANK
│       │   ├── reconnect.rb              # token → restore score
│       │   └── admit_batch.rb            # ZPOPMIN batch + publish
│       ├── reservations/
│       │   └── claim.rb                  # the atomic capacity transaction
│       ├── admission/
│       │   └── pacing.rb                 # read rate key, safe default
│       ├── metrics/
│       │   └── recorder.rb
│       └── redis_client.rb               # pooled connection
├── lib/
│   └── admission_loop.rb                 # standalone worker entrypoint
├── config/ db/ ...
└── spec/
    ├── services/                         # unit incl. concurrency specs
    ├── requests/                         # API contract specs
    └── integration/                      # end-to-end queue→admit→claim

frontend/                        # Next.js 14 (App Router)
├── app/
│   ├── raids/[id]/page.tsx              # raid detail + join
│   └── raids/[id]/queue/page.tsx        # waiting room (SSE)
├── components/
│   ├── QueuePosition.tsx
│   └── ClaimButton.tsx
├── lib/
│   ├── api.ts                           # REST client
│   └── queueStream.ts                   # EventSource + reconnect w/ token
└── tests/

docker-compose.yml               # postgres + redis + backend + worker + frontend
infra/                           # DEFERRED: terraform/ placeholder (README only)
```

**Structure Decision**: Web-application layout (Option 2) with an added standalone admission
worker process. Backend and frontend are separate deployables; the admission loop is a third
process sharing the backend codebase but run independently (its own docker-compose service) to
honor control/data-plane separation — it can be restarted or scaled without touching the API.

## Complexity Tracking

> No constitution violations. Section intentionally empty.
