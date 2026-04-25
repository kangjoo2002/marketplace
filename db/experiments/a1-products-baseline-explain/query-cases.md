# A-1a Products Baseline Query Cases

This document defines the stable workload contract for products-only baseline EXPLAIN experiments. The same case IDs should be reused in later tuning, API, k6, and search-backend comparison PRs.

The parameter values are synthetic/local benchmark parameters chosen from the seeded benchmark profiles and distribution verification artifacts. They must not be described as production-derived.

Common parameters:

- `category_id = 35`
- `brand_id = 543`
- `status = ACTIVE`
- `min_price = 10000`
- `max_price = 100000`
- `limit = 50`
- `shallow_offset = 100`
- `deep_offset = 10000`

| case_id | filters | sort | pagination | purpose | later_api_mapping |
|---|---|---|---|---|---|
| Q1_category_status_price_created_at_shallow | `category_id = 35`, `status = ACTIVE`, `price BETWEEN 10000 AND 100000` | `created_at DESC, id DESC` | `LIMIT 50 OFFSET 100` | Baseline for common category search with active products, price filter, recent-first sort, and shallow OFFSET pagination. | `GET /products?categoryId=35&status=ACTIVE&minPrice=10000&maxPrice=100000&sort=createdAtDesc&page=3&size=50` |
| Q2_category_brand_status_price_price_asc_shallow | `category_id = 35`, `brand_id = 543`, `status = ACTIVE`, `price BETWEEN 10000 AND 100000` | `price ASC, id ASC` | `LIMIT 50 OFFSET 100` | Baseline for category plus brand narrowing with low-price-first sorting. | `GET /products?categoryId=35&brandId=543&status=ACTIVE&minPrice=10000&maxPrice=100000&sort=priceAsc&page=3&size=50` |
| Q3_category_status_review_count_shallow | `category_id = 35`, `status = ACTIVE` | `review_count DESC, id DESC` | `LIMIT 50 OFFSET 100` | Baseline for popularity-like ordering within a category without a price filter. | `GET /products?categoryId=35&status=ACTIVE&sort=reviewCountDesc&page=3&size=50` |
| Q4_category_status_price_created_at_deep_offset | `category_id = 35`, `status = ACTIVE`, `price BETWEEN 10000 AND 100000` | `created_at DESC, id DESC` | `LIMIT 50 OFFSET 10000` | Baseline for deep OFFSET cost using the same filter and sort shape as Q1. | `GET /products?categoryId=35&status=ACTIVE&minPrice=10000&maxPrice=100000&sort=createdAtDesc&page=201&size=50` |
| Q5_status_only_created_at_shallow | `status = ACTIVE` | `created_at DESC, id DESC` | `LIMIT 50 OFFSET 100` | Baseline for broad active-product browsing with recent-first sort. | `GET /products?status=ACTIVE&sort=createdAtDesc&page=3&size=50` |
| Q6_price_range_price_asc_shallow | `price BETWEEN 10000 AND 100000` | `price ASC, id ASC` | `LIMIT 50 OFFSET 100` | Baseline for broad price-range browsing with price ascending sort. | `GET /products?minPrice=10000&maxPrice=100000&sort=priceAsc&page=3&size=50` |

The `later_api_mapping` column is conceptual only. This PR does not implement an API.
