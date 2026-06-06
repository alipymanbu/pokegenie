---
description: "Task list for Raid Lobby Waiting Queue & Reservation"
---

# Tasks: Raid Lobby Waiting Queue & Reservation

**Input**: Design documents from `specs/001-raid-lobby-queue/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: INCLUDED and test-first for the core — the constitution (Principle VI) makes
concurrency/capacity/fairness tests NON-NEGOTIABLE and release-blocking.

## Format: `[ID] [P?] [Story] Description`

- **[P]** = can run in parallel (different files, no dependency on another incomplete task)
- **[Story]** = US1 / US2 / US3 / US4 / FOUND / SETUP / POLISH
- Paths are repo-relative (web-app layout: `backend/`, `frontend/`).

---

## Phase 1: Setup (Shared Infrastructure)

- [x] T001 [SETUP] Create top-level structure: `backend/`, `frontend/`, `infra/` (README placeholder noting deferred Terraform), root `docker-compose.yml`, `.gitignore`.
- [x] T002 [SETUP] Initialize Rails 7.2 API app in `backend/` (`rails new backend --api -d postgresql`); add gems: `redis`, `connection_pool`, and (group :test) `rspec-rails`, `database_cleaner-active_record`.
- [x] T003 [P] [SETUP] Initialize Next.js 14 (App Router, TypeScript) app in `frontend/`; add a minimal API base-URL config.
- [x] T004 [P] [SETUP] Configure RSpec in `backend/` (`rails g rspec:install`), set `database_cleaner` truncation strategy so concurrency specs see committed rows (research §8).
- [x] T005 [SETUP] Author `docker-compose.yml` with services: `postgres` (16), `redis` (7), `backend` (3000), `worker` (admission loop), `frontend` (3001); wire env + healthchecks per quickstart.md.
- [x] T006 [P] [SETUP] Configure linting/formatting: RuboCop (backend), ESLint/Prettier (frontend).

**Checkpoint**: `docker compose up` builds; empty apps boot.

---

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ Must complete before ANY user story.**

- [x] T007 [FOUND] Migration: `trainers` (handle citext UNIQUE) per data-model.md → `backend/db/migrate/`.
- [x] T008 [FOUND] Migration: `raids` (boss, gym_name, lat/long, starts_at, capacity, slots_remaining, status) with `CHECK (capacity > 0)`, `CHECK (slots_remaining >= 0)`, `CHECK (slots_remaining <= capacity)`.
- [x] T009 [FOUND] Migration: `reservations` (raid_id FK, trainer_id FK, status) with `UNIQUE (raid_id, trainer_id)` (idempotency / INV-2).
- [x] T010 [P] [FOUND] Models `Raid`, `Trainer`, `Reservation` in `backend/app/models/` with associations + validations mirroring DB constraints.
- [x] T011 [FOUND] `backend/app/services/redis_client.rb` — pooled Redis connection (`connection_pool`) usable from API threads, SSE threads, and the worker.
- [x] T012 [P] [FOUND] Centralized config/constants for tuning params (`RECONNECT_GRACE_SECONDS`, `ADMISSION_DEFAULT_BATCH`, `ADMISSION_TICK_MS`, `CLAIM_WINDOW_SECONDS`, `POSITION_PUSH_MS`, `POST_START_GRACE_SECONDS`) read from ENV with defaults (data-model.md).
- [x] T013 [P] [FOUND] JSON error contract + structured logging setup (`Error` schema from openapi.yaml; high-severity logger channel for oversell-attempt events, Principle VII).
- [x] T014 [FOUND] `db/seeds.rb`: one published raid, capacity 20 (quickstart step).

**Checkpoint**: schema migrated, models + Redis client + config ready.

---

## Phase 3: User Story 1 — Fairly reserve a slot (Priority: P1) 🎯 MVP

**Goal**: Trainer joins line → admitted in FIFO order → claims a slot, with zero oversell.
**Independent test**: capacity-N raid, >N trainers join in known order, run admission → exactly
first N get reservations; rest "raid full"; no double-holds.

### Tests first (write, watch fail)
- [x] T015 [P] [US1] `spec/services/reservations/claim_spec.rb`: duplicate claim ⇒ exactly one reservation, slot decremented once (SC-005, FR-008).
- [x] T016 [P] [US1] `spec/integration/no_oversell_spec.rb`: launch >capacity **concurrent** claims (threads) ⇒ exactly `capacity` confirmed, `slots_remaining = 0`, zero oversell (SC-001, FR-007).
- [x] T017 [P] [US1] `spec/integration/fifo_admission_spec.rb`: join order = admission order; first N admitted == first N joiners (SC-002, FR-002).
- [x] T018 [P] [US1] `spec/requests/queue_join_spec.rb`: join returns token+position; re-join is idempotent (same position); join on full/unpublished raid ⇒ 409 (FR-001, FR-013).
- [x] T019 [P] [US1] `spec/requests/reservations_spec.rb`: claim when admitted ⇒ 201; not admitted ⇒ 409; full ⇒ 409 `raid_full` (FR-006, FR-009).

### Implementation
- [x] T020 [US1] `backend/app/services/queue/join.rb`: `INCR seq` → `ZADD queue NX` → mint token (`SET token:{t} EX grace`); reject if raid not published / full. Returns status (position via ZRANK, depth via ZCARD).
- [x] T021 [US1] `backend/app/services/queue/position.rb`: ZRANK lookup → waiting/admitted/not-found resolution.
- [x] T022 [US1] `backend/app/services/admission/pacing.rb`: read `admission:rate:{raid}` or return `ADMISSION_DEFAULT_BATCH` (never raises — Principle III).
- [x] T023 [US1] `backend/app/services/queue/admit_batch.rb`: ZPOPMIN batch → SADD `admitted` (TTL) → INCRBY `metrics:admitted` → PUBLISH `admitted`; stop & drain `raid_full` when `slots_remaining = 0`.
- [x] T024 [US1] `backend/app/services/reservations/claim.rb`: the atomic transaction (insert ON CONFLICT DO NOTHING + guarded decrement; rollback ⇒ raid_full; SISMEMBER admitted gate; metrics counters; high-sev log on guarded-update race). **This is the capacity invariant (Principle II).**
- [x] T025 [US1] `backend/lib/admission_loop.rb`: standalone process — every `ADMISSION_TICK_MS`, for each published raid call `admit_batch`; safe on coordinator/key absence; logs admission rate.
- [x] T026 [US1] Controllers + routes: `QueueController#join`, `#status`; `ReservationsController#create` (maps results to openapi.yaml status codes).
- [x] T027 [US1] Make T015–T019 pass; verify zero-oversell and FIFO specs are green.

**Checkpoint**: MVP works end-to-end via curl (quickstart) — join, admit (worker), claim, no oversell.

---

## Phase 4: User Story 2 — Real-time position & admission (Priority: P2)

**Goal**: Waiting trainers get live position + instant admission over SSE.
**Independent test**: positions only decrease; admitted notification arrives without polling.

### Tests first
- [ ] T028 [P] [US2] `spec/requests/queue_stream_spec.rb`: stream sends an initial `position` event; emits `admitted` after the worker pops the trainer (FR-004); content-type `text/event-stream`.

### Implementation
- [ ] T029 [US2] `backend/app/controllers/queue_streams_controller.rb` (`ActionController::Live`): subscribe to `events:{raid}` (instant admitted/raid_full) + timer-based `position` every `POSITION_PUSH_MS`; keepalive comments; close on terminal event. Per sse-events.md.
- [ ] T030 [US2] Ensure `admit_batch` publishes per-trainer `admitted`/`raid_full` payloads matching sse-events.md.
- [ ] T031 [P] [US2] Frontend `frontend/lib/queueStream.ts`: `EventSource` wrapper handling `position`/`admitted`/`raid_full`/`error`.
- [ ] T032 [P] [US2] Frontend `components/QueuePosition.tsx` + waiting-room page `app/raids/[id]/queue/page.tsx` showing live position; reveal `ClaimButton` on `admitted`.

**Checkpoint**: UI waiting room updates live and flips to claim on admission.

---

## Phase 5: User Story 3 — Reconnect preserves place (Priority: P3)

**Goal**: Disconnect+reconnect within grace resumes original rank; reservation survives regardless.

### Tests first
- [ ] T033 [P] [US3] `spec/services/queue/reconnect_spec.rb`: reconnect within grace ⇒ original score/rank restored; after grace ⇒ new back-of-line; held reservation intact across reconnect (SC-004, FR-010/011/014).

### Implementation
- [ ] T034 [US3] `backend/app/services/queue/reconnect.rb`: resolve `token:{t}` → re-`ZADD NX` original score + refresh TTL; missing ⇒ delegate to `Queue::Join` (new place). Emit `error: token_expired` path for SSE.
- [ ] T035 [US3] Wire reconnect into `#status` and the SSE controller (token re-resolution on connect); frontend persists token (localStorage) and reuses it on `EventSource` reconnect.

**Checkpoint**: kill the SSE connection mid-wait → reconnect resumes same position.

---

## Phase 6: User Story 4 — Organize a raid (Priority: P3)

**Goal**: Organizer creates + publishes a capacity-bounded raid.

### Tests first
- [ ] T036 [P] [US4] `spec/requests/raids_spec.rb`: create (201, status draft), publish (200), publish enables join; capacity enforced (FR-012, FR-013).

### Implementation
- [ ] T037 [US4] `RaidsController#index/#show/#create/#publish` + routes; `slots_remaining` initialized to `capacity` on create; per openapi.yaml.
- [ ] T038 [P] [US4] Frontend `app/raids/[id]/page.tsx` (raid detail + Join) and a minimal create form/page.

**Checkpoint**: organizer can stand up a new raid that trainers immediately queue for.

---

## Phase 7: Polish & Cross-Cutting

- [ ] T039 [P] [POLISH] `RaidsController#metrics` → `Metrics` schema (queue_depth, slots_remaining, counters, conflict_rate) (FR-016, SC-007).
- [ ] T040 [P] [POLISH] `spec/integration/coordinator_down_spec.rb`: with `admission:rate` key absent/unreadable, admission proceeds at default batch, correctness preserved (SC-006, FR-015).
- [ ] T041 [P] [POLISH] Frontend metrics/operator view (optional simple page) consuming `/raids/:id/metrics`.
- [ ] T042 [P] [POLISH] README at repo root: architecture diagram, run instructions (link quickstart.md), explicit deferred-scope list.
- [ ] T043 [P] [POLISH] `infra/README.md`: document the deferred AWS+Terraform phase (ECS/Fargate, ElastiCache, RDS, ALB) as future work — no resources created.
- [ ] T044 [POLISH] Full `bundle exec rspec` green; manual quickstart walkthrough; verify the five release-blocking specs pass.

---

## Dependencies & Order

- **Setup (P1)** → **Foundational (P2)** block everything.
- **US1 (P3 phase)** is the MVP and depends only on Foundational. Ship it alone for a working system.
- **US2** depends on US1 (queue + admission must exist to stream).
- **US3** depends on US1 (join/token) and benefits from US2 (SSE reconnect).
- **US4** depends only on Foundational (independent of US1 runtime); can be built in parallel with US1 by a second contributor, but US1 can use the seeded raid meanwhile.
- **Polish** last.

## Parallel execution examples

- Phase 1: T003, T004, T006 in parallel after T002.
- Phase 2: T010, T012, T013 in parallel after migrations (T007–T009) + T011.
- US1 tests T015–T019 all `[P]` (different spec files) — write them together, then implement T020–T026.
- US2/US4 frontend tasks (T031, T032, T038) parallel with their backend tasks.

## Implementation strategy

1. **MVP = Setup + Foundational + US1.** Delivers the core promise (fair, no-oversell reservation)
   testably on its own.
2. Add **US2** (real-time UX), then **US3** (reconnect resilience), then **US4** (organizer tooling).
3. **Polish** (metrics, coordinator-down test, docs) closes out observability + deferred-scope
   documentation.
4. Gate every merge touching queue/admission/reservation on the release-blocking specs
   (T016, T017, T015, T033, T040).
