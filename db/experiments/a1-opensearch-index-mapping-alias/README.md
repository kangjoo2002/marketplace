# A-1e PR-A17 OpenSearch Index Mapping And Alias Design

## Purpose

This experiment defines the first OpenSearch search read model shape for product discovery/ranking work.

It exists after the PostgreSQL normalized path, DB tuned path, and `product_search_documents` read-table work so the next transition PRs can use a documented index contract instead of inventing document fields inside a backfill or relay worker.

This PR validates only mapping shape, alias convention, and option filter semantics with a minimal fixture. PostgreSQL remains the source of truth.

## Scope

This PR includes:

- versioned product search index naming
- read/write/current alias naming
- product search document field coverage
- nested option mapping candidate
- object-array flattened candidate used as an unsafe contrast
- minimal same-option-row fixture
- OpenSearch query files
- local smoke validation scripts

This PR excludes:

- API read-path switch
- backfill
- incremental sync
- outbox table
- relay worker
- DB fallback
- k6
- benchmark claims
- relevance tuning
- synonyms
- typo tolerance
- autocomplete
- advanced analyzers

This is not a production capacity claim.

## Index Naming

Versioned physical indexes:

```text
products_search_v1
products_search_v2
```

The version suffix changes when the document contract or mapping requires a rebuild. A future blue/green reindex creates `products_search_v2`, loads it through the write alias, validates it, then moves read/current aliases.

The local smoke script uses isolated test names derived from:

```text
products_search_a17_smoke
```

This avoids deleting or replacing real `products_search_v*` indexes during local validation.

## Alias Naming

Alias convention:

| alias | intended use |
|---|---|
| `products_search_read` | product search API read queries after a later API switch PR |
| `products_search_write` | backfill/relay indexing target in later PRs |
| `products_search_current` | operator-visible pointer to the currently accepted physical index |

For a future `v1` rollout, all three aliases initially point to `products_search_v1`. During a future blue/green migration, `products_search_write` can point to the next physical index while `products_search_read` stays on the current index until validation passes.

## Product Document Shape

Minimum product document fields for current API filtering, sorting, and response mapping:

| field | type | reason |
|---|---|---|
| `productId` | `long` | API `id`, stable tie-break sort |
| `sellerId` | `long` | API response field |
| `categoryId` | `long` | exact filter |
| `brandId` | `long` | exact filter |
| `status` | `keyword` | exact filter, current API enum |
| `price` | `integer` | range filter and `priceAsc`/`priceDesc` sort |
| `rating` | `scaled_float` | API response field |
| `reviewCount` | `integer` | API response and `reviewCountDesc` sort |
| `createdAt` | `date` | API response and `createdAtDesc` sort |
| `updatedAt` | `date` | API response |
| `sourceUpdatedAt` | `date` | source freshness metadata for later sync validation |
| `documentRefreshedAt` | `date` | read model refresh metadata |
| `options.color` | `keyword` | option exact filter |
| `options.size` | `keyword` | option exact filter |
| `options.stockStatus` | `keyword` | option exact filter |

Current API response mapping:

| API field | OpenSearch field |
|---|---|
| `id` | `productId` |
| `sellerId` | `sellerId` |
| `categoryId` | `categoryId` |
| `brandId` | `brandId` |
| `status` | `status` |
| `price` | `price` |
| `rating` | `rating` |
| `reviewCount` | `reviewCount` |
| `createdAt` | `createdAt` |
| `updatedAt` | `updatedAt` |

No full-text fields are added in this PR because the current API behavior is filter/sort oriented.

## Option Representation Candidates

### Candidate 1: Object-array flattened behavior

File:

```text
mappings/products_v1_flattened_candidate.json
```

This candidate maps `options` as an `object` containing exact keyword fields. OpenSearch object arrays are flattened internally. A bool filter such as:

```text
options.color = BLACK
options.size = M
options.stockStatus = IN_STOCK
```

can match when those values exist in different option rows of the same product document.

This behavior is unsafe for the product option semantics in this project.

OpenSearch `flat_object` is not selected for option filters here. The option shape is known and enum-like, and the required behavior is tuple/row matching, not arbitrary key/value flattening.

### Candidate 2: Nested options

File:

```text
mappings/products_v1_nested.json
```

This candidate maps `options` as `nested`. Option filters must be emitted inside one `nested` query with `path: "options"` and all option predicates inside the same nested bool filter.

This preserves same-option-row semantics.

Selected representation:

```text
options: nested
```

## Same-option-row Fixture

File:

```text
fixtures/sample-product-options.json
```

Product A:

```text
productId = 1
status = ACTIVE
options:
  BLACK / S / IN_STOCK
  WHITE / M / IN_STOCK
```

Validation query:

```text
color = BLACK
size = M
stockStatus = IN_STOCK
```

Expected result:

```text
nested candidate: 0 hits
object-array flattened candidate: false positive risk, expected 1 hit with this fixture
```

Positive nested control:

```text
color = BLACK
size = S
stockStatus = IN_STOCK
```

Expected result:

```text
nested candidate: 1 hit
```

## Validation Commands

Start the PR-A17 local OpenSearch smoke service:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml up -d
```

This repository's root `docker-compose.yml` only defines PostgreSQL, so this PR keeps OpenSearch in an experiment-local compose file:

```text
db/experiments/a1-opensearch-index-mapping-alias/docker-compose.opensearch-smoke.yml
```

The smoke compose file uses:

```text
opensearchproject/opensearch:2.15.0
```

It is a single-node, no-auth, local-only smoke environment. It is not a production deployment shape and is not a capacity test.

Wait until the container is healthy, then run the smoke script.

PowerShell:

```powershell
$env:OPENSEARCH_URL = "http://localhost:9200"
.\db\experiments\a1-opensearch-index-mapping-alias\scripts\run-opensearch-mapping-smoke.ps1
```

Bash:

```bash
OPENSEARCH_URL=http://localhost:9200 \
  ./db/experiments/a1-opensearch-index-mapping-alias/scripts/run-opensearch-mapping-smoke.sh
```

Tear down the smoke container and smoke volume:

```powershell
docker compose -f db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml down -v
```

The scripts are safe to rerun. They delete only indexes whose names are derived from the local smoke prefix:

```text
products_search_a17_smoke_nested_v1
products_search_a17_smoke_flattened_v1
```

## Expected Validation Result

Expected smoke result:

| check | expected |
|---|---:|
| nested negative same-row query | 0 hits |
| nested positive same-row query | 1 hit |
| flattened/object negative query | 1 hit false positive |

The smoke script writes result artifacts only after all checks pass.

## Generated Artifacts

When validation succeeds, the script writes:

```text
results/<timestamp>/mapping-smoke-summary.md
results/<timestamp>/healthcheck-result.json
results/<timestamp>/nested-index-create-result.json
results/<timestamp>/alias-create-result.json
results/<timestamp>/alias-verification-result.json
results/<timestamp>/nested-document-index-result.json
results/<timestamp>/nested-negative-query-result.json
results/<timestamp>/nested-positive-query-result.json
results/<timestamp>/flattened-index-create-result.json
results/<timestamp>/flattened-document-index-result.json
results/<timestamp>/flattened-query-result.json
```

If OpenSearch is unavailable or validation fails, no result directory is created by the script.

## Limitations

- Minimal fixture only.
- No capacity or latency claim.
- No k6 run.
- No API switch.
- No backfill.
- No outbox or relay sync.
- No production analyzer design.
- No relevance tuning.
- Alias swap behavior is documented but not integrated into deployment code.

## Next Step

PR-A18 should add the outbox plus relay design around this selected nested document contract. Backfill and API switching remain separate later PRs.
