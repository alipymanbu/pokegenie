# Feature Specification: Raid Lobby Waiting Queue & Reservation

**Feature Branch**: `001-raid-lobby-queue`

**Created**: 2026-06-06

**Status**: Draft

**Input**: User description: "Virtual waiting queue and reservation system for high-demand Pokémon GO raid lobby slots. A raid instance has a fixed slot capacity; trainers queue for one of N slots in a specific raid at a specific time and location. Core iteration: fair FIFO queue, real-time position/admission updates, capacity-correct reservation. Adaptive admission control, section pub/sub, durable recovery log, and production-scale connection fleet are deferred."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Fairly reserve a slot in a high-demand raid (Priority: P1)

A trainer wants to join a specific, popular raid that has far more interested trainers than
available lobby slots. They open the raid, join the waiting line, wait their turn, and — when
admitted — claim one of the limited slots. If slots are still available when it is their turn,
they receive a confirmed reservation; if the raid fills before their turn, they are told it is
full. The order in which trainers are served matches the order in which they joined the line.

**Why this priority**: This is the entire reason the system exists — fairly converting a large
waiting crowd into a bounded set of confirmed reservations without overselling. Everything else
is in service of this flow.

**Independent Test**: Create a raid with capacity N, have more than N trainers join the line in
a known order, run admission to completion, and verify that exactly N trainers (the first N to
join) receive confirmed reservations and the rest are told the raid is full — with no trainer
holding more than one slot and no slot held by more than one trainer.

**Acceptance Scenarios**:

1. **Given** a raid with 20 open slots and 100 trainers in the waiting line, **When** admission
   runs to completion, **Then** exactly the first 20 trainers (by join time) hold confirmed
   reservations and the remaining 80 are told the raid is full.
2. **Given** a trainer who has been admitted and an available slot, **When** they claim a slot,
   **Then** they receive a confirmed reservation and the raid's remaining-slot count decreases
   by exactly one.
3. **Given** an admitted trainer whose claim arrives after the last slot was taken, **When**
   they attempt to claim, **Then** the claim is rejected with a clear "raid full" result and no
   reservation is created.
4. **Given** a trainer who already holds a confirmed reservation for a raid, **When** the same
   claim is submitted again (e.g. a retry), **Then** the result is the same single reservation
   and no second slot is consumed.

---

### User Story 2 - See my position in line in real time (Priority: P2)

While waiting, a trainer wants continuous feedback on where they stand — their current position
in line and roughly how the line is moving — so they know whether to keep waiting. When it
becomes their turn, they are notified immediately that they have been admitted and may claim a
slot.

**Why this priority**: Without live feedback, a waiting crowd refreshes and rage-clicks, which
both harms the experience and amplifies load. Position visibility is what makes a long wait
tolerable, but it depends on the P1 queue existing first.

**Independent Test**: Place several trainers in line, advance admission a few times, and verify
each waiting trainer receives position updates that only ever decrease (or hold), and that an
admitted trainer receives an "admitted" notification without polling.

**Acceptance Scenarios**:

1. **Given** a trainer waiting at position 5,000, **When** trainers ahead of them are admitted,
   **Then** they receive updated positions that monotonically approach the front of the line.
2. **Given** a waiting trainer, **When** they reach the front and are admitted, **Then** they
   receive an admission notification in real time, without manually refreshing.
3. **Given** a trainer at the front of an empty-ahead line, **When** they view their status,
   **Then** their reported position reflects that they are first to be served.

---

### User Story 3 - Keep my place after a disconnect (Priority: P3)

A trainer on an unreliable mobile connection briefly drops offline and reconnects. They expect
to resume at the same place in line they held before, not to be sent to the back or to lose a
reservation they already secured.

**Why this priority**: Mobile drops are common for the target audience, and losing one's place
on a reconnect is perceived as deeply unfair — it undermines the core fairness promise. It is
P3 only because the queue and live updates must exist before reconnection can be meaningful.

**Independent Test**: Put a trainer in line at a known position, simulate a disconnect and
reconnect using their preserved identity, and verify they resume at the same position (adjusted
only for trainers admitted in the interim) rather than rejoining at the back.

**Acceptance Scenarios**:

1. **Given** a trainer at position 1,200 who disconnects, **When** they reconnect within the
   allowed window using their preserved place-holding identity, **Then** they resume at their
   original relative position, not at the back of the line.
2. **Given** a trainer who already holds a confirmed reservation and disconnects, **When** they
   reconnect, **Then** their reservation is still intact.
3. **Given** a trainer who abandons the line and exceeds the allowed reconnection window,
   **When** they return, **Then** they are treated as a new arrival and join at the back.

---

### User Story 4 - Organize a raid with limited slots (Priority: P3)

An organizer sets up a raid as a bookable event: they define which raid (boss/gym), where, when
it starts, and how many lobby slots are available. Once published, trainers can begin queuing.

**Why this priority**: The system needs raids to exist before anyone can queue, but in the core
iteration raids can be seeded by a small number of organizers/admins, so rich organizer tooling
is lower priority than the trainer-facing flows.

**Independent Test**: Create a raid with a defined capacity, location, and start time, publish
it, and verify trainers can join its waiting line and that admission respects the defined
capacity.

**Acceptance Scenarios**:

1. **Given** an organizer, **When** they create a raid with capacity N, a location, and a start
   time, **Then** the raid becomes available for trainers to queue for.
2. **Given** a published raid, **When** its capacity is set to N, **Then** no more than N
   confirmed reservations can ever exist for it.

---

### Edge Cases

- **Last-slot contention**: Multiple admitted trainers attempt to claim the final remaining slot
  at the same instant — exactly one succeeds; the others receive a clear "raid full" result.
- **Double submission**: A trainer's claim is submitted twice (retry, double-tap) — the trainer
  ends with exactly one reservation.
- **Admission with no slots left**: The line still has waiting trainers but all slots are taken —
  remaining trainers are informed the raid is full rather than being admitted into nothing.
- **Joining an already-full raid**: A trainer tries to join the line for a raid that is already
  full — they are told it is full instead of being placed in a line that can never serve them.
- **Empty line**: Admission runs against a raid whose line is empty — it completes with no
  effect and no error.
- **Reconnect after the window**: A trainer returns after the reconnection grace period — they
  rejoin at the back as a new arrival (see US3 AS-3).
- **Raid start time reached**: The raid's start time arrives — behavior for late claims is
  governed by an assumption below (see Assumptions).
- **Coordinator unavailable**: The component that tunes admission pacing is unavailable —
  trainers continue to be admitted at a safe default pace; reservations remain correct.
- **Duplicate join**: A trainer who is already in line joins again — they retain a single place
  at their original position rather than gaining a second.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST allow a trainer to join the waiting line for a specific raid and
  receive a place-holding identity that represents their position.
- **FR-002**: System MUST order the waiting line strictly by the time each trainer joined, and
  MUST serve trainers for admission in that order (first-in, first-out).
- **FR-003**: System MUST allow a trainer to retrieve their current position in line at any time
  while waiting.
- **FR-004**: System MUST push position updates and an admission notification to waiting trainers
  in real time, without requiring them to manually refresh or repeatedly poll.
- **FR-005**: System MUST admit waiting trainers in controlled batches sized so that the booking
  step is not overwhelmed, rather than admitting the entire line at once.
- **FR-006**: System MUST allow an admitted trainer to claim one available slot in the raid and,
  on success, record a confirmed reservation for them.
- **FR-007**: System MUST guarantee that the number of confirmed reservations for a raid never
  exceeds that raid's defined slot capacity, even under simultaneous claims (no overselling).
- **FR-008**: System MUST ensure a trainer holds at most one confirmed reservation per raid, and
  that repeating the same claim does not consume an additional slot (idempotent claim).
- **FR-009**: System MUST reject a claim with a clear "raid full" result when no slots remain,
  without creating a reservation.
- **FR-010**: System MUST preserve a disconnecting trainer's place in line for a defined grace
  period and restore their original relative position when they reconnect using their
  place-holding identity.
- **FR-011**: System MUST keep an already-confirmed reservation intact across a trainer's
  disconnect and reconnect.
- **FR-012**: System MUST allow an organizer to create and publish a raid defined by its raid
  identity (boss/gym), location, start time, and slot capacity.
- **FR-013**: System MUST prevent a trainer from joining the line for a raid that is already full
  and inform them it is full.
- **FR-014**: System MUST treat a trainer who returns after the reconnection grace period has
  elapsed as a new arrival placed at the back of the line.
- **FR-015**: System MUST continue admitting trainers at a safe, conservative default pace if the
  component responsible for tuning admission pacing is unavailable, without violating capacity or
  ordering guarantees.
- **FR-016**: System MUST expose operational measurements of waiting-line depth, admission rate,
  and reservation-conflict rate (claims rejected because no slot was available), and MUST record
  any attempt that would have exceeded capacity as a high-severity event.

### Key Entities *(include if feature involves data)*

- **Raid**: A bookable raid event. Key attributes: which raid (boss/gym identity), location,
  start time, total slot capacity, and current count of remaining/confirmed slots. The authority
  on capacity.
- **Trainer**: A participant who can join lines and hold reservations. Key attribute: a stable
  identity used to preserve their place across disconnects.
- **Queue Entry**: A trainer's place in a specific raid's waiting line. Key attributes: the
  trainer, the raid, the join time (which defines order), and a place-holding identity/token used
  for reconnection.
- **Reservation**: A confirmed claim by a trainer on one slot of a raid. Key attributes: the
  trainer, the raid, and confirmation status. At most one active reservation per trainer per raid;
  total active reservations per raid never exceed capacity.
- **Admission Pacing Setting**: The current batch size / rate at which the next waiting trainers
  are admitted. Influenced by an optional coordinator; has a safe default when absent.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For any raid, the count of confirmed reservations never exceeds its slot capacity —
  zero oversell events across all tested contention scenarios.
- **SC-002**: When more trainers than slots compete, the trainers who receive reservations are
  exactly the earliest joiners — admission order matches join order in 100% of tested runs.
- **SC-003**: A waiting trainer sees their position update within 2 seconds of the line advancing
  past them, and receives their admission notification within 2 seconds of being admitted.
- **SC-004**: A trainer who reconnects within the grace period resumes at their original relative
  position in 100% of tested reconnection runs (no place lost, no reservation lost).
- **SC-005**: Submitting the same slot claim multiple times results in exactly one reservation in
  100% of tested duplicate-submission runs.
- **SC-006**: The system continues to admit trainers and confirm reservations correctly while the
  admission-pacing coordinator is unavailable (graceful degradation, no correctness violation).
- **SC-007**: Operators can observe live waiting-line depth, admission rate, and conflict rate for
  any active raid.

## Assumptions

- **Scale target vs. core iteration**: The architecture is designed for very large waiting lines
  (millions of concurrent waiters as a north star), but this core iteration is validated for
  correctness and real-time behavior at a representative scale on a single local environment;
  production-scale connection fleets and load are a deferred phase.
- **Auto-assigned slots, not seat selection**: In this iteration an admitted trainer claims "a
  slot" in the raid; there is no per-seat selection or seat map. (Seat-map / section browsing is
  explicitly deferred.)
- **Reconnection grace period**: A finite, configurable grace period governs how long a
  disconnected trainer keeps their place; its exact value is a tuning parameter, defaulted
  conservatively.
- **Late claims after start time**: Once a raid's start time has passed, the raid is considered
  closed to new claims; trainers admitted but not yet confirmed at that point are told the raid
  has started. (Exact post-start grace is a tuning parameter.)
- **Trainer identity**: A trainer has some stable identity (e.g. an account or device-bound
  token) sufficient to preserve their place across reconnects; full account management and
  authentication hardening are assumed to be provided/owned elsewhere and are not the focus of
  this iteration.
- **One line per raid**: Each raid has a single waiting line; a trainer may participate in lines
  for different raids independently.
- **Deferred scope** (documented per constitution): adaptive admission controller logic,
  section-based real-time seat maps, durable recovery log for rebuilding queue state, and the
  multi-server real-time connection fleet at production scale are out of scope for this iteration.
