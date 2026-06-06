# infra/ — DEFERRED: AWS + Terraform

This directory is a placeholder. Per the constitution, AWS infrastructure is an explicitly
**deferred** phase — the system runs end-to-end via `docker-compose` without it.

When this phase is picked up, the intended target (mirroring the source architecture) is:

| Component | AWS service |
|-----------|-------------|
| Rails API + SSE connection servers | ECS/Fargate behind an ALB (sticky-less; SSE fleet) |
| Admission worker | ECS/Fargate service (separate task — control/data-plane separation) |
| Redis (queue, counters, pub/sub) | ElastiCache for Redis (cluster mode + replicas for failover) |
| PostgreSQL (system of record) | RDS for PostgreSQL (Multi-AZ) |
| Frontend (Next.js) | ECS/Fargate or static export + CloudFront |

Also deferred (future specs): adaptive admission controller, section-based pub/sub seat maps,
and a durable recovery log (Kafka/Kinesis/DynamoDB) to rebuild queue state after Redis loss.

No resources are defined here yet — intentionally.
