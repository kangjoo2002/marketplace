# Product Search Baseline Scenario Discovery Notes

This note records parameter discovery for `product-search-baseline-v1`. It is
not an official measured benchmark result.

The previous `OUT_OF_STOCK` run is discarded because it produced zero-result or
non-representative scenarios. Official measured summary JSON artifacts were
removed from `benchmark/k6/results`.

## Repository-Grounded Inputs

- API request parameters: `categoryId`, `brandId`, `status`, `minPrice`,
  `maxPrice`, `color`, `size`, `stockStatus`, `sort`, `limit`, `offset`
- API sort values: `reviewCountDesc`, `priceAsc`, `priceDesc`, `createdAtDesc`
- product status values: `ACTIVE`, `SOLD_OUT`, `DELETED`
- option stock status values: `IN_STOCK`, `LOW_STOCK`, `OUT_OF_STOCK`
- colors: `BLACK`, `WHITE`, `RED`, `BLUE`, `GREEN`, `GRAY`, `NAVY`, `BEIGE`
- sizes: `XS`, `S`, `M`, `L`, `XL`, `FREE`
- Previous JOIN baseline workload used `category_id = 35`,
  `brand_id = 543`, `price BETWEEN 10000 AND 100000`, `LIMIT 50`, and
  offsets `100` or `10000`.

## Recommended Constants

| Scenario | categoryId | brandId | status | minPrice | maxPrice | color | size | stockStatus | sort | limit | offset |
|---|---:|---:|---|---:|---:|---|---|---|---|---:|---:|
| `B1_selective_option_filter` | 40 | 592 | `ACTIVE` | 10000 | 100000 | `RED` | `M` | `IN_STOCK` | `reviewCountDesc` | 50 | 100 |
| `B2_broad_active_option_filter` | N | N | `ACTIVE` | N | N | `RED` | `M` | `IN_STOCK` | `createdAtDesc` | 50 | 100 |
| `B3_deep_offset_option_filter` | 40 | N | `ACTIVE` | 10000 | 100000 | `RED` | `M` | `IN_STOCK` | `createdAtDesc` | 50 | 1000 |

## Final Validation

| Profile | Scenario | matching_count | required_min_count | Passes |
|---|---|---:|---:|---|
| `uniform` | `B1_selective_option_filter` | 213 | 150 | true |
| `moderate_skew` | `B1_selective_option_filter` | 7050 | 150 | true |
| `high_skew` | `B1_selective_option_filter` | 1030 | 150 | true |
| `uniform` | `B2_broad_active_option_filter` | 269997 | 150 | true |
| `moderate_skew` | `B2_broad_active_option_filter` | 450000 | 150 | true |
| `high_skew` | `B2_broad_active_option_filter` | 475000 | 150 | true |
| `uniform` | `B3_deep_offset_option_filter` | 2792 | 1050 | true |
| `moderate_skew` | `B3_deep_offset_option_filter` | 24340 | 1050 | true |
| `high_skew` | `B3_deep_offset_option_filter` | 13030 | 1050 | true |

## Rejection Evidence

- `categoryId=35`, `brandId=543`, `WHITE/L/OUT_OF_STOCK` failed because
  `uniform=0`, `high_skew=0`.
- `categoryId=35`, `brandId=543`, `BLACK/M/IN_STOCK` failed because
  `uniform=0`, `moderate_skew=0`.
- B3 with the selected B1 category+brand and price range failed at offset 500
  because `uniform=213`, below required `550`.
- B3 with the selected B1 category+brand and relaxed price failed at offset 500
  because `uniform=315`, below required `550`.
- The nearest category+brand no-price B3 candidate found was
  `categoryId=13`, `brandId=321`, `BLACK/XL/IN_STOCK`; it failed at offset 500
  because `uniform=480`, below required `550`.
- The selected B3 category-only candidate passes offset `1000`; it fails
  offset `5000` because `uniform=2792`, below required `5050`.

Run the SQL files for reproducible evidence:

```powershell
Get-Content -Raw benchmark\k6\product-search-baseline-scenario-candidates.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab

Get-Content -Raw benchmark\k6\product-search-baseline-scenario-validation.sql |
  docker compose exec -T postgres psql -U readpath -d readpath_lab
```
