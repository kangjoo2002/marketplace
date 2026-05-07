# 상품 검색 읽기 경로 최종 결과 요약

## 요약

이 문서는 Product Search Read Path 최적화 결과를 요약한다. 기존 로컬 benchmark, k6 summary, DB experiment, OpenSearch smoke validation artifact를 한 곳에 모아 이후 Portfolio Root README PR에서 링크할 기준 문서로 사용하기 위한 것이다.

이 문서는 production readiness 보고서가 아니다. 결과는 로컬 Docker 기반 synthetic benchmark와 smoke gate 검증에 한정되며, production capacity, SLA, SLO를 주장하지 않는다.

## 완료 단계 요약

| 순서 | 단계 | 목적 | 주요 근거 artifact |
|---:|---|---|---|
| 1 | products single-table filtering baseline | `products_*` 단일 테이블 필터링 baseline EXPLAIN 확인 | `db/experiments/a1-products-baseline-explain/observations.md` |
| 2 | products index and pagination tuning | 단일 컬럼, composite, partial index와 keyset pagination 후보 비교 | `db/experiments/a1-products-single-column-index-attempts/observations.md`, `db/experiments/a1-products-composite-index-comparison/observations.md`, `db/experiments/a1-products-partial-index-comparison/observations.md`, `db/experiments/a1-products-keyset-pagination-comparison/observations.md` |
| 3 | product_options JOIN + DISTINCT bottleneck | `products` + `product_options` JOIN, DISTINCT, OFFSET baseline 병목 확인 | `db/experiments/a1-product-options-join-baseline-explain/observations.md` |
| 4 | product_options index attempts | option filter index 후보 비교 | `db/experiments/a1-product-options-index-attempts/observations.md` |
| 5 | EXISTS rewrite | JOIN/DISTINCT 중심 쿼리를 `EXISTS` option filtering으로 비교 | `db/experiments/a1-product-options-exists-rewrite-comparison/observations.md` |
| 6 | EXISTS + keyset pagination | JOIN/EXISTS 계열에서 keyset pagination 후보 확인 | `db/experiments/a1-join-keyset-pagination/observations.md` |
| 7 | denormalized DB read model | PostgreSQL 내부 read table로 read-time JOIN/EXISTS 의존 제거 검증 | `db/experiments/a1-product-search-denormalized-read-table/README.md`, `db/experiments/a1-product-search-denormalized-read-table/observations.md` |
| 8 | OpenSearch mapping / alias | `options.type = nested` 선택과 read/write/current alias smoke 검증 | `db/experiments/a1-opensearch-index-mapping-alias/results/20260501_210124/mapping-smoke-summary.md` |
| 9 | search_outbox transactional capture | 상품 변경과 outbox event가 같은 transaction에 묶이는지 검증 | `db/experiments/a1-search-outbox-transactional-capture/results/20260501_235850/search-outbox-transaction-summary.md` |
| 10 | outbox relay sync | outbox event 처리, OpenSearch upsert/delete, idempotent replay 검증 | `db/experiments/a1-outbox-relay-opensearch-sync/results/20260502_111326/outbox-relay-summary.md` |
| 11 | backfill checkpoint | backfill, checkpoint, resume, missing/extra validation 검증 | `db/experiments/a1-opensearch-backfill-checkpoint/results/20260502_112733/backfill-summary.md` |
| 12 | catch-up replay / DB-Search dual-run | replay 후 DB/Search snapshot shadow comparison 검증 | `db/experiments/a1-opensearch-catchup-dualrun/results/20260502_145444/catchup-dualrun-summary.md` |
| 13 | lag / fallback / rollback gate | lag threshold, backlog recovery, alias switch/rollback smoke 검증 | `db/experiments/a1-opensearch-lag-fallback-rollback/results/20260502_194815/ops-smoke-summary.md` |
| 14 | feature-flagged OpenSearch read path | `readpath.product-search.read-path` 기반 DB/Search/fallback 전환 검증 | `db/experiments/a1-opensearch-feature-flag-readpath/results/20260502_201920/feature-flag-readpath-summary.md` |
| 15 | circuit breaker | closed/open/half-open/fallback 동작 smoke 검증 | `db/experiments/a1-opensearch-circuit-breaker/results/20260502_210700/circuit-breaker-summary.md` |
| 16 | OpenSearch API k6 benchmark | feature-flagged OpenSearch read path의 최종 API k6 결과 측정 | `benchmark/k6/results/products_moderate_skew/product_search_opensearch_products_moderate_skew_20260503_121509_summary.json` |

## 최종 API/k6 비교

모든 값은 `product-search-baseline-v1`, `moderate_skew`, VUs 10, measured duration 10m 기준의 기존 k6 summary artifact에서 확인했다. HTTP smoke, k6 smoke, warm-up은 공식 결과에서 제외된다.

| Read path | Total requests | Mixed p95 | B1 p95 | B2 p95 | B3 p95 | Throughput | Error rate | Failed checks | Source artifact |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| Baseline API | 382 | 29611.602365 ms | 17124.170814999994 ms | 33409.19112499999 ms | 18519.306105 ms | 0.6262291702382904 req/s | 0 | 0 | `benchmark/k6/results/products_moderate_skew/product_search_baseline_products_moderate_skew_20260428_115844_summary.json` |
| DB tuned API | 31126 | 370.313125 ms | 386.7013 ms | 33.930324999999996 ms | 394.51556999999997 ms | 51.85398922328235 req/s | 0 | 0 | `benchmark/k6/results/products_moderate_skew/product_search_db_tuned_products_moderate_skew_20260428_150401_summary.json` |
| Denormalized DB API | 165685 | 127.34185999999998 ms | 20.867624999999993 ms | 23.145569999999992 ms | 152.9373 ms | 276.1365354515421 req/s | 0 | 0 | `benchmark/k6/results/products_moderate_skew/product_search_denormalized_db_products_moderate_skew_20260430_102433_summary.json` |
| OpenSearch API | 105780 | 98.89618499999996 ms | 86.04545999999996 ms | 70.34295999999999 ms | 125.53488499999999 ms | 176.2846593857517 req/s | 0 | 0 | `benchmark/k6/results/products_moderate_skew/product_search_opensearch_products_moderate_skew_20260503_121509_summary.json` |

## Read path별 해석

| Read path | 해석 | artifact 기반 관찰 |
|---|---|---|
| Baseline API | normalized DB에서 `products` + `product_options` JOIN, DISTINCT, OFFSET pagination을 사용하는 기준선이다. | Mixed p95 29611.602365 ms, throughput 0.6262291702382904 req/s로 가장 느린 기준선이었다. |
| DB tuned API | selected index, `EXISTS` rewrite, DISTINCT 제거를 적용한 normalized DB 개선 경로다. OFFSET pagination은 유지한다. | Baseline API 대비 Mixed p95와 throughput이 크게 개선됐다. B2 p95는 33.930324999999996 ms로 낮았지만 B1/B3는 약 386-394 ms 수준이었다. |
| Denormalized DB API | PostgreSQL 내부 `product_search_documents_moderate_skew` read model을 사용하는 경로다. read-time JOIN/EXISTS 의존을 줄이지만 OFFSET pagination은 유지한다. | Mixed p95 127.34185999999998 ms, throughput 276.1365354515421 req/s였다. B1/B2 p95와 throughput-heavy 관점에서는 OpenSearch보다 강한 구간이 있었다. |
| OpenSearch API | `products_search_read` alias와 nested option filter를 사용하는 search read model 경로다. DB fallback은 official primary result에서 사용되지 않아야 한다. | Mixed p95 98.89618499999996 ms, B3 p95 125.53488499999999 ms로 일부 latency dimension에서 가장 낮았다. 그러나 throughput은 Denormalized DB API보다 낮았다. |

결론은 OpenSearch가 항상 더 빠르다는 뜻이 아니다. DB tuning, Denormalized DB read model, OpenSearch search read model은 workload에 따라 서로 다른 장단점을 가진다.

## OpenSearch corpus / readiness

| 항목 | 확인 값 | Source artifact |
|---|---|---|
| source product count | 10000000 | `benchmark/k6/results/products_moderate_skew/opensearch_index_prepare_20260503_121439/source-counts.json` |
| source option count | 20500029 | `benchmark/k6/results/products_moderate_skew/opensearch_index_prepare_20260503_121439/source-counts.json` |
| indexed root document count | 10000000 / expected 10000000, passes `true` | `benchmark/k6/results/products_moderate_skew/opensearch_index_prepare_20260503_121439/index-count-validation-result.json` |
| nested option object count | 20500029 source option rows embedded as `options[]` | `benchmark/k6/results/products_moderate_skew/opensearch_index_prepare_20260503_121439/opensearch-index-prepare-summary.md` |
| physical index name | `products_search_benchmark_moderate_skew_v1` | `benchmark/k6/results/products_moderate_skew/opensearch_index_prepare_20260503_121439/opensearch-index-prepare-summary.md` |
| read/write/current aliases | `products_search_read`, `products_search_write`, `products_search_current` | `benchmark/k6/results/products_moderate_skew/opensearch_index_prepare_20260503_121439/alias-validation-result.json` |
| selected mapping | `db/experiments/a1-opensearch-index-mapping-alias/mappings/products_v1_nested.json` | `benchmark/k6/results/products_moderate_skew/opensearch_index_prepare_20260503_121439/opensearch-index-prepare-summary.md` |
| options mapping | `optionsType = nested`, passes `true` | `benchmark/k6/results/products_moderate_skew/opensearch_index_prepare_20260503_121439/mapping-validation-result.json` |
| max result window | `maxResultWindow = 10050`, required `10050`, passes `true` | `benchmark/k6/results/products_moderate_skew/opensearch_index_prepare_20260503_121439/index-settings-validation-result.json` |
| status count validation | ACTIVE 9000000, SOLD_OUT 700000, DELETED 300000, passes `true` | `benchmark/k6/results/products_moderate_skew/opensearch_index_prepare_20260503_121439/status-count-validation-result.json` |
| B1/B2/B3 preflight | B1 13380 >= 150, B2 720000 >= 150, B3 13380 >= 10050, all passes `true` | `benchmark/k6/results/products_moderate_skew/opensearch_index_prepare_20260503_121439/b1-b2-b3-preflight-result.json` |

## OpenSearch migration gate 요약

| Gate | 검증 내용 | 핵심 확인 값 | Source artifact | 결과 |
|---|---|---|---|---|
| Mapping / alias | nested mapping 선택, flattened/object false positive 확인, alias 생성 | nested positive hits 1, nested negative hits 0, flattened/object negative hits 1 | `db/experiments/a1-opensearch-index-mapping-alias/results/20260501_210124/mapping-smoke-summary.md` | pass |
| Transactional outbox capture | commit/update/status-change event capture와 rollback 미발행 확인 | captured event count 3, rollback outbox count 0 | `db/experiments/a1-search-outbox-transactional-capture/results/20260501_235850/search-outbox-transaction-summary.md` | pass |
| Outbox relay sync | processed/pending/failed/retry, idempotent replay, delete behavior 확인 | processed 5, pending 0, retry 1, idempotent replay mismatch 0 | `db/experiments/a1-outbox-relay-opensearch-sync/results/20260502_111326/outbox-relay-summary.md` | pass |
| Backfill checkpoint | source/index count, missing/extra, sample comparison, resume 확인 | source 4, indexed 4, missing 0, extra 0, resume success `True` | `db/experiments/a1-opensearch-backfill-checkpoint/results/20260502_112733/backfill-summary.md` | pass |
| Catch-up replay / DB-Search dual-run | replay 후 DB/Search static shadow comparison 확인 | replayed event count 3, mismatch count 0, stale by updated_at count 0 | `db/experiments/a1-opensearch-catchup-dualrun/results/20260502_145444/catchup-dualrun-summary.md` | pass |
| Lag / fallback / rollback ops gate | local lag threshold, backlog recovery, alias switch/rollback 확인 | p95 event lag 7.6081268 sec <= 30 sec, rollback success `True` | `db/experiments/a1-opensearch-lag-fallback-rollback/results/20260502_194815/ops-smoke-summary.md` | pass |
| Feature flag read path | DB path, Search path, fallback, flag rollback 확인 | DB path pass, Search path pass, fallback count 1, flag rollback pass `True` | `db/experiments/a1-opensearch-feature-flag-readpath/results/20260502_201920/feature-flag-readpath-summary.md` | pass |
| Circuit breaker | closed/open/half-open/fallback 동작 확인 | fallback count 8, circuit breaker open count 4, short-circuited request count 2 | `db/experiments/a1-opensearch-circuit-breaker/results/20260502_210700/circuit-breaker-summary.md` | pass |
| OpenSearch API k6 | full corpus readiness 후 feature-flagged OpenSearch read path 측정 | total requests 105780, Mixed p95 98.89618499999996 ms, fallback count 0 | `benchmark/k6/results/products_moderate_skew/product_search_opensearch_products_moderate_skew_20260503_121509_summary.json` | pass |

이 gate들은 production operations validation이 아니라 local smoke validation이다.

## 최종 결론

이 프로젝트는 로컬 synthetic benchmark에서 Baseline API, DB tuned API, Denormalized DB API, OpenSearch API read path를 비교했다. 기존 artifact 기준으로 DB tuning은 baseline 대비 큰 개선을 만들었다.

Denormalized DB read model과 OpenSearch search read model은 서로 다른 강점을 보였다. OpenSearch API는 Mixed p95와 B3 p95 등 일부 latency dimension에서 가장 낮았고, Denormalized DB API는 B1/B2 p95와 throughput-heavy 관점에서 더 강한 결과를 보였다.

핵심 교훈은 workload-dependent read path trade-off다. OpenSearch는 migration/fallback gate를 갖춘 search read model로 해석해야 하며, 보편적으로 더 빠른 database replacement로 해석하면 안 된다.

## 한계

- 결과는 로컬 Docker 기반 synthetic benchmark 결과다.
- 결과는 production capacity claim이 아니다.
- 결과는 production readiness claim이 아니다.
- 결과는 SLA/SLO claim이 아니다.
- k6 workload는 synthetic workload이며 실제 production traffic을 대표하지 않는다.
- smoke gate 결과는 production operations validation과 다르다.
- API p95는 PostgreSQL `EXPLAIN` Execution Time과 직접 비교하면 안 된다.
- `moderate_skew` 대표 profile 중심 결과이며 `uniform`, `high_skew`의 최종 API/k6 비교는 이 문서의 측정 대상이 아니다.
- 누락된 artifact path 또는 검증 불가능한 값은 이 결과 요약의 한계로 남는다.
- artifact에서 확인하지 못한 값은 새로 계산하거나 추정하지 않았다.
