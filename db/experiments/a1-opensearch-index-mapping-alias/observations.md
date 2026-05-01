# PR-A17 Observations

## Current Status

PR-A17 OpenSearch mapping smoke validation passed against the experiment-local Docker OpenSearch service.

Local smoke service:

```text
opensearchproject/opensearch:2.15.0
```

Generated artifact path:

```text
db/experiments/a1-opensearch-index-mapping-alias/results/20260501_210124/
```

## Mapping Validation Result

Pass.

Commands run:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml up -d
```

OpenSearch container health became:

```text
healthy
```

```powershell
$env:OPENSEARCH_URL = "http://localhost:9200"
$env:OPENSEARCH_IMAGE = "opensearchproject/opensearch:2.15.0"
.\db\experiments\a1-opensearch-index-mapping-alias\scripts\run-opensearch-mapping-smoke.ps1
```

Result:

```text
PASS: OpenSearch mapping smoke validation completed
```

Teardown was run after artifact generation:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml down -v
```

## Index Creation Result

Pass.

The smoke script created only:

```text
products_search_a17_smoke_nested_v1
products_search_a17_smoke_flattened_v1
```

## Alias Creation Result

Pass.

The smoke script created isolated aliases:

```text
products_search_a17_smoke_read
products_search_a17_smoke_write
products_search_a17_smoke_current
```

The documented future application aliases remain:

```text
products_search_read
products_search_write
products_search_current
```

## Sample Document Indexing Result

Pass.

Fixture:

```text
fixtures/sample-product-options.json
```

## Option Mapping Candidate Comparison

Candidate 1:

- `options` as an OpenSearch `object`
- used only as an unsafe contrast
- expected to match the negative fixture query because object arrays are flattened across rows

Candidate 2:

- `options` as OpenSearch `nested`
- selected representation
- expected to preserve same-option-row semantics when queried with a single nested query containing all option predicates

## Option Same-row False Positive Count

Measured by real OpenSearch smoke queries.

Observed smoke result with the included fixture:

| candidate | query | observed hits |
|---|---|---:|
| nested | `BLACK / M / IN_STOCK` | 0 |
| nested | `BLACK / S / IN_STOCK` | 1 |
| object-array flattened | `BLACK / M / IN_STOCK` | 1 false positive |

Flattened/object false positive count:

```text
1
```

## Selected Option Representation

Selected:

```text
options: nested
```

Reason:

The product search option filter requires `color`, `size`, and `stockStatus` to exist in the same option row. A nested mapping plus a single nested bool query preserves that tuple boundary. Object-array flattened behavior does not.

## Limitations

- Smoke validation used a minimal local Docker fixture only.
- This PR does not prove production performance or capacity.
- This PR does not run k6.
- This PR does not switch the API to OpenSearch.
- This PR does not implement backfill, outbox, relay, or incremental sync.
- PostgreSQL remains the source of truth.

## Next Step

After this mapping contract is accepted, PR-A18 should implement outbox plus relay work against the nested option document shape.
