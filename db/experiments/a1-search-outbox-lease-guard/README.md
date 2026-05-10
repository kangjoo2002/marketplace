# A-1 Search Outbox Lease Guard Validation

This validation checks the existing search outbox relay lease guard.

Verified behavior:

- claim attempts use PostgreSQL `FOR UPDATE SKIP LOCKED`
- each claim attempt receives a fresh `claim_token`
- stale `PROCESSING` rows are eligible for reclaim after `processingTimeoutMs`
- non-stale `PROCESSING` rows are not eligible for reclaim
- state transitions are fenced by `id`, `status = PROCESSING`, and `claim_token`
- stale workers that complete late do not overwrite the current claim holder

Coordination mechanism:

- PostgreSQL row locking prevents active workers from claiming the same eligible row at the same time.
- `claim_token` fences late state transitions from old workers after a row is reclaimed.

This is local validation of the current guardrail behavior. It is not a production distributed systems claim, benchmark, indexing lag measurement, or OpenSearch performance test.
