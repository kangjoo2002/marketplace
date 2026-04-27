# Product Options Seed Data

## Purpose

This PR prepares product_options data for later JOIN experiments. It does not measure JOIN performance yet.

The goal is to create deterministic synthetic `product_options` data for the existing 10M products profiles so the next PR can measure products + product_options JOIN baseline behavior.

## Why Product Options Comes After Products-Only Experiments

A-1a established products-only baseline behavior, index attempts, partial index behavior, and keyset pagination behavior without JOIN fan-out.

A-1b starts the next chapter by adding the data foundation needed to inspect product_options JOIN bottlenecks later. This PR only creates and verifies data. It intentionally does not add JOIN EXPLAIN artifacts.

## What Data Is Created

Each `product_options` row has:

- `id`
- `product_id`
- `color`
- `size`
- `stock_status`

Every generated product has at least one option. The target average is around 2 options per product, creating a controlled 1:N relationship without making local experiments unnecessarily expensive.

## Table Naming Strategy

There is one matching product_options table per products profile:

| products table | product_options table |
|---|---|
| `products_uniform` | `product_options_uniform` |
| `products_moderate_skew` | `product_options_moderate_skew` |
| `products_high_skew` | `product_options_high_skew` |

No 3x3 cross-profile matrix is created.

## Why Exactly One Matching Option Profile Per Products Profile

The goal is to observe JOIN fan-out and option filter selectivity within each synthetic profile, not to multiply the experiment matrix.

Correct pairings:

- `products_uniform` + `product_options_uniform`
- `products_moderate_skew` + `product_options_moderate_skew`
- `products_high_skew` + `product_options_high_skew`

Cross-profile combinations are intentionally not part of this seed design.

## Synthetic/Local Benchmark Caveat

These option distributions are synthetic benchmark choices, not production-derived distributions.

The distribution is designed to create controlled differences in fan-out, option selectivity, and skew for later JOIN baseline experiments.

The goal is not to mimic a real commerce catalog exactly. The goal is reproducible local data for read-path experiments.

## Distribution Design Rationale

The seed uses deterministic product-id arithmetic. It does not call `random()`.

Option values are bounded:

- colors: `BLACK`, `WHITE`, `RED`, `BLUE`, `GREEN`, `GRAY`, `NAVY`, `BEIGE`
- sizes: `XS`, `S`, `M`, `L`, `XL`, `FREE`
- stock statuses: `IN_STOCK`, `LOW_STOCK`, `OUT_OF_STOCK`

Fan-out rules:

| profile | options-per-product rule | intent |
|---|---|---|
| `uniform` | `1`, `2`, `3` repeating by product id | Even, simple baseline with average around 2. |
| `moderate-skew` | 35% 1 option, 35% 2 options, 20% 3 options, 10% 4 options | Moderate fan-out and common-value concentration. |
| `high-skew` | 65% 1 option, 15% 2 options, 15% 4 options, 5% 8 options | Most products are narrow, while a small subset has higher fan-out. |

Value distribution intent:

- `uniform`: color and size are roughly even; stock status is mildly `IN_STOCK` heavy.
- `moderate-skew`: `BLACK`, `WHITE`, `GRAY`, `M`, `L`, `FREE`, and `IN_STOCK` are more common.
- `high-skew`: `BLACK`, `M` or `FREE`, and `IN_STOCK` are strongly concentrated.

## Schema Choice

The schema creates a primary key on `id` and CHECK constraints for bounded option values.

Actual foreign keys are intentionally omitted for local seed speed and to avoid adding extra validation cost while loading roughly 20M option rows per profile. The verification script reports orphan rows instead.

No product_options query tuning indexes are added in this PR. That means no `product_id` JOIN index, no color index, no size index, no stock_status index, and no composite option filter index.

## Why This PR Does Not Run JOIN EXPLAIN Yet

This PR creates the data foundation only. JOIN baseline measurements should happen in a separate PR after the schema and seed artifacts are stable.

product_options index tuning, EXISTS rewrite, API/k6, and OpenSearch are intentionally left for later PRs.

## How To Create Product Options Schema

```powershell
Get-Content -Raw db/seed/product-options/product_options_schema.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab
```

Or run the helper, which creates schema before seeding:

```powershell
.\db\seed\product-options\run-seed-product-options.ps1
```

## How To Seed One Profile

Default profile is `moderate-skew`:

```powershell
.\db\seed\product-options\run-seed-product-options.ps1
```

Specific profile:

```powershell
.\db\seed\product-options\run-seed-product-options.ps1 -Profile uniform
```

Manual command:

```powershell
Get-Content -Raw db/seed/product-options/seed_product_options.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v seed_profile=moderate-skew -v chunk_size=500000
```

## How To Seed All Profiles

```powershell
.\db\seed\product-options\run-seed-product-options.ps1 -Profile all
```

## How To Verify Row Counts

The helper runs verification automatically after each seed.

Manual verification:

```powershell
Get-Content -Raw db/seed/product-options/verify_product_options_distribution.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab -v seed_profile=moderate-skew
```

The verification output includes products row count, product_options row count, distinct option `product_id` count, products with zero options, and orphan option rows.

## How To Verify Fan-Out

Use the `options_per_product` section in the verification output.

It reports:

- min options per product
- average options per product
- max options per product
- product count by options-per-product bucket

## How To Verify Color Distribution

Use the `color` distribution section in the verification output.

It reports row count and percentage for each bounded synthetic color value.

## How To Verify Size Distribution

Use the `size` distribution section in the verification output.

It reports row count and percentage for each bounded synthetic size value.

## How To Verify Stock Status Distribution

Use the `stock_status` distribution section in the verification output.

It reports row count and percentage for `IN_STOCK`, `LOW_STOCK`, and `OUT_OF_STOCK`.

## How To Verify Important Option Combinations

The verification script includes:

- `color + size` distribution
- `color + size + stock_status` distribution
- `category_id = 35`, `status = ACTIVE`, `price BETWEEN 10000 AND 100000` option combination counts
- `category_id = 35`, `brand_id = 543`, `status = ACTIVE`, `price BETWEEN 10000 AND 100000` option combination counts

The category and brand checks are included because later JOIN baseline experiments are likely to reuse the existing products-only Q1/Q2/Q4 filter parameters.

These checks scan large local tables because this PR intentionally does not add product_options JOIN indexes.

## Result Artifact Naming

The helper saves artifacts under:

```text
db/seed/results/
```

Expected names:

```text
product_options_schema_setup.log
uniform_10m_product_options_seed.log
uniform_10m_product_options_distribution.txt
moderate_skew_10m_product_options_seed.log
moderate_skew_10m_product_options_distribution.txt
high_skew_10m_product_options_seed.log
high_skew_10m_product_options_distribution.txt
```

Do not commit result files unless the matching command actually ran successfully.

## Next PR Recommendation

The next PR should add product_options JOIN + DISTINCT baseline EXPLAIN artifacts using these seeded profile pairs.

It should still avoid product_options index tuning, EXISTS rewrite, API/k6, OpenSearch, Redis, read models, and outbox until the JOIN baseline is visible.
