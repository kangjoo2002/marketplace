# A-1a Products-Only Baseline EXPLAIN Observations

## Scope

This document records observations from products-only baseline EXPLAIN artifacts under `db/experiments/a1-products-baseline-explain/results`.

These are pre-index-tuning observations. This document does not claim index tuning conclusions, API p95 improvement, or OpenSearch necessity.

## Result Files

| profile | result file |
|---|---|
| `products_uniform` | `db/experiments/a1-products-baseline-explain/results/products_uniform/products_uniform_baseline_explain_20260425_133112.txt` |
| `products_moderate_skew` | `db/experiments/a1-products-baseline-explain/results/products_moderate_skew/products_moderate_skew_baseline_explain_20260425_133055.txt` |
| `products_high_skew` | `db/experiments/a1-products-baseline-explain/results/products_high_skew/products_high_skew_baseline_explain_20260425_133129.txt` |

## Observation Rules

- Only summarize what is visible in EXPLAIN output.
- Do not infer production behavior.
- Do not claim performance improvement.
- Do not compare PostgreSQL EXPLAIN query time directly with future OpenSearch API p95.
- Future OpenSearch comparison must be API-to-API after both APIs exist.

## Query Observations

### Q1_category_status_price_created_at_shallow

#### Why this query exists

Q1 represents a common products-only listing shape: category filter, active status filter, price range filter, recent-first ordering, and shallow OFFSET pagination.

#### Observed plan shape

| profile | scan / access pattern | sort behavior | notable EXPLAIN fields | short observation |
|---|---|---|---|---|
| `products_uniform` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=13998 read=109545`; Rows Removed by Filter `3329134`; Execution Time `690.030 ms` | Baseline scans the table in parallel and sorts the matching rows for the requested order. |
| `products_moderate_skew` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=486 read=123057`; Rows Removed by Filter `3322380`; Execution Time `472.460 ms` | Same plan shape as uniform, with different observed row counts and buffer mix. |
| `products_high_skew` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=223 read=123320`; Rows Removed by Filter `3303657`; Execution Time `505.951 ms` | Same plan shape; high skew shows more rows from the scan node per worker in the result file. |

#### Baseline learning

At baseline, this query shows the cost shape before any index can support the combined filters and `created_at DESC, id DESC` ordering.

#### What not to conclude yet

Do not conclude which index is correct, whether this is production latency, or whether a search engine is needed.

### Q2_category_brand_status_price_price_asc_shallow

#### Why this query exists

Q2 adds `brand_id` and sorts by `price ASC, id ASC`. It exists to preserve a query shape where price is both a filter dimension and the leading sort key.

#### Observed plan shape

| profile | scan / access pattern | sort behavior | notable EXPLAIN fields | short observation |
|---|---|---|---|---|
| `products_uniform` | `Parallel Seq Scan`, then `Gather` | top-level `Sort`; `Sort Method: top-N heapsort` | Buffers `hit=14008 read=109449`; Rows Removed by Filter `3332992`; Execution Time `483.287 ms` | Uniform used `Gather` followed by a top-level sort rather than `Gather Merge`. |
| `products_moderate_skew` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=584 read=122961`; Rows Removed by Filter `3327993`; Execution Time `613.467 ms` | Moderate skew used parallel scan plus per-worker sort and merge. |
| `products_high_skew` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=321 read=123224`; Rows Removed by Filter `3330500`; Execution Time `462.725 ms` | Same broad baseline access pattern, with different estimated and actual rows. |

#### Baseline learning

Q2 captures the baseline for a narrower category-brand workload before comparing a price single-column index or a composite index.

#### What not to conclude yet

Do not conclude that price alone is sufficient or insufficient as an index strategy. That requires later controlled index experiments.

### Q3_category_status_review_count_shallow

#### Why this query exists

Q3 keeps category and status filters but changes ordering to `review_count DESC, id DESC`, representing a popularity-like listing shape.

#### Observed plan shape

| profile | scan / access pattern | sort behavior | notable EXPLAIN fields | short observation |
|---|---|---|---|---|
| `products_uniform` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=14190 read=109353`; Rows Removed by Filter `3327331`; Execution Time `378.940 ms` | Baseline still scans in parallel and sorts for the requested review-count order. |
| `products_moderate_skew` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=678 read=122865`; Rows Removed by Filter `3317683`; Execution Time `621.940 ms` | Same plan operators, with more rows emitted by the scan node than uniform. |
| `products_high_skew` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=415 read=123128`; Rows Removed by Filter `3290870`; Execution Time `382.707 ms` | Same plan shape; high skew shows the highest scan-node row count among the three files. |

#### Baseline learning

Changing the sort key creates another baseline that later index candidates must be evaluated against separately from created-at sorting.

#### What not to conclude yet

Do not conclude that a review-count-oriented index should be added yet. This file only records the untuned plan.

### Q4_category_status_price_created_at_deep_offset

#### Why this query exists

Q4 uses the same filter and order shape as Q1, but with deep OFFSET pagination. It exists to compare shallow and deep OFFSET behavior before keyset pagination is introduced.

#### Observed plan shape

| profile | scan / access pattern | sort behavior | notable EXPLAIN fields | short observation |
|---|---|---|---|---|
| `products_uniform` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: quicksort` | Buffers `hit=14286 read=109257`; Rows Removed by Filter `3329134`; Execution Time `430.357 ms` | Deep OFFSET required the plan to produce `10050` rows through `Gather Merge`. |
| `products_moderate_skew` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: quicksort` | Buffers `hit=774 read=122769`; Rows Removed by Filter `3322380`; Execution Time `596.307 ms` | Same deep OFFSET row requirement is visible in `Gather Merge` rows `10050`. |
| `products_high_skew` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=511 read=123032`; Rows Removed by Filter `3303657`; Execution Time `533.356 ms` | High skew kept top-N heapsort in this artifact while still producing `10050` rows through `Gather Merge`. |

#### Baseline learning

Q4 shows that the deep OFFSET case has the same filter shape as Q1 but must carry more ordered rows to satisfy pagination.

#### What not to conclude yet

Do not conclude keyset pagination impact yet. Q4 is only the baseline target for a later keyset comparison.

### Q5_status_only_created_at_shallow

#### Why this query exists

Q5 is a broad status-only control case with recent-first ordering. It exists to show the baseline shape for a low-selectivity filter.

#### Observed plan shape

| profile | scan / access pattern | sort behavior | notable EXPLAIN fields | short observation |
|---|---|---|---|---|
| `products_uniform` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=14382 read=109161`; Rows Removed by Filter `333333`; Execution Time `1585.324 ms` | Broad active-status filtering emits about `3000000` rows per loop from the scan node. |
| `products_moderate_skew` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=870 read=122673`; Rows Removed by Filter `333333`; Execution Time `1510.988 ms` | Same broad plan shape and same rows-removed count as uniform in the artifact. |
| `products_high_skew` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=607 read=122936`; Rows Removed by Filter `166667`; Execution Time `1014.466 ms` | High skew has fewer rows removed by the status filter because the profile has more `ACTIVE` rows. |

#### Baseline learning

Q5 gives a control point for broad low-cardinality filtering before later single-column status index attempts.

#### What not to conclude yet

Do not conclude that a status index is useful or useless yet. The baseline only shows the current no-index-tuning plan.

### Q6_price_range_price_asc_shallow

#### Why this query exists

Q6 is a broad price-range control case sorted by `price ASC, id ASC`. It exists to compare price-only behavior against the more constrained Q1 and Q2 workloads later.

#### Observed plan shape

| profile | scan / access pattern | sort behavior | notable EXPLAIN fields | short observation |
|---|---|---|---|---|
| `products_uniform` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=14480 read=109065`; Rows Removed by Filter `1000000`; Execution Time `946.822 ms` | Price range alone remains broad in this baseline artifact. |
| `products_moderate_skew` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=968 read=122577`; Rows Removed by Filter `1000000`; Execution Time `931.768 ms` | Same plan shape and same rows-removed count as uniform in the artifact. |
| `products_high_skew` | `Parallel Seq Scan` | `Gather Merge`; `Sort Method: top-N heapsort` | Buffers `hit=705 read=122840`; Rows Removed by Filter `1000000`; Execution Time `945.971 ms` | Same broad price-range baseline shape across profiles. |

#### Baseline learning

Q6 preserves a price-only control query so future price index behavior can be compared against the core category and brand workloads.

#### What not to conclude yet

Do not conclude that a price single-column index is the correct main workload index. Later experiments must compare it against Q1 and Q2.

## Cross-Query Observations

- All six query cases used `Parallel Seq Scan` in the committed baseline result files.
- Most query cases used `Gather Merge`; Q2 on `products_uniform` used `Gather` followed by a top-level `Sort`.
- Sorting appears repeatedly because every query has an explicit `ORDER BY`.
- Shallow OFFSET cases generally show `top-N heapsort`; Q4 deep OFFSET on `products_uniform` and `products_moderate_skew` used `quicksort`, while `products_high_skew` still used `top-N heapsort`.
- Q5 and Q6 are broad control cases: Q5 filters only by status, and Q6 filters only by price range.
- Q1, Q2, and Q3 are intended for later composite-index comparison because they combine filters with different sort keys.
- Q4 is the baseline for later OFFSET vs keyset pagination comparison.
- Profile distribution affects row counts and some observed plan details, but these artifacts alone do not prove production behavior.

## How These Observations Will Be Used Later

Later PRs will reuse the same Q1-Q6 workload to compare:

- failed single-column index attempts
- composite indexes
- partial indexes
- keyset pagination
- API/k6 p95 baseline and after-tuning comparison
- later DB-backed API vs OpenSearch-backed API comparison

## Non-Goals

- No index recommendation yet
- No p95 claim yet
- No OpenSearch decision yet
- No production latency claim
- No resume bullet yet
