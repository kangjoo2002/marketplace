# A-1 Search Outbox Lease Guard Observations

## Results

| Scenario | Result |
| --- | --- |
| Concurrent claim guard | Claim SQL uses `FOR UPDATE SKIP LOCKED`; concurrent claim attempts create distinct `claim_token` values. |
| Stale token transition | `markDone`, `markFailed`, and `markPendingRetry` with a stale `claim_token` are no-op transitions. |
| Stale `PROCESSING` reclaim | Claim SQL includes `PROCESSING` rows where `updated_at` is older than `processingTimeoutMs`. |
| Non-stale `PROCESSING` skip | Claim SQL requires the processing timeout predicate, so recent `PROCESSING` rows are not eligible. |

## Limitations

- The repository does not currently include Testcontainers or another isolated PostgreSQL integration test setup.
- The validation is focused unit coverage around the claim SQL and claim-token fencing behavior.
- No benchmark, OpenSearch load test, indexing lag measurement, or production readiness claim is included.
