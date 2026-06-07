# Feature Specification: Elastic Raid Encounters (auto-assigned rooms)

**Branch**: `001-raid-lobby-queue` (built on the existing core) · **Created**: 2026-06-07 · **Status**: Draft

## Summary

Instead of trainers picking a specific fixed-capacity room, they queue against an **Encounter**
(one Pokémon at one time/place, e.g. "Mewtwo @ 8pm"). The system admits them in fair FIFO order
and **auto-assigns each admitted trainer to a room with space, elastically spawning new rooms**
(each of `room_size`, e.g. 20) as needed. There is no "raid full" — supply expands to meet demand;
scarcity becomes wait time, not rejection. This is the article's "staff-level insight": don't make
users pick a seat — let them pick the thing they want and auto-assign the best available slot.

## User Stories

### US-E1 — Queue for a Pokémon and get auto-placed in a room (P1)
A trainer joins an Encounter's line, waits their turn, and on admission is **automatically placed
in a room** (room #1, #2, …). They claim their spot in that room. They never choose a room.

**Acceptance**:
1. Given an Encounter with room_size 20 and 50 trainers queued, when admission runs to completion,
   then 3 rooms exist (20 + 20 + 10), each with ≤ 20 confirmed, and every trainer is placed.
2. Given an admitted trainer assigned to room K, when they claim, then they get a confirmed
   reservation in room K and that room never exceeds room_size.
3. There is no "encounter full" rejection — a new room spawns whenever the open room is full.

### US-E2 — Real-time position + room assignment (P2)
While waiting the trainer sees live position; on admission they're told **which room** they got,
over SSE (reuses the existing stream mechanics).

### US-E3 — Organizer creates an Encounter (P3)
An organizer creates/publishes an Encounter (boss, label, start time, room_size). Rooms are
created by the system, not the organizer.

## Key entities

- **Encounter**: one Pokémon at one time/place. Attributes: boss, label, starts_at, room_size,
  status (draft/published/closed). Owns many rooms. Has a single FIFO waiting line.
- **Room**: a `Raid` with `encounter_id` + `room_number`, `capacity = room_size`. Reuses all
  existing room/claim/reservation machinery (per-room no-oversell stays exact).
- **Assignment**: which room an admitted trainer was placed in (until they claim or it lapses).

## Functional requirements

- **FE-001**: A trainer MUST be able to join an Encounter's FIFO line (not a specific room).
- **FE-002**: Admission MUST assign each admitted trainer to a room with available assignment
  space, in FIFO order, spawning a new room of `room_size` when the open room is full.
- **FE-003**: A room MUST NEVER hold more confirmed reservations than `room_size` (per-room
  no-oversell — inherited from the core claim transaction).
- **FE-004**: The system MUST NOT reject a trainer for lack of capacity (elastic); waiting is the
  only scarcity.
- **FE-005**: On admission the trainer MUST be told their assigned room (number + id) in real time.
- **FE-006**: An admitted trainer MUST be able to claim their spot in their assigned room; the
  per-trainer claim window (FR from core) applies; a lapsed window frees the assignment slot.
- **FE-007**: An organizer MUST be able to create + publish an Encounter; rooms are system-created.

## Success criteria

- **SC-E1**: For N trainers and room_size R, after full admission the number of rooms is
  ceil(assigned/R), each room ≤ R confirmed, zero oversold rooms.
- **SC-E2**: No trainer is ever rejected for capacity; every joined trainer is admitted (given time).
- **SC-E3**: Assigned-room is delivered to the client within ~2s of admission.

## Design notes / decisions

- **Rooms = Raid (encounter_id set)** → reuse claim/reservation/no-oversell unchanged. Standalone
  raids (encounter_id null) keep working (backward compatible with feature 001).
- **Single admission worker** assigns rooms (no cross-process race): per encounter it tracks the
  open room + assigned count in Redis; when assigned == room_size it spawns the next room.
- **Claim reuses** `POST /raids/:roomId/reservations` (the room is a Raid). The admitted SSE event
  carries the room id.
- **Out of scope (v1)**: backfilling AFK no-show slots into later rooms; per-room start staggering;
  a hard cap on total rooms. Documented for a future iteration.
