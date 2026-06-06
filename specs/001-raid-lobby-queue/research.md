# Phase 0 Research: Raid Lobby Waiting Queue

Decisions resolving the Technical Context. Each entry: Decision / Rationale / Alternatives.

## 1. FIFO queue data structure

**Decision**: Redis **sorted set** per raid, `queue:{raidId}`, member = `trainerId`, score = a
monotonic per-raid sequence number from `INCR seq:{raidId}`.

**Rationale**: Sorted sets give O(log N) insert (`ZADD`), rank lookup (`ZRANK`), and atomic batch
pop (`ZPOPMIN k`) — exactly the operations the queue needs, and they stay sub-millisecond at the
millions-of-members design target (Principle IV). Using an `INCR` sequence as the score (instead
of a wall-clock timestamp as in the source article) guarantees **strict, unique, total ordering**
with no clock-skew or same-millisecond-collision ambiguity — directly serving Fairness
(Principle I). The wall-clock join time is still stored (in the reconnect token + for metrics)
but is not the ordering key.

**Alternatives considered**:
- *Timestamp score (article's approach)*: simpler conceptually but two joins in the same
  millisecond tie, and clock skew across app servers can reorder. Rejected for a fairness-critical
  system.
- *Redis List (`LPUSH`/`RPOP`)*: O(1) ends but O(N) rank lookup — can't answer "what's my
  position?" cheaply. Rejected (FR-003 needs cheap position).
- *Postgres queue table with `ORDER BY`*: durable but rank queries and high-churn pops contend on
  the same hot rows under load. Rejected for the hot path (Postgres remains the reservation SoR).

## 2. Idempotent join & duplicate-join handling

**Decision**: `ZADD queue:{raidId} NX <score> <trainerId>`. `NX` only sets the score if the member
is absent, so a re-join or double-tap never moves an existing waiter. The score is allocated via
`INCR` only when needed; a redundant `INCR` on a no-op `ZADD NX` is harmless (sequence gaps are
fine).

**Rationale**: Satisfies the "duplicate join" edge case and Principle I without an extra read.

**Alternatives**: read-then-write (`ZSCORE` then `ZADD`) — racy under concurrency. Rejected.

## 3. Reconnection with position preservation

**Decision**: On join, mint an opaque **queue token** (UUID) and store
`token:{token} → {raidId, trainerId, score}` in Redis with TTL = reconnection grace period
(default 120s, configurable). On reconnect the client presents the token; if the key still exists
we re-`ZADD NX` the original score (restores exact relative position); if expired, the trainer is
treated as a new arrival (`INCR` a fresh score → back of line). A held reservation is in Postgres,
so it survives regardless of token expiry (FR-011).

**Rationale**: Server-side stateless SSE (Principle V) — the token, not the connection, carries the
place. TTL implements the grace window (FR-010, FR-014) without a sweeper job.

**Alternatives**: cookie/session affinity to a server — breaks the stateless-fleet requirement.
Rejected.

## 4. Capacity invariant — the no-oversell transaction

**Decision**: Enforce in PostgreSQL, single transaction in `Reservations::Claim`:

```sql
BEGIN;
INSERT INTO reservations (raid_id, trainer_id, status, created_at)
VALUES ($1, $2, 'confirmed', now())
ON CONFLICT (raid_id, trainer_id) DO NOTHING
RETURNING id;
-- if no row returned: reservation already existed → idempotent success, DO NOT decrement, COMMIT
UPDATE raids SET slots_remaining = slots_remaining - 1
WHERE id = $1 AND slots_remaining > 0
RETURNING slots_remaining;
-- if no row returned: full → ROLLBACK (removes the just-inserted reservation) → "raid full"
COMMIT;
```

Backed by `UNIQUE (raid_id, trainer_id)` and `CHECK (slots_remaining >= 0)` constraints.

**Rationale**: The unique index gives idempotency (FR-008); the guarded conditional `UPDATE` is the
atomic decrement that cannot oversell even under simultaneous last-slot claims (FR-007, Principle
II) — the row lock serializes the two contenders and the `slots_remaining > 0` predicate fails the
loser. Doing insert-before-decrement and rolling back on "full" keeps the two facts consistent.
The `CHECK` constraint is the data-layer backstop required by the constitution ("data layer, not
application convention").

**Alternatives**:
- *`SELECT count(*) ... FOR UPDATE` then insert*: works but counts rows each claim; the counter
  column + guarded update is cheaper and equally safe. Kept the counter.
- *Decrement a Redis counter for capacity*: fast but Redis is not the durable SoR; a Redis failure
  could lose the truth of who holds a slot. Rejected — capacity truth must be durable.

## 5. Admission worker (control plane / data plane separation)

**Decision**: A standalone long-running process (`lib/admission_loop.rb`, its own docker-compose
service). Each tick, per active raid: read batch size from `admission:rate:{raidId}` (default 50
if unset/unreadable), `ZPOPMIN queue:{raidId} <batch>`, add each popped trainer to
`admitted:{raidId}` set (TTL = claim window), and `PUBLISH events:{raidId}` an `admitted` event
per trainer. Stop admitting a raid once `slots_remaining = 0`, draining the rest of the line with
`raid_full` events.

**Rationale**: Separating the worker from the API process realizes Principle III physically — the
booking/claim hot path never waits on admission, and if the (deferred) controller that tunes
`admission:rate` dies, the worker falls back to the safe default and keeps going (FR-015, SC-006).

**Alternatives**:
- *Sidekiq job per tick*: adds a dependency and a redundant job-queue abstraction over what is
  really one continuous loop. Deferred — can swap in later without changing the claim path.
- *Admit inside the request that joins*: collapses control and data plane. Rejected.

## 6. Real-time transport — SSE

**Decision**: `ActionController::Live` streaming endpoint `GET /raids/:id/queue/stream`. The handler
opens a Redis subscription to `events:{raidId}` (instant `admitted`/`raid_full`) and, on a short
timer (~1.5s), computes `ZRANK` to emit `position` events. Client uses the browser `EventSource`
API; on disconnect it reconnects with its stored queue token.

**Rationale**: Queue status is purely server→client, so SSE fits without WebSocket overhead
(Principle V). `EventSource` auto-reconnects natively; we layer token-based position preservation
on top. The 1.5s position cadence meets the 2s freshness target (SC-003).

**Alternatives**: WebSocket / ActionCable — bidirectional machinery we don't need; heavier per
connection. Rejected for this scope. Polling — defeats the purpose and amplifies load.

**Known limitation (documented, accepted for this iteration)**: each SSE stream holds a Puma
thread, so a single backend process caps at its thread count. Acceptable locally; the multi-server
stateless SSE fleet is the deferred scaling phase.

## 7. Atomicity of batch admission

**Decision**: `ZPOPMIN` is itself atomic for the pop. The follow-on `SADD` to the admitted set and
`PUBLISH` are done immediately after; if the worker crashes between pop and publish, the affected
trainers are admitted-but-unnotified and will be picked up on their next position poll / SSE
reconnect (they're already in `admitted:{raidId}` if SADD ran, else they were popped without admit
— a rare crash window). For stronger guarantees a Lua script bundling POP+SADD+PUBLISH can be
added; deferred because the durable reservation step (claim) is the real correctness boundary.

**Rationale**: Keeps the worker simple; correctness of *capacity* never depends on the worker, only
flow control does.

## 8. Stack versions & tooling

**Decision**: Ruby 3.3 / Rails 7.2 API-only; Postgres 16; Redis 7; Node 20 / Next.js 14 (App
Router) / React 18; RSpec + `database_cleaner` (truncation, for real-concurrency specs) on the
backend; Playwright for a thin frontend E2E. `redis` gem with `connection_pool` (SSE threads +
worker need pooled connections).

**Rationale**: Current stable releases matching the constitution's stack mandate; App Router is the
default Next.js model; truncation strategy (not transactional fixtures) is required so concurrency
specs see each other's committed rows.

**Alternatives**: Rails full stack (not API) — unnecessary, frontend is Next.js. Transactional test
fixtures — would hide the very concurrency the core tests must exercise. Rejected.

## Resolved unknowns

All Technical Context items are decided above; no `NEEDS CLARIFICATION` remain. Tuning parameters
(grace period 120s, default batch 50, claim window, post-start grace) are defaulted here and
surfaced as configuration in `data-model.md` / quickstart.
