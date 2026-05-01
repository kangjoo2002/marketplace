# PR-A17 OpenSearch Mapping Smoke Summary

- OpenSearch URL: http://localhost:9200
- OpenSearch image: opensearchproject/opensearch:2.15.0
- Nested index: products_search_a17_smoke_nested_v1
- Flattened/object candidate index: products_search_a17_smoke_flattened_v1
- Read alias: products_search_a17_smoke_read
- Write alias: products_search_a17_smoke_write
- Current alias: products_search_a17_smoke_current

| check | hits | result |
|---|---:|---|
| healthcheck | n/a | PASS |
| nested index creation | n/a | PASS |
| alias creation | n/a | PASS |
| nested sample document indexing | n/a | PASS |
| nested negative BLACK / M / IN_STOCK | 0 | PASS |
| nested positive BLACK / S / IN_STOCK | 1 | PASS |
| flattened/object index creation | n/a | PASS |
| flattened/object sample document indexing | n/a | PASS |
| flattened/object negative BLACK / M / IN_STOCK | 1 | PASS, false positive demonstrated |

Selected option representation: nested.

This smoke result is not a production capacity or latency claim.
