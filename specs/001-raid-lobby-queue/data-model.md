# Phase 1 Data Model: Raid Lobby Waiting Queue

Two stores with clear ownership:
- **PostgreSQL** = durable system of record (raids, trainers, reservations + the capacity
  invariant).
- **Redis** = ephemeral coordination (FIFO line, admitted set, reconnect tokens, metric counters,
  Pub/Sub). Rebuildable; losing it loses queue *positions*, never reservations.

## PostgreSQL schema

### `trainers`
| Column | Type | Notes |
|--------|------|-------|
| id | bigint PK | |
| handle | citext UNIQUE | trainer display name / stable identity |
| created_at, updated_at | timestamptz | |

### `raids`
| Column | Type | Notes |
|--------|------|-------|
| id | bigint PK | |
| boss | text NOT NULL | raid boss / which raid |
| gym_name | text NOT NULL | location |
| latitude, longitude | numeric | optional location coords |
| starts_at | timestamptz NOT NULL | raid start time |
| capacity | integer NOT NULL | `CHECK (capacity > 0)` — total slots |
| slots_remaining | integer NOT NULL | `CHECK (slots_remaining >= 0)` and `CHECK (slots_remaining <= capacity)`; initialized to `capacity` |
| status | text NOT NULL | `draft` / `published` / `closed`; default `draft` |
| created_at, updated_at | timestamptz | |

`slots_remaining` is the **capacity invariant carrier**. It is only ever changed by the guarded
atomic decrement in the claim transaction (and incremented if a reservation is released — out of
scope this iteration). The two CHECK constraints make oversell impossible at the data layer.

### `reservations`
| Column | Type | Notes |
|--------|------|-------|
| id | bigint PK | |
| raid_id | bigint FK → raids | NOT NULL |
| trainer_id | bigint FK → trainers | NOT NULL |
| status | text NOT NULL | `confirmed` (default); `released` reserved for future |
| created_at, updated_at | timestamptz | |

**Constraints (correctness-critical):**
- `UNIQUE (raid_id, trainer_id)` — at most one reservation per trainer per raid → idempotent
  claim (FR-008).
- FK `raid_id`, `trainer_id` with `ON DELETE RESTRICT`.

**Invariants (enforced / asserted):**
- INV-1 (no oversell): `count(reservations where raid_id = R and status='confirmed') == R.capacity - R.slots_remaining` and `slots_remaining >= 0`. Enforced by the transactional claim + CHECK.
- INV-2 (idempotency): unique index above.

## Redis keyspace

| Key | Type | Purpose | Lifetime |
|-----|------|---------|----------|
| `seq:{raidId}` | string (INCR) | monotonic score allocator → strict FIFO | life of raid |
| `queue:{raidId}` | sorted set | the waiting line; member=`trainerId`, score=sequence | until drained |
| `admitted:{raidId}` | set | trainers currently admitted & allowed to claim | members expire at claim-window TTL (or set-level housekeeping) |
| `token:{queueToken}` | string (JSON) | `{raidId, trainerId, score, joinedAt}` for reconnect | TTL = grace period (default 120s), refreshed on activity |
| `events:{raidId}` | Pub/Sub channel | `admitted` / `raid_full` / `position` push to SSE | n/a |
| `admission:rate:{raidId}` | string (int) | batch size the worker admits per tick | written by deferred controller; **absent ⇒ default 50** |
| `metrics:claims:{raidId}` | string (INCR) | total claim attempts | reset per raid |
| `metrics:conflicts:{raidId}` | string (INCR) | claims rejected "raid full" | reset per raid |
| `metrics:admitted:{raidId}` | string (INCR) | total admitted | reset per raid |

Queue depth is `ZCARD queue:{raidId}` (no separate counter). A trainer's position is
`ZRANK queue:{raidId} {trainerId}` (0-based; display as rank+1).

## Key operations (semantics)

| Operation | Store actions |
|-----------|---------------|
| **Join** (FR-001/002/013) | If raid not `published` or full → reject. `score = INCR seq:{raid}`; `ZADD queue:{raid} NX score trainerId`; if added, mint `token`, `SET token:{token} {...} EX grace`. Return `{token, position=ZRANK+1, depth=ZCARD}`. |
| **Position** (FR-003) | `ZRANK queue:{raid} trainerId` → not found ⇒ either admitted (check `admitted` set) or never joined. |
| **Reconnect** (FR-010/014) | Look up `token:{token}`. Exists ⇒ `ZADD queue:{raid} NX origScore trainerId`, refresh token TTL. Missing ⇒ treat as new Join (back of line). |
| **Admit batch** (FR-005/015) | `batch = GET admission:rate:{raid}` or 50. `members = ZPOPMIN queue:{raid} batch`. `SADD admitted:{raid} members…`; `INCRBY metrics:admitted`; `PUBLISH events:{raid}` one `admitted` per member. If `raids.slots_remaining = 0`: stop, drain remaining members with `raid_full`. Never blocks on the rate key. |
| **Claim** (FR-006/007/008/009) | Verify `SISMEMBER admitted:{raid} trainerId` (else 409 not-admitted). `INCR metrics:claims`. Run the Postgres claim transaction (see research §4). On "full": `INCR metrics:conflicts`, log `error` if it indicates a guarded-update race, return 409 `raid_full`. On success: `SREM admitted:{raid} trainerId`, return reservation. |
| **Metrics** (FR-016) | Read `ZCARD`, the three counters, compute admission/conflict rates over a window. |

## State transitions

**Raid**: `draft → published` (organizer publishes; trainers may queue) `→ closed` (start time
reached or manually closed; no new claims).

**Trainer-in-raid** (logical, derived from Redis + PG):
`not_in_line → waiting (in queue ZSET) → admitted (in admitted set) → confirmed (reservation row)`
with two exits: `waiting → left` (token expired / abandoned) and `admitted → raid_full` (no slots
left at claim).

## Configuration / tuning parameters (with defaults)

| Param | Default | Meaning |
|-------|---------|---------|
| `RECONNECT_GRACE_SECONDS` | 120 | token TTL; how long a place is held across disconnect |
| `ADMISSION_DEFAULT_BATCH` | 50 | fallback batch when `admission:rate:{raid}` absent (Principle III) |
| `ADMISSION_TICK_MS` | 1000 | worker loop interval |
| `CLAIM_WINDOW_SECONDS` | 120 | how long an admitted trainer has to claim before their admit lapses |
| `POSITION_PUSH_MS` | 1500 | SSE position cadence (meets SC-003 ≤2s) |
| `POST_START_GRACE_SECONDS` | 0 | grace for claims after `starts_at` |

## Validation rules (from requirements)

- Join rejected unless `raid.status = published` and `slots_remaining > 0` (FR-013).
- Claim rejected unless trainer ∈ `admitted:{raid}` (flow gate) — capacity still independently
  enforced in PG (defense in depth).
- `capacity > 0`; `0 <= slots_remaining <= capacity` (CHECKs).
- One reservation per (raid, trainer) (UNIQUE).
