# Product Seed Data

## Purpose

These seed scripts create synthetic benchmark profiles for product read-path experiments. The profiles are not production-derived distributions.

The goal is to compare how data distribution affects selectivity, execution plans, sort cost, pagination cost, join pressure, and later API p95 latency. The goal is not to reproduce production traffic exactly.

## Scale

The official benchmark scale is fixed at 10,000,000 products per profile.

All three official profiles can be stored in the same PostgreSQL database:

- `products_uniform`
- `products_moderate_skew`
- `products_high_skew`

Each profile table stores 10M rows after a full seed. All three profile tables together store 30M rows, which takes significant disk space.

10M products is not a claim about the average size of a typical commerce service. It is a local stress benchmark target. The scale is informed by public large-scale ecommerce/product metadata datasets such as UCSD Amazon Review Data 2018, which provides metadata for about 15.5M products.

This project chooses 10M products as a practical upper bound for repeated local experiments on MacBook Pro M2 16GB RAM + Docker Compose, including seed generation, index creation, `EXPLAIN ANALYZE`, and later k6 experiments.

## Storage Model

The project intentionally does not store all profiles in one `products` table with a `seed_profile` column.

Reason:

- A `seed_profile` filter would pollute the actual product filtering query shape.
- Profile-specific tables preserve clean query shapes.
- Separate tables allow repeated comparison across distributions without reseeding one shared table.

`products_active` is a view used by experiments that want a stable table-like name. By default, `products_active` points to `products_moderate_skew`. Use `set_active_product_profile.sql` to switch it.

## Optimized Seed Strategy

`seed_products.sql` uses PostgreSQL SQL-based generation only. It does not use Java, JPA, application memory, external scripts, or generated CSV files.

The script:

- Maps `seed_profile` to one target table:
  - `uniform` -> `products_uniform`
  - `moderate-skew` -> `products_moderate_skew`
  - `high-skew` -> `products_high_skew`
- Creates the three profile tables if they are missing.
- Creates `products_active` if it is missing, pointing to `products_moderate_skew`.
- Truncates only the selected target profile table with `TRUNCATE TABLE ... RESTART IDENTITY`.
- Does not truncate the base `products` table.
- Does not truncate the other profile tables.
- Inserts exactly 10,000,000 rows into the selected profile table.
- Inserts rows in configurable chunks using `generate_series`.
- Inserts deterministic `id` values directly and resets the selected target table sequence after the seed.
- Sets session-level `jit = off` to avoid JIT compile overhead for this synthetic seed query.
- Sets session-level `synchronous_commit = off` to reduce local seed commit latency. This is for local benchmark seeding, not a production durability setting.
- Runs `ANALYZE` on the selected target table after seeding.

Progress is printed after each chunk with `RAISE NOTICE`, including profile, target table, target count, inserted count, percentage, inserted id range, chunk elapsed time, and total elapsed time.

Example:

```text
NOTICE:  seeding products profile=moderate-skew target_table=products_moderate_skew target=10000000 chunk_size=500000
NOTICE:  inserted 500000 / 10000000 products (5.0 percent) target_table=products_moderate_skew range=1-500000 chunk_elapsed=... total_elapsed=...
NOTICE:  inserted 1000000 / 10000000 products (10.0 percent) target_table=products_moderate_skew range=500001-1000000 chunk_elapsed=... total_elapsed=...
```

The chunks are progress and memory-control units, not independent commit units. The chunk loop runs inside one PL/pgSQL `DO` block, so the script cannot commit each chunk independently. If the `DO` block fails, rows inserted by the block can roll back. Because `TRUNCATE TABLE ... RESTART IDENTITY` runs before the insert loop, a failed seed can leave the selected profile table empty. Other profile tables are not truncated.

## Profiles

Supported profiles:

- `uniform`: category, brand, and seller dimensions are distributed as evenly as practical. Status is about 90% `ACTIVE`, 7% `SOLD_OUT`, and 3% `DELETED`.
- `moderate-skew`: the default official skew profile. Category, brand, and seller dimensions have hot groups and long-tail groups. Status is about 90% `ACTIVE`, 7% `SOLD_OUT`, and 3% `DELETED`.
- `high-skew`: a stronger stress profile. Category, brand, and seller dimensions are more concentrated in hot groups. Status is about 95% `ACTIVE`, 4% `SOLD_OUT`, and 1% `DELETED`.

These profiles are synthetic benchmark profiles. Exact ratios are experimental parameters, not production-derived values. The reason for three profiles is to compare planner behavior and latency sensitivity across different data distributions.

Synthetic cardinality parameters:

- Categories: 500
- Brands: 5,000
- Sellers: 50,000

## Joint Distribution

`category_id`, `brand_id`, and `seller_id` are intentionally not generated as fully independent random dimensions. Fully independent generation can make `category_id + brand_id` filter combinations too sparse or unrealistic for repeatable `EXPLAIN ANALYZE` and later load experiments.

The seed uses deterministic correlation rules:

- Global hot brands: brand IDs `1..200` can appear across many categories, so some brands are visible outside a single category.
- Category-specific local brand pools: brand IDs `201..5000` are selected from deterministic category-local pools, so category and brand filters still produce meaningful combinations.
- Seller-specific category focus: each seller has a primary category range and most products stay near that focus.
- Skew profiles connect hot sellers more often with hot categories and hot categories more often with hot brands.
- Long-tail sellers and categories remain present so cold combinations can still be inspected.

## How To Run

PowerShell:

```powershell
docker compose down
docker compose up -d
```

Seed each profile with the default chunk size of 500,000:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -v seed_profile=uniform -v chunk_size=500000 -f /seed/seed_products.sql
docker compose exec postgres psql -U readpath -d readpath_lab -v seed_profile=moderate-skew -v chunk_size=500000 -f /seed/seed_products.sql
docker compose exec postgres psql -U readpath -d readpath_lab -v seed_profile=high-skew -v chunk_size=500000 -f /seed/seed_products.sql
```

If `seed_profile` is omitted, the script defaults to `moderate-skew`. If `chunk_size` is omitted, the script defaults to `500000`.

Smaller chunks print progress more often but add more chunk overhead. Larger chunks reduce chunk overhead but print progress less often.

## Verify Profiles

Verify each profile:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -v target_table=products_uniform -f /seed/verify_product_distribution.sql
docker compose exec postgres psql -U readpath -d readpath_lab -v target_table=products_moderate_skew -f /seed/verify_product_distribution.sql
docker compose exec postgres psql -U readpath -d readpath_lab -v target_table=products_high_skew -f /seed/verify_product_distribution.sql
```

If `target_table` is omitted, verification defaults to `products_active`.

Switch active profile:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -v active_profile=uniform -f /seed/set_active_product_profile.sql
docker compose exec postgres psql -U readpath -d readpath_lab -v active_profile=moderate-skew -f /seed/set_active_product_profile.sql
docker compose exec postgres psql -U readpath -d readpath_lab -v active_profile=high-skew -f /seed/set_active_product_profile.sql
```

Verify active profile:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -v target_table=products_active -f /seed/verify_product_distribution.sql
```

## Save Verification Output

Create a local results directory:

```powershell
New-Item -ItemType Directory -Force -Path db/seed/results
```

After seeding `uniform`, save verification output:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -v target_table=products_uniform -f /seed/verify_product_distribution.sql | Tee-Object -FilePath db/seed/results/uniform_10m_distribution.txt
```

After seeding `moderate-skew`, save verification output:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -v target_table=products_moderate_skew -f /seed/verify_product_distribution.sql | Tee-Object -FilePath db/seed/results/moderate_skew_10m_distribution.txt
```

After seeding `high-skew`, save verification output:

```powershell
docker compose exec postgres psql -U readpath -d readpath_lab -v target_table=products_high_skew -f /seed/verify_product_distribution.sql | Tee-Object -FilePath db/seed/results/high_skew_10m_distribution.txt
```

Do not create or commit these result files unless the matching full 10M seed and verification actually completed successfully.

## Warnings

Seeding 10M rows per profile can take time and disk space. Storing all three profiles means 30M product rows in total.

`docker compose down` keeps the PostgreSQL volume.

`docker compose down -v` removes the local PostgreSQL volume and deletes all seeded data.

Init scripts and seed scripts are different:

- `db/init` scripts run automatically only when PostgreSQL initializes a new empty volume.
- `db/seed` scripts are mounted into the container and run manually.

## Related Seed Work

Product option seed support lives under:

```text
db/seed/product-options/
```

That seed work creates matching `product_options_*` tables for later JOIN bottleneck experiments.

## Intentionally Not Included

This PR intentionally does not include:

- Product API
- Java/JPA/Flyway/Liquibase integration
- DB tuning indexes
- k6
- OpenSearch
- Redis
