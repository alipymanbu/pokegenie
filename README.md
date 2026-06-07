# PokeGenie Raid Queue

A **learning project** for studying the design of a virtual waiting-queue + reservation system,
modeled on high-demand **Pokémon GO raid lobby slots** — trainers queue for one of N slots in a
fixed-capacity raid, are admitted fairly (FIFO), and claim a slot with a hard **no-oversell**
guarantee. Inspired by the system design behind concert-ticket waiting queues, adapted to raid
lobbies. The intent is educational: a small but realistic codebase for exploring FIFO fairness,
no-oversell invariants, and control/data-plane separation (see the [`teach-me/`](teach-me/)
walkthrough).

Built spec-first with [spec-kit](https://github.com/github/spec-kit). The full spec, plan, and
design live in [`specs/001-raid-lobby-queue/`](specs/001-raid-lobby-queue/); the engineering
principles are in [`.specify/memory/constitution.md`](.specify/memory/constitution.md).

## Architecture

```
Browser (Next.js)
   │  REST: join / status / claim          SSE: position / admitted   (US2)
   ▼
Rails API ──────────────┐
   │  claim (atomic txn) │  reads/writes
   ▼                     ▼
PostgreSQL           Redis  ── sorted-set FIFO queue, admitted set,
(reservations,        │       reconnect tokens, metric counters, pub/sub
 capacity invariant)  │
                      ▼
            Admission worker (separate process)
            pops batches → publishes "admitted"   (control plane; never blocks claims)
```

- **Fairness** (FIFO): Redis sorted set scored by a monotonic `INCR` sequence; idempotent re-join.
- **No oversell**: a single Postgres transaction — `INSERT ON CONFLICT DO NOTHING` (idempotency)
  + a guarded atomic decrement (`WHERE slots_remaining > 0`) + a `CHECK` constraint backstop.
- **Control/data-plane separation**: the admission worker paces admission with a safe default when
  the (deferred) coordinator is absent; the claim path never depends on it.

## Run it

**Docker (full system):**

```bash
docker compose up --build
# frontend → http://localhost:3001   API → http://localhost:3000
```

**Locally (host Postgres + Redis already running):**

```bash
cd backend && bundle install && bin/rails db:prepare db:seed
bin/rails server -p 3000                 # API
bin/rails admission:run                  # admission worker (separate terminal)
cd ../frontend && npm install && npm run dev   # http://localhost:3001
```

See [`specs/001-raid-lobby-queue/quickstart.md`](specs/001-raid-lobby-queue/quickstart.md) for a
curl walkthrough.

## Tests (the core invariants)

```bash
cd backend && RAILS_MAX_THREADS=60 bundle exec rspec
```

Release-blocking specs (constitution Principle VI): concurrent **no-oversell**
(`spec/integration/no_oversell_spec.rb`), **FIFO admission**
(`spec/integration/fifo_admission_spec.rb`), idempotent claim, and the request contracts.

## Status

- ✅ **US1 — Core**: fair FIFO queue, admission worker, capacity-correct reservation, per-trainer
  claim window with countdown + graceful expiry, metrics; backend tested under concurrency.
- ✅ **US2 — Real-time**: SSE position + admission push (Redis pub/sub + periodic fallback).
- ✅ **US3 — Reconnect**: presence-based grace window; refresh/disconnect resumes your place;
  reservations survive (Postgres).
- ✅ **US4 — Organizer**: create + publish raids from the UI.
- ✅ **Polish**: operator metrics view, coordinator-down (pacing fallback) test.
- ✅ **Elastic encounters (feature 002)**: queue for a Pokémon, the system auto-assigns rooms and
  **spawns new ones on demand** (no "full") — see [specs/002-elastic-encounters/](specs/002-elastic-encounters/).
- 🚫 **Deferred** (documented): adaptive admission *controller* logic, section pub/sub seat maps,
  durable recovery log, production-scale SSE fleet, and AWS/Terraform infra (`infra/`).
