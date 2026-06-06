<!-- SPECKIT START -->
Active feature: **001-raid-lobby-queue** — virtual waiting queue + reservation for high-demand
Pokémon GO raid lobby slots.

Read these for full context before working:
- Constitution (non-negotiable principles): `.specify/memory/constitution.md`
- Plan (stack, structure, decisions): `specs/001-raid-lobby-queue/plan.md`
- Spec (requirements): `specs/001-raid-lobby-queue/spec.md`
- Design: `specs/001-raid-lobby-queue/{research,data-model,quickstart}.md`,
  `specs/001-raid-lobby-queue/contracts/`
- Tasks (once generated): `specs/001-raid-lobby-queue/tasks.md`

Stack: Rails 7.2 API (`backend/`), Next.js 14 (`frontend/`), Postgres 16, Redis 7, standalone
admission worker. Local-first via docker-compose; AWS/Terraform deferred.

Non-negotiables: no oversell (capacity enforced in Postgres), strict FIFO fairness (Redis sorted
set), control plane never blocks the claim hot path, concurrency/capacity invariants are
test-first and release-blocking.
<!-- SPECKIT END -->
