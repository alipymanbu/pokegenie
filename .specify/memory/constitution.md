<!--
Sync Impact Report
==================
Version change: (template) → 1.0.0
Bump rationale: Initial ratification of the project constitution (MAJOR baseline).
Modified principles: N/A (initial adoption)
Added sections:
  - Core Principles (8 principles)
  - Technology & Architecture Constraints
  - Development Workflow & Quality Gates
  - Governance
Removed sections: None
Templates requiring updates:
  - .specify/templates/plan-template.md ✅ reviewed (Constitution Check gate aligns)
  - .specify/templates/spec-template.md ✅ reviewed (scope/requirements alignment)
  - .specify/templates/tasks-template.md ✅ reviewed (testing/observability task types)
Follow-up TODOs: None
-->

# PokeGenie Raid Queue Constitution

PokeGenie Raid Queue is a virtual waiting-queue and reservation system for high-demand
Pokémon GO raid lobby slots. A raid instance has a fixed slot capacity; trainers queue for
one of N slots in a specific raid at a specific time and location. These principles are
non-negotiable engineering constraints derived from the system's defining challenge:
fairly admitting a very large number of waiting users to a small, strictly-bounded set of
slots without overselling or collapsing under load.

## Core Principles

### I. Fairness First (NON-NEGOTIABLE)
Admission MUST follow strict first-in-first-out ordering by the user's original queue join
time. A user who disconnects and reconnects MUST retain their original position via a
position-preserving token; reconnection MUST NOT advance or reset their place. No
mechanism may allow queue-jumping. Rationale: perceived and actual fairness is the core
product promise of a waiting queue; any ordering violation under load destroys user trust
and is treated as a correctness bug, not a UX nicety.

### II. Capacity Correctness — No Overselling (NON-NEGOTIABLE)
A raid lobby MUST NEVER hold more confirmed reservations than its slot capacity.
Slot claims MUST be atomic and idempotent: retrying the same claim MUST NOT consume a
second slot, and concurrent claims MUST NOT exceed capacity. Rationale: overselling a
fixed-capacity lobby is an unrecoverable real-world failure; capacity is a hard invariant
that the data layer (not application convention) must enforce.

### III. Control Plane / Data Plane Separation
Admission coordination and rate-control logic (the control plane) MUST NEVER block the
booking/reservation hot path (the data plane). Control-plane components influence the
system by writing tunable values; they MUST be free to fail. If a coordinator is
unavailable, queue workers and the booking service MUST fall back to a safe, conservative
default and continue serving. Rationale: coordination is an optimization, not a dependency;
the booking path must survive coordinator failure.

### IV. Resilience Under Load
The design target is millions of concurrently queued users. The system MUST degrade
gracefully under spikes: apply backpressure (slow or shed admission) rather than collapse.
Hot-path operations MUST be sub-linear in queue size (e.g. O(log N) queue operations).
No design may assume a load ceiling lower than the stated target without documenting the
limit and its mitigation. Rationale: the queue exists precisely for the overload case;
behaving well under overload is the product, not an edge case.

### V. Real-Time Updates via SSE
Server-to-client position and admission updates MUST be delivered over Server-Sent Events
(server→client only — no client→server channel is required for queue status). Clients MUST
support reconnection with a position-preserving token (see Principle I). Connection-holding
servers MUST be stateless so the SSE fleet scales horizontally. Rationale: queue status is
inherently a server-push problem; SSE matches the one-directional need without WebSocket
overhead.

### VI. Test-First for the Core (NON-NEGOTIABLE)
The queue, admission, and reservation core MUST have automated tests written and failing
before implementation. Concurrency and capacity invariants (Principles I and II) MUST be
covered by tests that exercise contention (e.g. concurrent claims against limited capacity,
reconnect-preserves-position). Rationale: the invariants that matter most here only fail
under concurrency, which is exactly what manual testing cannot reliably reproduce.

### VII. Observability as a First-Class Concern
Queue depth, admission rate, reservation conflict rate, and any oversell attempt MUST be
emitted as structured, queryable metrics. An oversell attempt (a claim rejected by the
capacity invariant) MUST be logged at high severity. Rationale: a queue is operated live
during high-stakes events; operators must see contention and fairness/capacity health in
real time to react.

### VIII. Spec-Driven Development
Every feature MUST progress through spec → plan → tasks → implement (this spec-kit
workflow). Scope MUST be explicit and deferrals MUST be documented in the spec. Code that
expands scope beyond the approved spec MUST be flagged and re-specified. Rationale: a
distributed reservation system accumulates accidental complexity quickly; an explicit
scope contract keeps each increment reviewable and deferrals honest.

## Technology & Architecture Constraints

- **Backend**: Ruby on Rails (API mode).
- **Frontend**: Next.js / React.
- **Queue & counters**: Redis (sorted set for the FIFO queue; atomic counters for
  admission/conflict metrics).
- **System of record**: PostgreSQL (raids, slots, confirmed reservations — the durable
  source of truth for the capacity invariant).
- **Local-first delivery**: The system MUST run end-to-end via docker-compose
  (Rails + Postgres + Redis + Next.js). AWS + Terraform infrastructure is an explicitly
  DEFERRED later phase and MUST NOT be a prerequisite for running or testing the system.
- **Deferred scope (out of the initial iteration, documented for future specs)**: adaptive
  admission controller, section-based pub/sub seat maps, Kafka/durable recovery log, and
  the multi-server SSE fleet at production scale. The initial iteration delivers the core
  queue + SSE admission + reservation only.

## Development Workflow & Quality Gates

- All work flows through the spec-kit lifecycle (Principle VIII).
- A change touching the queue, admission, or reservation core MUST NOT merge without tests
  covering the relevant fairness (I) and capacity (II) invariants.
- Plans MUST include a Constitution Check; any principle deviation MUST be justified in the
  plan's Complexity Tracking section or the plan is revised.
- Capacity and fairness invariants are release-blocking: a failing concurrency/capacity
  test blocks merge regardless of feature pressure.

## Governance

This constitution supersedes ad-hoc engineering practices for this project. Amendments
require: a written description of the change, the rationale, and a version bump per the
policy below.

- **Versioning policy** (semantic):
  - MAJOR: backward-incompatible governance or principle removal/redefinition.
  - MINOR: a new principle/section or materially expanded guidance.
  - PATCH: clarifications, wording, or non-semantic refinements.
- **Compliance review**: every plan and pull request affecting the core MUST verify
  compliance with the NON-NEGOTIABLE principles (I, II, VI). Unjustified complexity is
  grounds to reject a change.
- **Runtime guidance**: agent and contributor runtime guidance lives in `CLAUDE.md` and the
  current feature plan; this constitution governs principles, not procedure.

**Version**: 1.0.0 | **Ratified**: 2026-06-06 | **Last Amended**: 2026-06-06
