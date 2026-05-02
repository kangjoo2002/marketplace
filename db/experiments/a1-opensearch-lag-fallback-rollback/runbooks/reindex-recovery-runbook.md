# OpenSearch Reindex Recovery Runbook

This runbook documents the recovery path for the product search read model after
the local mapping, outbox relay, backfill, catch-up, dual-run, and operations
smoke validations.

PostgreSQL remains the source of truth. OpenSearch is a search read model. This
runbook is documentation only; it does not implement a production reindex
system.

## When To Create A New Physical Index

Create a new physical index when the document contract, mapping, analyzer
settings, or backfill strategy changes in a way that cannot be safely applied
in place.

Use a new versioned physical index name:

```text
products_search_v<N>
```

Local smoke scripts must continue to use isolated smoke names and must not touch
generic application aliases.

## Apply The Selected Mapping

Apply the selected nested mapping from:

```text
db/experiments/a1-opensearch-index-mapping-alias/mappings/products_v1_nested.json
```

Evidence:

- `db/experiments/a1-opensearch-index-mapping-alias/README.md`
- `db/experiments/a1-opensearch-index-mapping-alias/observations.md`

The selected `options: nested` mapping preserves same-option-row semantics.

## Backfill Into The New Index

Point the write alias to the new physical index and run checkpoint-based
backfill into that index.

Required checks:

- checkpoint is written during the run
- resume from checkpoint succeeds
- failed batch count is `0`
- retried batch count is `0` for the local smoke gate
- source/index count validation passes
- missing document count is `0`
- extra document count is `0`
- sample document mismatch count is `0`

Evidence:

- `db/experiments/a1-opensearch-backfill-checkpoint/README.md`
- `db/experiments/a1-opensearch-backfill-checkpoint/observations.md`

Backfill duration and throughput are local smoke metrics only, not production
throughput claims.

## Run Catch-up Replay

Record the backfill high-watermark before backfill starts:

```text
backfill_start_outbox_id = max(search_outbox.id)
```

After backfill, replay:

```text
search_outbox.id > backfill_start_outbox_id
```

Required checks:

- pending after replay is `0`
- failed after replay is `0`
- replayed event count matches the controlled smoke fixture

Evidence:

- `db/experiments/a1-opensearch-catchup-dualrun/README.md`
- `db/experiments/a1-opensearch-catchup-dualrun/observations.md`

## Run Static DB/Search Comparison

Before read-path switch, run a static PostgreSQL versus OpenSearch comparison
against representative exact-filter queries.

Required checks:

- mismatch count is `0`
- mismatch ratio is `0`
- missing in search count is `0`
- extra in search count is `0`
- ordering mismatch count is `0`
- stale by updated_at count is `0`

Evidence:

- `db/experiments/a1-opensearch-catchup-dualrun/results/20260502_145444/`

## Check Operations Gates

Before switching the read path, check the operations smoke gates:

- p95 event lag
- max event lag
- pending event count after recovery
- oldest pending age after recovery
- failed event count
- retry count
- alias switch success
- rollback success
- previous index retained

The thresholds in this experiment are local smoke validation gates, not
production SLA/SLO.

Evidence:

- `db/experiments/a1-opensearch-lag-fallback-rollback/README.md`
- `db/experiments/a1-opensearch-lag-fallback-rollback/observations.md`

## Switch Aliases

After mapping, backfill, catch-up replay, DB/Search comparison, and operations
gates pass, move read aliases to the new physical index:

```text
products_search_read
products_search_current
```

The write alias behavior depends on rollout stage:

- during backfill, write can point to the new physical index
- during steady state, relay writes must target the accepted write alias
- do not switch read/current aliases until validation passes

Alias operations should be atomic through the OpenSearch `_aliases` API.

## Roll Back Aliases

If validation or early read-path switch checks fail, move read/current aliases
back to the previous physical index using one `_aliases` request.

Rollback must verify:

- read alias returns the previous index marker or expected document set
- current alias points back to the previous accepted index
- new index remains retained for diagnosis unless it must be removed for safety

## Previous Index Retention

Retain the previous index through the read-path switch validation window so that
alias rollback remains possible.

The exact production retention duration is intentionally not defined here. A
future production migration plan must choose the retention window from
operational constraints, disk budget, and rollback policy.

For local smoke validation, previous index retention means both isolated smoke
physical indexes still exist after alias rollback.

## Cleanup Old Indexes

Clean up old indexes only after:

- read/current aliases have been stable for the chosen retention window
- fallback and rollback checks are no longer relying on the old index
- retained artifacts identify which index was accepted
- operators have confirmed cleanup scope

Do not delete indexes by broad prefix in scripts that can touch non-smoke
resources.

