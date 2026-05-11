#!/usr/bin/env bash
set -euo pipefail

RUN_ID="${RUN_ID:-backlog-polling-delay-attribution-$(date +%Y%m%d-%H%M)}"
EVENT_COUNT="${EVENT_COUNT:-1000}"
BATCH_SIZE="${BATCH_SIZE:-100}"
FIXED_DELAY_MS_VALUES="${FIXED_DELAY_MS_VALUES:-5000 1000 100}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-180}"
STABILIZATION_SECONDS="${STABILIZATION_SECONDS:-3}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-readpath-baseline-postgres}"
POSTGRES_USER="${POSTGRES_USER:-marketplace}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-marketplace}"
POSTGRES_DATABASE="${POSTGRES_DATABASE:-marketplace}"
OPENSEARCH_URL="${OPENSEARCH_URL:-http://localhost:9200}"
APP_PORT="${APP_PORT:-18080}"
APP_JAVA_OPTS="${APP_JAVA_OPTS:--Xms64m -Xmx160m}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${EXPERIMENT_DIR}/../../.." && pwd)"
MAPPING_PATH="${REPO_ROOT}/db/experiments/a1-opensearch-index-mapping-alias/mappings/products_v1_nested.json"
MEASURE_SQL_PATH="${EXPERIMENT_DIR}/sql/measure-indexing-lag.sql"
RESULT_DIR="${EXPERIMENT_DIR}/results/${RUN_ID}"
RESULT_PATH="${RESULT_DIR}/result.txt"
WRITE_ALIAS="products_search_backlog_polling_delay_write"
PRODUCT_START_ID="-36100000"
APP_JAR="${REPO_ROOT}/build/libs/marketplace-0.0.1-SNAPSHOT.jar"

mkdir -p "${RESULT_DIR}"

psql_text() {
  local tuples_only="${1:-false}"
  local args=(
    exec -i "${POSTGRES_CONTAINER}"
    psql
    -U "${POSTGRES_USER}"
    -d "${POSTGRES_DATABASE}"
    -v ON_ERROR_STOP=1
    -q
  )
  if [[ "${tuples_only}" == "true" ]]; then
    args+=(-t -A)
  fi
  docker "${args[@]}"
}

opensearch_request() {
  local method="$1"
  local path="$2"
  local body_path="${3:-}"
  if [[ -n "${body_path}" ]]; then
    curl -fsS -X "${method}" \
      -H "Content-Type: application/json" \
      --data-binary @"${body_path}" \
      "${OPENSEARCH_URL%/}/${path#/}" >/dev/null
  else
    curl -fsS -X "${method}" "${OPENSEARCH_URL%/}/${path#/}" >/dev/null
  fi
}

opensearch_json() {
  local method="$1"
  local path="$2"
  local body="$3"
  curl -fsS -X "${method}" \
    -H "Content-Type: application/json" \
    -d "${body}" \
    "${OPENSEARCH_URL%/}/${path#/}" >/dev/null
}

initialize_opensearch_target() {
  local index_name="$1"
  curl -sS -X DELETE "${OPENSEARCH_URL%/}/${index_name}" >/dev/null || true
  opensearch_request PUT "${index_name}" "${MAPPING_PATH}"
  curl -sS -X DELETE "${OPENSEARCH_URL%/}/_all/_alias/${WRITE_ALIAS}" >/dev/null || true
  opensearch_json POST "_aliases" "{\"actions\":[{\"add\":{\"index\":\"${index_name}\",\"alias\":\"${WRITE_ALIAS}\"}}]}"
}

initialize_postgres_schema() {
  psql_text false <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS products (
    id BIGSERIAL PRIMARY KEY,
    seller_id BIGINT NOT NULL,
    category_id BIGINT NOT NULL,
    brand_id BIGINT NOT NULL,
    status VARCHAR(20) NOT NULL,
    price INTEGER NOT NULL CHECK (price >= 0),
    rating NUMERIC(3,2) NOT NULL CHECK (rating >= 0 AND rating <= 5),
    review_count INTEGER NOT NULL CHECK (review_count >= 0),
    created_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP NOT NULL,
    CHECK (status IN ('ACTIVE', 'SOLD_OUT', 'DELETED'))
);

CREATE TABLE IF NOT EXISTS product_options (
    id BIGSERIAL PRIMARY KEY,
    product_id BIGINT NOT NULL REFERENCES products(id),
    color VARCHAR(20) NOT NULL,
    size VARCHAR(10) NOT NULL,
    stock_status VARCHAR(20) NOT NULL,
    CHECK (color IN ('BLACK', 'WHITE', 'RED', 'BLUE', 'GREEN', 'GRAY', 'NAVY', 'BEIGE')),
    CHECK (size IN ('XS', 'S', 'M', 'L', 'XL', 'FREE')),
    CHECK (stock_status IN ('IN_STOCK', 'LOW_STOCK', 'OUT_OF_STOCK'))
);

CREATE TABLE IF NOT EXISTS search_outbox (
    id BIGSERIAL PRIMARY KEY,
    aggregate_type VARCHAR(40) NOT NULL,
    aggregate_id BIGINT NOT NULL,
    event_type VARCHAR(80) NOT NULL,
    schema_version INTEGER NOT NULL DEFAULT 1,
    payload JSONB NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    claim_token UUID,
    claimed_by VARCHAR(120),
    claimed_at TIMESTAMPTZ,
    retry_count INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    next_retry_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ,
    CHECK (aggregate_type IN ('PRODUCT')),
    CHECK (event_type IN (
        'PRODUCT_CREATED',
        'PRODUCT_UPDATED',
        'PRODUCT_DELETED',
        'PRODUCT_STATUS_CHANGED',
        'PRODUCT_OPTION_CHANGED'
    )),
    CHECK (status IN ('PENDING', 'PROCESSING', 'DONE', 'FAILED')),
    CHECK (schema_version >= 1),
    CHECK (retry_count >= 0),
    CHECK (
        (status IN ('DONE', 'FAILED') AND processed_at IS NOT NULL)
        OR status IN ('PENDING', 'PROCESSING')
    )
);

ALTER TABLE search_outbox
ADD COLUMN IF NOT EXISTS claimed_by VARCHAR(120);

ALTER TABLE search_outbox
ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_product_options_product_id
ON product_options(product_id);

CREATE INDEX IF NOT EXISTS idx_search_outbox_pending_next_retry
ON search_outbox(created_at, id)
WHERE status = 'PENDING';

CREATE INDEX IF NOT EXISTS idx_search_outbox_aggregate
ON search_outbox(aggregate_type, aggregate_id, id);

CREATE INDEX IF NOT EXISTS idx_search_outbox_status_created
ON search_outbox(status, created_at, id);
SQL
}

clear_postgres_smoke_rows() {
  psql_text false <<SQL >/dev/null
DELETE FROM search_outbox WHERE payload->>'smokeRun' LIKE 'backlog-polling-delay-%';
DELETE FROM product_options WHERE product_id BETWEEN -36110000 AND -36100001;
DELETE FROM products WHERE id BETWEEN -36110000 AND -36100001;
SQL
}

initialize_postgres_rows() {
  local case_run_id="$1"
  psql_text false <<SQL >/dev/null
INSERT INTO products (id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at)
SELECT
    ${PRODUCT_START_ID} - seq,
    4500 + seq,
    75,
    900 + (seq % 10),
    'ACTIVE',
    10000 + seq,
    4.50,
    seq,
    now(),
    now()
FROM generate_series(1, ${EVENT_COUNT}) AS seq;

INSERT INTO product_options (product_id, color, size, stock_status)
SELECT
    ${PRODUCT_START_ID} - seq,
    'BLACK',
    'M',
    'IN_STOCK'
FROM generate_series(1, ${EVENT_COUNT}) AS seq;

INSERT INTO search_outbox (aggregate_type, aggregate_id, event_type, payload, created_at, updated_at)
SELECT
    'PRODUCT',
    ${PRODUCT_START_ID} - seq,
    'PRODUCT_UPDATED',
    jsonb_build_object(
        'productId', ${PRODUCT_START_ID} - seq,
        'eventType', 'PRODUCT_UPDATED',
        'smokeRun', '${case_run_id}',
        'tombstone', false
    ),
    now(),
    now()
FROM generate_series(1, ${EVENT_COUNT}) AS seq;
SQL
}

status_counts() {
  local case_run_id="$1"
  psql_text true <<SQL
SELECT jsonb_build_object(
    'doneCount', COUNT(*) FILTER (WHERE status = 'DONE'),
    'failedCount', COUNT(*) FILTER (WHERE status = 'FAILED'),
    'pendingCount', COUNT(*) FILTER (WHERE status = 'PENDING'),
    'processingCount', COUNT(*) FILTER (WHERE status = 'PROCESSING'),
    'retryCount', COALESCE(SUM(retry_count), 0)
)::text
FROM search_outbox
WHERE payload->>'smokeRun' = '${case_run_id}';
SQL
}

json_field() {
  local field="$1"
  python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "${field}"
}

wait_case_done() {
  local case_run_id="$1"
  local deadline=$((SECONDS + 240))
  local counts
  while (( SECONDS < deadline )); do
    counts="$(status_counts "${case_run_id}")"
    local done failed
    done="$(printf '%s' "${counts}" | json_field doneCount)"
    failed="$(printf '%s' "${counts}" | json_field failedCount)"
    if [[ "${done}" == "${EVENT_COUNT}" || "${failed}" != "0" ]]; then
      printf '%s' "${counts}"
      return 0
    fi
    sleep 0.5
  done
  status_counts "${case_run_id}"
}

wait_spring_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    local health_body
    health_body="$(curl -fsS "http://localhost:${APP_PORT}/actuator/health" 2>/dev/null || true)"
    if [[ -n "${health_body}" ]] && printf '%s' "${health_body}" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("status") == "UP" else 1)' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Spring app did not become healthy within ${HEALTH_TIMEOUT_SECONDS} seconds" >&2
  return 1
}

stop_spring_app() {
  local pid="${1:-}"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
}

measure_lag() {
  local case_run_id="$1"
  docker exec -i "${POSTGRES_CONTAINER}" psql \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DATABASE}" \
    -v ON_ERROR_STOP=1 \
    -q -t -A \
    -v "smoke_run=${case_run_id}" < "${MEASURE_SQL_PATH}"
}

measure_db_summary() {
  local case_run_id="$1"
  psql_text true <<SQL
WITH scoped AS (
    SELECT *
    FROM search_outbox
    WHERE payload->>'smokeRun' = '${case_run_id}'
),
queue_wait AS (
    SELECT EXTRACT(EPOCH FROM (claimed_at - created_at)) * 1000.0 AS queue_wait_ms
    FROM scoped
    WHERE claimed_at IS NOT NULL
),
batch_claims AS (
    SELECT DISTINCT claimed_by, claimed_at
    FROM scoped
    WHERE claimed_by IS NOT NULL
      AND claimed_at IS NOT NULL
),
claimed_by_counts AS (
    SELECT claimed_by, COUNT(*) AS row_count
    FROM scoped
    GROUP BY claimed_by
),
duplicate_aggregates AS (
    SELECT aggregate_id
    FROM scoped
    GROUP BY aggregate_id
    HAVING COUNT(*) > 1
)
SELECT jsonb_build_object(
    'queueWaitMs', jsonb_build_object(
        'p95', COALESCE((SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY queue_wait_ms) FROM queue_wait), 0)
    ),
    'batchClaimCount', (SELECT COUNT(*) FROM batch_claims),
    'claimedByCounts', (
        SELECT jsonb_agg(jsonb_build_object(
            'claimedBy', claimed_by,
            'rowCount', row_count
        ) ORDER BY claimed_by)
        FROM claimed_by_counts
    ),
    'duplicateClaimDetected', EXISTS (SELECT 1 FROM duplicate_aggregates)
)::text
FROM scoped
LIMIT 1;
SQL
}

append_case_result() {
  local fixed_delay_ms="$1"
  local case_run_id="$2"
  local total_processing_time_ms="$3"
  local counts_json="$4"
  local lag_json="$5"
  local db_summary_json="$6"

  python3 - "${RESULT_PATH}" "${fixed_delay_ms}" "${case_run_id}" "${EVENT_COUNT}" "${BATCH_SIZE}" \
    "${total_processing_time_ms}" "${counts_json}" "${lag_json}" "${db_summary_json}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
fixed_delay_ms = int(sys.argv[2])
case_run_id = sys.argv[3]
event_count = int(sys.argv[4])
batch_size = int(sys.argv[5])
total_processing_time_ms = int(sys.argv[6])
counts = json.loads(sys.argv[7])
lag = json.loads(sys.argv[8])
db_summary = json.loads(sys.argv[9])
claimed_by_counts = ", ".join(
    f"{item['claimedBy']}={item['rowCount']}" for item in db_summary["claimedByCounts"]
)

with path.open("a", encoding="utf-8") as output:
    output.write(
        "| {fixed_delay_ms} | {total_processing_time_ms} | {done} | {failed} | {pending} | "
        "{processing} | {total_p95} | {queue_p95} | {batch_claim_count} | {claimed_by_counts} | "
        "{duplicate_claim} | {retry_failed} | {case_run_id} |\n".format(
            fixed_delay_ms=fixed_delay_ms,
            total_processing_time_ms=total_processing_time_ms,
            done=counts["doneCount"],
            failed=counts["failedCount"],
            pending=counts["pendingCount"],
            processing=counts["processingCount"],
            total_p95=lag["totalIndexingLagMs"]["p95"],
            queue_p95=db_summary["queueWaitMs"]["p95"],
            batch_claim_count=db_summary["batchClaimCount"],
            claimed_by_counts=claimed_by_counts,
            duplicate_claim=str(db_summary["duplicateClaimDetected"]).lower(),
            retry_failed=str(int(counts["retryCount"]) > 0 or int(counts["failedCount"]) > 0).lower(),
            case_run_id=case_run_id,
        )
    )

if counts["doneCount"] != event_count:
    raise SystemExit(f"Expected DONE {event_count}, got {counts['doneCount']}")
if counts["failedCount"] != 0 or counts["pendingCount"] != 0 or counts["processingCount"] != 0:
    raise SystemExit(
        "Expected FAILED/PENDING/PROCESSING 0, got "
        f"failed={counts['failedCount']} pending={counts['pendingCount']} processing={counts['processingCount']}"
    )
if db_summary["duplicateClaimDetected"]:
    raise SystemExit("Duplicate claim detected")
if int(counts["retryCount"]) > 0 or int(counts["failedCount"]) > 0:
    raise SystemExit("Retry or failed relay detected")
PY
}

run_case() {
  local fixed_delay_ms="$1"
  local case_run_id="backlog-polling-delay-${RUN_ID}-${fixed_delay_ms}"
  local index_name="products_search_backlog_polling_delay_${fixed_delay_ms}_$(date +%s)"
  local app_log_path="/tmp/${RUN_ID}-${fixed_delay_ms}-spring-app.log"
  local pid=""

  initialize_opensearch_target "${index_name}"
  clear_postgres_smoke_rows

  (
    export JAVA_TOOL_OPTIONS="${APP_JAVA_OPTS}"
    export SPRING_DATASOURCE_URL="jdbc:postgresql://localhost:15432/${POSTGRES_DATABASE}"
    export SPRING_DATASOURCE_USERNAME="${POSTGRES_USER}"
    export SPRING_DATASOURCE_PASSWORD="${POSTGRES_PASSWORD}"
    export SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE="2"
    export SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE="1"
    export SPRING_JPA_DATABASE_PLATFORM="org.hibernate.dialect.PostgreSQLDialect"
    export READPATH_PRODUCT_SEARCH_OPEN_SEARCH_BASE_URL="${OPENSEARCH_URL}"
    export READPATH_PRODUCT_SEARCH_OPEN_SEARCH_WRITE_ALIAS="${WRITE_ALIAS}"
    export READPATH_PRODUCT_SEARCH_INDEXING_RELAY_ENABLED="true"
    export READPATH_PRODUCT_SEARCH_INDEXING_RELAY_BATCH_SIZE="${BATCH_SIZE}"
    export READPATH_PRODUCT_SEARCH_INDEXING_RELAY_FIXED_DELAY_MS="${fixed_delay_ms}"
    export READPATH_PRODUCT_SEARCH_INDEXING_RELAY_INSTANCE_ID="spring-app-1"
    export MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE="health"
    exec java -jar "${APP_JAR}" --server.port="${APP_PORT}"
  ) > "${app_log_path}" 2>&1 &
  pid="$!"
  trap 'stop_spring_app "${pid}"' RETURN

  wait_spring_healthy
  sleep "${STABILIZATION_SECONDS}"

  initialize_postgres_rows "${case_run_id}"
  local start_ms
  local counts_json
  local end_ms
  local lag_json
  local db_summary_json
  start_ms="$(date +%s%3N)"
  counts_json="$(wait_case_done "${case_run_id}")"
  end_ms="$(date +%s%3N)"
  stop_spring_app "${pid}"
  trap - RETURN

  lag_json="$(measure_lag "${case_run_id}")"
  db_summary_json="$(measure_db_summary "${case_run_id}")"
  append_case_result "${fixed_delay_ms}" "${case_run_id}" "$((end_ms - start_ms))" \
    "${counts_json}" "${lag_json}" "${db_summary_json}"
  rm -f "${app_log_path}"
}

bash "${REPO_ROOT}/gradlew" --no-daemon bootJar
initialize_postgres_schema

cat > "${RESULT_PATH}" <<EOF
# Backlog polling delay attribution

conditions: local PostgreSQL + local OpenSearch, eventCount=${EVENT_COUNT}, batchSize=${BATCH_SIZE}, replicaCount=1, health UP before insert, stabilizationSeconds=${STABILIZATION_SECONDS}

| fixedDelayMs | totalProcessingTimeMs | DONE | FAILED | PENDING | PROCESSING | totalIndexingLagMs p95 | queueWaitMs p95 | batchClaimCount | row count by claimed_by | duplicate claim | retry/failed | runId |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|---|
EOF

for fixed_delay_ms in ${FIXED_DELAY_MS_VALUES}; do
  run_case "${fixed_delay_ms}"
done

echo "RESULT_PATH=${RESULT_PATH}"
