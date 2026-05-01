#!/usr/bin/env bash
set -euo pipefail

OPENSEARCH_URL="${OPENSEARCH_URL:-http://localhost:9200}"
OPENSEARCH_IMAGE="${OPENSEARCH_IMAGE:-opensearchproject/opensearch:2.15.0}"
INDEX_PREFIX="${INDEX_PREFIX:-products_search_a17_smoke}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

NESTED_INDEX="${INDEX_PREFIX}_nested_v1"
FLATTENED_INDEX="${INDEX_PREFIX}_flattened_v1"
READ_ALIAS="${INDEX_PREFIX}_read"
WRITE_ALIAS="${INDEX_PREFIX}_write"
CURRENT_ALIAS="${INDEX_PREFIX}_current"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

request() {
  local method="$1"
  local path="$2"
  local body_path="${3:-}"
  local url="${OPENSEARCH_URL%/}/${path#/}"

  if [[ -n "$body_path" ]]; then
    curl -fsS -X "$method" "$url" -H 'Content-Type: application/json' --data-binary "@${body_path}"
  else
    curl -fsS -X "$method" "$url"
  fi
}

delete_index() {
  local index_name="$1"
  local url="${OPENSEARCH_URL%/}/${index_name}"
  local status
  status="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$url")"
  if [[ "$status" == "200" || "$status" == "404" ]]; then
    echo "Delete check for ${index_name}: ${status}"
    return
  fi
  echo "Failed to delete ${index_name}: HTTP ${status}" >&2
  exit 1
}

hit_count() {
  jq -r '.hits.total.value // .hits.total'
}

echo "Using OpenSearch URL: ${OPENSEARCH_URL}"
HEALTHCHECK_JSON="$(request GET "_cluster/health")"

delete_index "$NESTED_INDEX"
delete_index "$FLATTENED_INDEX"

echo "Creating nested index ${NESTED_INDEX}"
NESTED_INDEX_CREATE_JSON="$(request PUT "$NESTED_INDEX" "${EXPERIMENT_DIR}/mappings/products_v1_nested.json")"

echo "Creating aliases for nested index"
ALIAS_CREATE_JSON="$(curl -fsS -X POST "${OPENSEARCH_URL%/}/_aliases" \
  -H 'Content-Type: application/json' \
  --data-binary @- <<JSON
{
  "actions": [
    { "add": { "index": "${NESTED_INDEX}", "alias": "${READ_ALIAS}" } },
    { "add": { "index": "${NESTED_INDEX}", "alias": "${WRITE_ALIAS}" } },
    { "add": { "index": "${NESTED_INDEX}", "alias": "${CURRENT_ALIAS}" } }
  ]
}
JSON
)"
ALIAS_VERIFICATION_JSON="$(request GET "${NESTED_INDEX}/_alias")"

echo "Indexing sample document into nested index"
NESTED_DOCUMENT_INDEX_JSON="$(request PUT "${NESTED_INDEX}/_doc/1?refresh=true" "${EXPERIMENT_DIR}/fixtures/sample-product-options.json")"

echo "Running nested negative same-row query"
NESTED_NEGATIVE_JSON="$(request POST "${NESTED_INDEX}/_search" "${EXPERIMENT_DIR}/queries/nested-option-filter-query.json")"
NESTED_NEGATIVE_COUNT="$(printf '%s' "$NESTED_NEGATIVE_JSON" | hit_count)"

echo "Running nested positive same-row query"
NESTED_POSITIVE_JSON="$(request POST "${NESTED_INDEX}/_search" "${EXPERIMENT_DIR}/queries/nested-option-filter-positive-query.json")"
NESTED_POSITIVE_COUNT="$(printf '%s' "$NESTED_POSITIVE_JSON" | hit_count)"

echo "Creating flattened/object candidate index ${FLATTENED_INDEX}"
FLATTENED_INDEX_CREATE_JSON="$(request PUT "$FLATTENED_INDEX" "${EXPERIMENT_DIR}/mappings/products_v1_flattened_candidate.json")"

echo "Indexing sample document into flattened/object candidate index"
FLATTENED_DOCUMENT_INDEX_JSON="$(request PUT "${FLATTENED_INDEX}/_doc/1?refresh=true" "${EXPERIMENT_DIR}/fixtures/sample-product-options.json")"

echo "Running flattened/object negative query"
FLATTENED_JSON="$(request POST "${FLATTENED_INDEX}/_search" "${EXPERIMENT_DIR}/queries/flattened-option-filter-query.json")"
FLATTENED_COUNT="$(printf '%s' "$FLATTENED_JSON" | hit_count)"

if [[ "$NESTED_NEGATIVE_COUNT" != "0" ]]; then
  echo "FAIL: nested negative query expected 0 hits, got ${NESTED_NEGATIVE_COUNT}" >&2
  exit 1
fi

if [[ "$NESTED_POSITIVE_COUNT" != "1" ]]; then
  echo "FAIL: nested positive query expected 1 hit, got ${NESTED_POSITIVE_COUNT}" >&2
  exit 1
fi

if [[ "$FLATTENED_COUNT" != "1" ]]; then
  echo "FAIL: flattened/object candidate query expected 1 false-positive hit, got ${FLATTENED_COUNT}" >&2
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="${EXPERIMENT_DIR}/results/${TIMESTAMP}"
mkdir -p "$RESULT_DIR"

printf '%s\n' "$HEALTHCHECK_JSON" | jq . > "${RESULT_DIR}/healthcheck-result.json"
printf '%s\n' "$NESTED_INDEX_CREATE_JSON" | jq . > "${RESULT_DIR}/nested-index-create-result.json"
printf '%s\n' "$ALIAS_CREATE_JSON" | jq . > "${RESULT_DIR}/alias-create-result.json"
printf '%s\n' "$ALIAS_VERIFICATION_JSON" | jq . > "${RESULT_DIR}/alias-verification-result.json"
printf '%s\n' "$NESTED_DOCUMENT_INDEX_JSON" | jq . > "${RESULT_DIR}/nested-document-index-result.json"
printf '%s\n' "$FLATTENED_INDEX_CREATE_JSON" | jq . > "${RESULT_DIR}/flattened-index-create-result.json"
printf '%s\n' "$FLATTENED_DOCUMENT_INDEX_JSON" | jq . > "${RESULT_DIR}/flattened-document-index-result.json"
printf '%s\n' "$NESTED_NEGATIVE_JSON" | jq . > "${RESULT_DIR}/nested-negative-query-result.json"
printf '%s\n' "$NESTED_POSITIVE_JSON" | jq . > "${RESULT_DIR}/nested-positive-query-result.json"
printf '%s\n' "$FLATTENED_JSON" | jq . > "${RESULT_DIR}/flattened-query-result.json"

cat > "${RESULT_DIR}/mapping-smoke-summary.md" <<EOF
# PR-A17 OpenSearch Mapping Smoke Summary

- OpenSearch URL: ${OPENSEARCH_URL}
- OpenSearch image: ${OPENSEARCH_IMAGE}
- Nested index: ${NESTED_INDEX}
- Flattened/object candidate index: ${FLATTENED_INDEX}
- Read alias: ${READ_ALIAS}
- Write alias: ${WRITE_ALIAS}
- Current alias: ${CURRENT_ALIAS}

| check | hits | result |
|---|---:|---|
| healthcheck | n/a | PASS |
| nested index creation | n/a | PASS |
| alias creation | n/a | PASS |
| nested sample document indexing | n/a | PASS |
| nested negative BLACK / M / IN_STOCK | ${NESTED_NEGATIVE_COUNT} | PASS |
| nested positive BLACK / S / IN_STOCK | ${NESTED_POSITIVE_COUNT} | PASS |
| flattened/object index creation | n/a | PASS |
| flattened/object sample document indexing | n/a | PASS |
| flattened/object negative BLACK / M / IN_STOCK | ${FLATTENED_COUNT} | PASS, false positive demonstrated |

Selected option representation: nested.

This smoke result is not a production capacity or latency claim.
EOF

echo "PASS: OpenSearch mapping smoke validation completed"
echo "Result artifacts: ${RESULT_DIR}"
