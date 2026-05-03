# OpenSearch Product Search Benchmark Index Prepare Summary

- status: pass
- message: Existing OpenSearch benchmark index validated and promoted in 00:00:16.8356813.
- run mode: official-full
- OpenSearch URL: http://localhost:9200
- physical index: products_search_benchmark_moderate_skew_v1
- official aliases: products_search_read, products_search_write, products_search_current
- selected mapping: C:\projects\readpath-lab\readpath-lab\db\experiments\a1-opensearch-index-mapping-alias\mappings\products_v1_nested.json
- batch size: 5000
- start after product id: 0
- max products: 0
- dry run: False
- explain only: False
- promote existing: True
- helper index flag: True
- helper index name: idx_product_options_moderate_skew_product_id_benchmark_export
- index max_result_window: 10050
- source product count: 10000000
- source option count: 20500029

This is local benchmark corpus preparation only. It is not a production
migration, production readiness claim, capacity claim, SLA, or SLO.
Validation:

- options mapping type: nested
- index max_result_window: 10050
- indexed root document count: 10000000
- official root document count expected: 10000000
- official corpus ready: True
- status count validation: True
- B1_selective_option_filter matching count: 13380 / required 150 / passes True
- B2_broad_active_option_filter matching count: 720000 / required 150 / passes True
- B3_deep_offset_option_filter matching count: 13380 / required 10050 / passes True

