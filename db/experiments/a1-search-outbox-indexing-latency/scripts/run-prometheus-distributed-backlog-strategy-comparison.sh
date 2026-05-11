#!/usr/bin/env bash
set -euo pipefail

RUN_ID="${RUN_ID:-prometheus-distributed-backlog-strategy-comparison-$(date +%Y%m%d-%H%M)}"
EVENT_COUNT="${EVENT_COUNT:-4000}"
REPLICA_COUNT="${REPLICA_COUNT:-4}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-180}"
STABILIZATION_SECONDS="${STABILIZATION_SECONDS:-3}"
IDLE_SECONDS="${IDLE_SECONDS:-30}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-readpath-baseline-postgres}"
POSTGRES_USER="${POSTGRES_USER:-marketplace}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-marketplace}"
POSTGRES_DATABASE="${POSTGRES_DATABASE:-marketplace}"
OPENSEARCH_URL="${OPENSEARCH_URL:-http://localhost:9200}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:19090}"
APP_PORT_BASE="${APP_PORT_BASE:-18100}"
APP_JAVA_OPTS="${APP_JAVA_OPTS:--Xms64m -Xmx192m}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${EXPERIMENT_DIR}/../../.." && pwd)"
MAPPING_PATH="${REPO_ROOT}/db/experiments/a1-opensearch-index-mapping-alias/mappings/products_v1_nested.json"
MEASURE_SQL_PATH="${EXPERIMENT_DIR}/sql/measure-indexing-lag.sql"
PROMETHEUS_CONTAINER="${PROMETHEUS_CONTAINER:-search-outbox-relay-prometheus-smoke}"
PROMETHEUS_CONFIG_PATH="/tmp/${RUN_ID}-prometheus.yml"
DOCKER_NETWORK="${DOCKER_NETWORK:-search-outbox-relay-prometheus-smoke}"
RESULT_DIR="${EXPERIMENT_DIR}/results/${RUN_ID}"
RESULT_PATH="${RESULT_DIR}/result.txt"
WRITE_ALIAS="products_search_prometheus_distributed_backlog_write"
PRODUCT_START_ID="-36300000"
APP_JAR="${REPO_ROOT}/build/libs/marketplace-0.0.1-SNAPSHOT.jar"
INSTANCE_REGEX="spring-app-[1-4]"

mkdir -p "${RESULT_DIR}"
MAIN_ROWS="$(mktemp)"
REPLICA_ROWS="$(mktemp)"
IDLE_ROWS="$(mktemp)"
ORDER_ROWS="$(mktemp)"

cleanup() {
  rm -f "${MAIN_ROWS}" "${REPLICA_ROWS}" "${IDLE_ROWS}" "${ORDER_ROWS}"
}
trap cleanup EXIT

now_seconds() {
  python3 -c 'import time; print(f"{time.time():.3f}")'
}

window_seconds() {
  python3 - "$1" "$2" <<'PY'
import math
import sys
start = float(sys.argv[1])
end = float(sys.argv[2])
print(max(1, math.ceil(end - start) + 2))
PY
}

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

prom_query() {
  local query="$1"
  local at_time="$2"
  python3 - "${PROMETHEUS_URL}" "${query}" "${at_time}" <<'PY'
import json
import sys
import urllib.parse
import urllib.request

base_url, query, at_time = sys.argv[1], sys.argv[2], sys.argv[3]
params = urllib.parse.urlencode({"query": query, "time": at_time})
with urllib.request.urlopen(f"{base_url.rstrip('/')}/api/v1/query?{params}", timeout=10) as response:
    payload = json.load(response)
if payload.get("status") != "success":
    raise SystemExit(payload)
result = payload.get("data", {}).get("result", [])
if not result:
    print("0")
else:
    print(result[0]["value"][1])
PY
}

prom_ready() {
  curl -fsS "${PROMETHEUS_URL}/-/ready" >/dev/null
}

start_prometheus() {
  docker network rm "${DOCKER_NETWORK}" >/dev/null 2>&1 || true
  docker network create "${DOCKER_NETWORK}" >/dev/null
  cat > "${PROMETHEUS_CONFIG_PATH}" <<EOF
global:
  scrape_interval: 1s
  evaluation_interval: 1s

scrape_configs:
  - job_name: spring-replica-relay
    metrics_path: /actuator/prometheus
    static_configs:
      - targets:
          - spring-app-1:8080
          - spring-app-2:8080
          - spring-app-3:8080
          - spring-app-4:8080
          - baseline-spring-app-1:8080
          - baseline-spring-app-2:8080
          - baseline-spring-app-3:8080
          - baseline-spring-app-4:8080
          - shorter-polling-spring-app-1:8080
          - shorter-polling-spring-app-2:8080
          - shorter-polling-spring-app-3:8080
          - shorter-polling-spring-app-4:8080
          - larger-batch-spring-app-1:8080
          - larger-batch-spring-app-2:8080
          - larger-batch-spring-app-3:8080
          - larger-batch-spring-app-4:8080
          - multi-batch-spring-app-1:8080
          - multi-batch-spring-app-2:8080
          - multi-batch-spring-app-3:8080
          - multi-batch-spring-app-4:8080
EOF
  docker rm -f "${PROMETHEUS_CONTAINER}" >/dev/null 2>&1 || true
  docker run -d \
    --name "${PROMETHEUS_CONTAINER}" \
    --network "${DOCKER_NETWORK}" \
    -p 19090:9090 \
    -v "${PROMETHEUS_CONFIG_PATH}:/etc/prometheus/prometheus.yml:ro" \
    prom/prometheus:v3.0.1 \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.retention.time=2h \
    --web.enable-lifecycle >/dev/null
  local deadline=$((SECONDS + 60))
  until prom_ready; do
    if (( SECONDS >= deadline )); then
      echo "Prometheus did not become ready" >&2
      return 1
    fi
    sleep 1
  done
}

stop_prometheus() {
  docker rm -f "${PROMETHEUS_CONTAINER}" >/dev/null 2>&1 || true
  docker network rm "${DOCKER_NETWORK}" >/dev/null 2>&1 || true
  rm -f "${PROMETHEUS_CONFIG_PATH}"
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

ALTER TABLE search_outbox ADD COLUMN IF NOT EXISTS claimed_by VARCHAR(120);
ALTER TABLE search_outbox ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_product_options_product_id ON product_options(product_id);
CREATE INDEX IF NOT EXISTS idx_product_options_color_size_stock_product
ON product_options(color, size, stock_status, product_id);
CREATE INDEX IF NOT EXISTS idx_search_outbox_pending_next_retry
ON search_outbox(created_at, id)
WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS idx_search_outbox_aggregate ON search_outbox(aggregate_type, aggregate_id, id);
CREATE INDEX IF NOT EXISTS idx_search_outbox_status_created ON search_outbox(status, created_at, id);
SQL
}

clear_postgres_smoke_rows() {
  psql_text false <<SQL >/dev/null
DELETE FROM search_outbox WHERE payload->>'smokeRun' LIKE 'prometheus-distributed-backlog-%';
DELETE FROM product_options WHERE product_id BETWEEN -36310000 AND -36300001;
DELETE FROM products WHERE id BETWEEN -36310000 AND -36300001;
SQL
}

initialize_postgres_rows() {
  local case_run_id="$1"
  psql_text false <<SQL >/dev/null
INSERT INTO products (id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at)
SELECT
    ${PRODUCT_START_ID} - seq,
    6500 + seq,
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
  local deadline=$((SECONDS + 300))
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

wait_spring_replicas_healthy() {
  local replica_count="$1"
  shift
  local ports=("$@")
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    local healthy=0
    for port in "${ports[@]}"; do
      local health_body
      health_body="$(curl -fsS "http://localhost:${port}/actuator/health" 2>/dev/null || true)"
      if [[ "${health_body}" == *'"status":"UP"'* ]]; then
        healthy=$((healthy + 1))
      fi
    done
    if [[ "${healthy}" -eq "${replica_count}" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "Spring app replicas did not become healthy within ${HEALTH_TIMEOUT_SECONDS} seconds" >&2
  return 1
}

wait_prometheus_targets_ready() {
  local target_regex="$1"
  local deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    local up_count scrape_count
    up_count="$(prom_query "sum(up{job=\"spring-replica-relay\",instance=~\"${target_regex}\"})" "$(now_seconds)" || echo 0)"
    scrape_count="$(prom_query "min(count_over_time(up{job=\"spring-replica-relay\",instance=~\"${target_regex}\"}[5s]))" "$(now_seconds)" || echo 0)"
    if python3 - "${up_count}" "${scrape_count}" "${REPLICA_COUNT}" <<'PY'
import sys
up_count = float(sys.argv[1])
scrape_count = float(sys.argv[2])
replica_count = float(sys.argv[3])
sys.exit(0 if up_count == replica_count and scrape_count >= 2 else 1)
PY
    then
      return 0
    fi
    sleep 1
  done
  echo "Prometheus targets did not become UP with at least two scrapes" >&2
  return 1
}

wait_prometheus_scheduler_metrics_ready() {
  local target_regex="$1"
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    local empty_run_count processed_rows_series_count
    empty_run_count="$(prom_query "sum(product_search_outbox_relay_scheduler_runs_total{job=\"spring-replica-relay\",instance=~\"${target_regex}\",result=\"empty\"})" "$(now_seconds)" || echo 0)"
    processed_rows_series_count="$(prom_query "count(product_search_outbox_relay_processed_rows_total{job=\"spring-replica-relay\",instance=~\"${target_regex}\"})" "$(now_seconds)" || echo 0)"
    if python3 - "${empty_run_count}" "${processed_rows_series_count}" "${REPLICA_COUNT}" <<'PY'
import sys
empty_run_count = float(sys.argv[1])
processed_rows_series_count = float(sys.argv[2])
replica_count = float(sys.argv[3])
sys.exit(0 if empty_run_count >= replica_count and processed_rows_series_count >= replica_count else 1)
PY
    then
      return 0
    fi
    sleep 1
  done
  echo "Prometheus did not scrape initial empty scheduler metrics" >&2
  return 1
}

wait_prometheus_processed_rows() {
  local target_regex="$1"
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    local processed_rows
    processed_rows="$(prom_query "sum(product_search_outbox_relay_processed_rows_total{job=\"spring-replica-relay\",instance=~\"${target_regex}\"})" "$(now_seconds)" || echo 0)"
    if python3 - "${processed_rows}" "${EVENT_COUNT}" <<'PY'
import sys
processed_rows = float(sys.argv[1])
event_count = float(sys.argv[2])
sys.exit(0 if processed_rows >= event_count else 1)
PY
    then
      return 0
    fi
    sleep 1
  done
  echo "Prometheus processedRowsTotal did not reach eventCount" >&2
  return 1
}

stop_spring_replicas() {
  local containers=("$@")
  for container in "${containers[@]}"; do
    docker rm -f "${container}" >/dev/null 2>&1 || true
  done
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
claim_groups AS (
    SELECT claimed_by, claimed_at, COUNT(*) AS rows_per_claim
    FROM scoped
    WHERE claimed_by IS NOT NULL
      AND claimed_at IS NOT NULL
    GROUP BY claimed_by, claimed_at
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
        'p50', COALESCE((SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY queue_wait_ms) FROM queue_wait), 0),
        'p95', COALESCE((SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY queue_wait_ms) FROM queue_wait), 0),
        'p99', COALESCE((SELECT percentile_cont(0.99) WITHIN GROUP (ORDER BY queue_wait_ms) FROM queue_wait), 0),
        'max', COALESCE((SELECT MAX(queue_wait_ms) FROM queue_wait), 0)
    ),
    'batchClaimCount', (SELECT COUNT(*) FROM claim_groups),
    'avgRowsPerClaim', COALESCE((SELECT AVG(rows_per_claim) FROM claim_groups), 0),
    'maxRowsPerClaim', COALESCE((SELECT MAX(rows_per_claim) FROM claim_groups), 0),
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

collect_prometheus_summary() {
  local window_start="$1"
  local window_end="$2"
  local target_regex="$3"
  local phase="$4"
  local window_size
  window_size="$(window_seconds "${window_start}" "${window_end}")"
  python3 - "${PROMETHEUS_URL}" "${window_start}" "${window_end}" "${window_size}" "${INSTANCE_REGEX}" "${target_regex}" "${phase}" <<'PY'
import json
import sys
import urllib.parse
import urllib.request

base_url, start_time, end_time, window_size, instance_regex, target_regex, phase = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]

def query(promql):
    params = urllib.parse.urlencode({"query": promql, "time": end_time})
    with urllib.request.urlopen(f"{base_url.rstrip('/')}/api/v1/query?{params}", timeout=10) as response:
        payload = json.load(response)
    if payload.get("status") != "success":
        raise SystemExit(payload)
    result = payload.get("data", {}).get("result", [])
    if not result:
        return 0.0
    return float(result[0]["value"][1])

def counter_delta(selector):
    start_params = urllib.parse.urlencode({"query": f"sum({selector})", "time": start_time})
    end_params = urllib.parse.urlencode({"query": f"sum({selector})", "time": end_time})
    def value(params):
        with urllib.request.urlopen(f"{base_url.rstrip('/')}/api/v1/query?{params}", timeout=10) as response:
            payload = json.load(response)
        if payload.get("status") != "success":
            raise SystemExit(payload)
        result = payload.get("data", {}).get("result", [])
        if not result:
            return 0.0
        return float(result[0]["value"][1])
    return max(0.0, value(end_params) - value(start_params))

selector = f'instance_id=~"{instance_regex}",instance=~"{target_regex}"'
window = f"{window_size}s"
scheduler_runs = counter_delta(f'product_search_outbox_relay_scheduler_runs_total{{{selector}}}')
empty_runs = counter_delta(f'product_search_outbox_relay_scheduler_runs_total{{{selector},result="empty"}}')
non_empty_runs = counter_delta(f'product_search_outbox_relay_scheduler_runs_total{{{selector},result="non_empty"}}')
batch_attempts = counter_delta(f'product_search_outbox_relay_batch_attempts_total{{{selector}}}')
empty_batch_attempts = counter_delta(f'product_search_outbox_relay_batch_attempts_total{{{selector},result="empty"}}')
non_empty_batch_attempts = counter_delta(f'product_search_outbox_relay_batch_attempts_total{{{selector},result="non_empty"}}')
if phase == "drain":
    processed_rows = query(f'max_over_time(sum(product_search_outbox_relay_processed_rows_total{{{selector}}})[{window}:1s])')
else:
    processed_rows = counter_delta(f'product_search_outbox_relay_processed_rows_total{{{selector}}}')
duration_p95 = query(f'max(max_over_time(product_search_outbox_relay_scheduler_run_duration_seconds{{{selector},quantile="0.95"}}[{window}]))')
claim_rows_p50 = query(f'max(max_over_time(product_search_outbox_relay_claim_rows{{{selector},quantile="0.5"}}[{window}]))')
claim_rows_p95 = query(f'max(max_over_time(product_search_outbox_relay_claim_rows{{{selector},quantile="0.95"}}[{window}]))')
claim_rows_max = query(f'max(max_over_time(product_search_outbox_relay_claim_rows_max{{{selector}}}[{window}]))')

summary = {
    "schedulerRunCount": scheduler_runs,
    "emptyRunCount": empty_runs,
    "nonEmptyRunCount": non_empty_runs,
    "emptyRunRatio": 0 if scheduler_runs == 0 else empty_runs / scheduler_runs,
    "batchAttemptCount": batch_attempts,
    "emptyBatchAttemptCount": empty_batch_attempts,
    "nonEmptyBatchAttemptCount": non_empty_batch_attempts,
    "processedRowsTotal": processed_rows,
    "schedulerRunDurationP95": duration_p95,
    "claimRowsP50": claim_rows_p50,
    "claimRowsP95": claim_rows_p95,
    "claimRowsMax": claim_rows_max,
}
print(json.dumps(summary))
PY
}

append_case_rows() {
  local order="$1"
  local case_name="$2"
  local batch_size="$3"
  local fixed_delay_ms="$4"
  local max_drain_rounds="$5"
  local drain_start="$6"
  local drain_end="$7"
  local idle_start="$8"
  local idle_end="$9"
  local total_processing_time_ms="${10}"
  local counts_json="${11}"
  local lag_json="${12}"
  local db_summary_json="${13}"
  local drain_prom_json="${14}"
  local idle_prom_json="${15}"

  python3 - "${ORDER_ROWS}" "${MAIN_ROWS}" "${REPLICA_ROWS}" "${IDLE_ROWS}" \
    "${order}" "${case_name}" "${batch_size}" "${fixed_delay_ms}" "${max_drain_rounds}" \
    "${drain_start}" "${drain_end}" "${idle_start}" "${idle_end}" "${EVENT_COUNT}" \
    "${total_processing_time_ms}" "${counts_json}" "${lag_json}" "${db_summary_json}" \
    "${drain_prom_json}" "${idle_prom_json}" <<'PY'
import json
import sys
from pathlib import Path

order_rows, main_rows, replica_rows, idle_rows = map(Path, sys.argv[1:5])
order = int(sys.argv[5])
case_name = sys.argv[6]
batch_size = int(sys.argv[7])
fixed_delay_ms = int(sys.argv[8])
max_drain_rounds = int(sys.argv[9])
drain_start = sys.argv[10]
drain_end = sys.argv[11]
idle_start = sys.argv[12]
idle_end = sys.argv[13]
event_count = int(sys.argv[14])
total_processing_time_ms = int(sys.argv[15])
counts = json.loads(sys.argv[16])
lag = json.loads(sys.argv[17])
db_summary = json.loads(sys.argv[18])
drain_prom = json.loads(sys.argv[19])
idle_prom = json.loads(sys.argv[20])
events_per_second = round(event_count * 1000.0 / total_processing_time_ms, 2)

def rounded(value, digits=3):
    return round(float(value), digits)

with order_rows.open("a", encoding="utf-8") as output:
    output.write(f"| {order} | {case_name} | {drain_start} | {drain_end} | {idle_start} | {idle_end} |\n")

with main_rows.open("a", encoding="utf-8") as output:
    output.write(
        "| {order} | {case_name} | {batch_size} | {fixed_delay_ms} | {max_drain_rounds} | "
        "{total_processing_time_ms} | {events_per_second} | "
        "{scheduler_runs} | {empty_runs} | {non_empty_runs} | {batch_attempts} | "
        "{processed_rows} | {duration_p95} | {claim_p50} | {claim_p95} | {claim_max} | "
        "{queue_p50} | {queue_p95} | {queue_p99} | {queue_max} | "
        "{total_p50} | {total_p95} | {total_p99} | {total_max} | "
        "{batch_claim_count} | {avg_rows_per_claim} | {max_rows_per_claim} | "
        "{done} | {failed} | {pending} | {processing} | {retry_count} | {duplicate_claim} | "
        "{db_prom_processed_match} |\n".format(
            order=order,
            case_name=case_name,
            batch_size=batch_size,
            fixed_delay_ms=fixed_delay_ms,
            max_drain_rounds=max_drain_rounds,
            total_processing_time_ms=total_processing_time_ms,
            events_per_second=events_per_second,
            scheduler_runs=rounded(drain_prom["schedulerRunCount"]),
            empty_runs=rounded(drain_prom["emptyRunCount"]),
            non_empty_runs=rounded(drain_prom["nonEmptyRunCount"]),
            batch_attempts=rounded(drain_prom["batchAttemptCount"]),
            processed_rows=rounded(drain_prom["processedRowsTotal"]),
            duration_p95=rounded(drain_prom["schedulerRunDurationP95"], 6),
            claim_p50=rounded(drain_prom["claimRowsP50"]),
            claim_p95=rounded(drain_prom["claimRowsP95"]),
            claim_max=rounded(drain_prom["claimRowsMax"]),
            queue_p50=db_summary["queueWaitMs"]["p50"],
            queue_p95=db_summary["queueWaitMs"]["p95"],
            queue_p99=db_summary["queueWaitMs"]["p99"],
            queue_max=db_summary["queueWaitMs"]["max"],
            total_p50=lag["totalIndexingLagMs"]["p50"],
            total_p95=lag["totalIndexingLagMs"]["p95"],
            total_p99=lag["totalIndexingLagMs"]["p99"],
            total_max=lag["totalIndexingLagMs"]["max"],
            batch_claim_count=db_summary["batchClaimCount"],
            avg_rows_per_claim=round(float(db_summary["avgRowsPerClaim"]), 2),
            max_rows_per_claim=db_summary["maxRowsPerClaim"],
            done=counts["doneCount"],
            failed=counts["failedCount"],
            pending=counts["pendingCount"],
            processing=counts["processingCount"],
            retry_count=counts["retryCount"],
            duplicate_claim=str(db_summary["duplicateClaimDetected"]).lower(),
            db_prom_processed_match=str(int(counts["doneCount"]) == int(round(float(drain_prom["processedRowsTotal"])))).lower(),
        )
    )

for item in db_summary["claimedByCounts"]:
    with replica_rows.open("a", encoding="utf-8") as output:
        output.write(f"| {case_name} | {item['claimedBy']} | {item['rowCount']} |\n")

with idle_rows.open("a", encoding="utf-8") as output:
    output.write(
        "| {case_name} | {scheduler_runs} | {empty_runs} | {non_empty_runs} | {empty_ratio} | "
        "{batch_attempts} | {empty_batch_attempts} | {non_empty_batch_attempts} | {processed_rows} |\n".format(
            case_name=case_name,
            scheduler_runs=rounded(idle_prom["schedulerRunCount"]),
            empty_runs=rounded(idle_prom["emptyRunCount"]),
            non_empty_runs=rounded(idle_prom["nonEmptyRunCount"]),
            empty_ratio=rounded(idle_prom["emptyRunRatio"], 4),
            batch_attempts=rounded(idle_prom["batchAttemptCount"]),
            empty_batch_attempts=rounded(idle_prom["emptyBatchAttemptCount"]),
            non_empty_batch_attempts=rounded(idle_prom["nonEmptyBatchAttemptCount"]),
            processed_rows=rounded(idle_prom["processedRowsTotal"]),
        )
    )

if counts["doneCount"] != event_count:
    raise SystemExit(f"Expected DONE {event_count}, got {counts['doneCount']}")
if counts["failedCount"] != 0 or counts["pendingCount"] != 0 or counts["processingCount"] != 0:
    raise SystemExit(
        "Expected FAILED/PENDING/PROCESSING 0, got "
        f"failed={counts['failedCount']} pending={counts['pendingCount']} processing={counts['processingCount']}"
    )
if int(counts["retryCount"]) != 0:
    raise SystemExit(f"Expected retryCount 0, got {counts['retryCount']}")
if db_summary["duplicateClaimDetected"]:
    raise SystemExit("Duplicate claim detected")
if int(counts["doneCount"]) != int(round(float(drain_prom["processedRowsTotal"]))):
    raise SystemExit(
        "DB DONE and Prometheus processedRowsTotal mismatch: "
        f"done={counts['doneCount']} processedRowsTotal={drain_prom['processedRowsTotal']}"
    )
PY
}

start_spring_replicas() {
	local batch_size="$1"
	local fixed_delay_ms="$2"
	local max_drain_rounds="$3"
	local run_prefix="$4"
	local -n output_containers="$5"
	local -n output_ports="$6"
	local started_containers=()
	local started_ports=()

  for replica_index in $(seq 1 "${REPLICA_COUNT}"); do
    local port=$((APP_PORT_BASE + replica_index))
    local replica_name="spring-app-${replica_index}"
    local container_name="${run_prefix}-${replica_name}"
    docker rm -f "${container_name}" >/dev/null 2>&1 || true
    docker run -d \
      --name "${container_name}" \
      --network "${DOCKER_NETWORK}" \
      --add-host host.docker.internal:host-gateway \
      -p "${port}:8080" \
      -v "${REPO_ROOT}/build/libs:/app/libs:ro" \
      -w /app \
      -e JAVA_TOOL_OPTIONS="${APP_JAVA_OPTS}" \
      -e SPRING_DATASOURCE_URL="jdbc:postgresql://host.docker.internal:15432/${POSTGRES_DATABASE}" \
      -e SPRING_DATASOURCE_USERNAME="${POSTGRES_USER}" \
      -e SPRING_DATASOURCE_PASSWORD="${POSTGRES_PASSWORD}" \
      -e SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE="2" \
      -e SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE="1" \
      -e SPRING_JPA_DATABASE_PLATFORM="org.hibernate.dialect.PostgreSQLDialect" \
      -e READPATH_PRODUCT_SEARCH_OPEN_SEARCH_BASE_URL="http://host.docker.internal:9200" \
      -e READPATH_PRODUCT_SEARCH_OPEN_SEARCH_WRITE_ALIAS="${WRITE_ALIAS}" \
      -e READPATH_PRODUCT_SEARCH_INDEXING_RELAY_ENABLED="true" \
      -e READPATH_PRODUCT_SEARCH_INDEXING_RELAY_BATCH_SIZE="${batch_size}" \
      -e READPATH_PRODUCT_SEARCH_INDEXING_RELAY_FIXED_DELAY_MS="${fixed_delay_ms}" \
      -e READPATH_PRODUCT_SEARCH_INDEXING_RELAY_MAX_DRAIN_ROUNDS="${max_drain_rounds}" \
      -e READPATH_PRODUCT_SEARCH_INDEXING_RELAY_INSTANCE_ID="${replica_name}" \
      -e MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE="health,prometheus" \
      eclipse-temurin:21-jre \
      java -jar /app/libs/marketplace-0.0.1-SNAPSHOT.jar >/dev/null
    started_containers+=("${container_name}")
    started_ports+=("${port}")
  done

	output_containers=("${started_containers[@]}")
	output_ports=("${started_ports[@]}")
}

run_case() {
  local order="$1"
  local case_slug="$2"
  local case_name="$3"
  local batch_size="$4"
  local fixed_delay_ms="$5"
  local max_drain_rounds="$6"
  local case_run_id="prometheus-distributed-backlog-${RUN_ID}-${case_slug}"
  local index_name="products_search_prom_dist_backlog_${case_slug}_$(date +%s)"
  local target_regex="${case_slug}-spring-app-[1-4]:8080"
  local containers=()
  local ports=()

  printf '%s\n' "RUN_CASE order=${order} case=${case_name}"
  initialize_opensearch_target "${index_name}"
  clear_postgres_smoke_rows

  start_spring_replicas "${batch_size}" "${fixed_delay_ms}" "${max_drain_rounds}" "${case_slug}" containers ports
  trap 'stop_spring_replicas "${containers[@]}"' RETURN

  wait_spring_replicas_healthy "${REPLICA_COUNT}" "${ports[@]}"
  sleep "${STABILIZATION_SECONDS}"
  wait_prometheus_targets_ready "${target_regex}"
  wait_prometheus_scheduler_metrics_ready "${target_regex}"

  local drain_start
  local drain_end
  local idle_start
  local idle_end
  local start_ms
  local end_ms
  local counts_json
  local lag_json
  local db_summary_json
  local drain_prom_json
  local idle_prom_json

  drain_start="$(now_seconds)"
  initialize_postgres_rows "${case_run_id}"
  start_ms="$(date +%s%3N)"
  counts_json="$(wait_case_done "${case_run_id}")"
  end_ms="$(date +%s%3N)"
  wait_prometheus_processed_rows "${target_regex}"
  sleep 3
  drain_end="$(now_seconds)"

  idle_start="$(now_seconds)"
  sleep "${IDLE_SECONDS}"
  idle_end="$(now_seconds)"

  lag_json="$(measure_lag "${case_run_id}")"
  db_summary_json="$(measure_db_summary "${case_run_id}")"
  drain_prom_json="$(collect_prometheus_summary "${drain_start}" "${drain_end}" "${target_regex}" "drain")"
  idle_prom_json="$(collect_prometheus_summary "${idle_start}" "${idle_end}" "${target_regex}" "idle")"

  append_case_rows "${order}" "${case_name}" "${batch_size}" "${fixed_delay_ms}" "${max_drain_rounds}" \
    "${drain_start}" "${drain_end}" "${idle_start}" "${idle_end}" "$((end_ms - start_ms))" \
    "${counts_json}" "${lag_json}" "${db_summary_json}" "${drain_prom_json}" "${idle_prom_json}"

  stop_spring_replicas "${containers[@]}"
  trap - RETURN
}

write_result() {
  cat > "${RESULT_PATH}" <<EOF
# Prometheus-based distributed backlog strategy comparison

conditions: local PostgreSQL + local OpenSearch, Prometheus server, scrape_interval=1s, evaluation_interval=1s, eventCount=${EVENT_COUNT}, replicaCount=${REPLICA_COUNT}, app health UP before insert, Prometheus targets UP and scraped at least twice before insert, idleSeconds=${IDLE_SECONDS}, each case once.

Prometheus metrics:

- product_search_outbox_relay_scheduler_runs_total{instance_id,result}
- product_search_outbox_relay_batch_attempts_total{instance_id,result}
- product_search_outbox_relay_processed_rows_total{instance_id}
- product_search_outbox_relay_scheduler_run_duration_seconds{instance_id}
- product_search_outbox_relay_claim_rows{instance_id}

## Case execution order

| order | case | drainStartEpoch | drainEndEpoch | idleStartEpoch | idleEndEpoch |
|---:|---|---:|---:|---:|---:|
EOF
  cat "${ORDER_ROWS}" >> "${RESULT_PATH}"
  cat >> "${RESULT_PATH}" <<'EOF'

## Case results

| order | case | batchSize | fixedDelayMs | maxDrainRounds | totalProcessingTimeMs | eventsPerSecond | schedulerRunCount | emptyRunCount | nonEmptyRunCount | batchAttemptCount | processedRowsTotal | schedulerRunDuration p95 | claimRows p50 | claimRows p95 | claimRows max | queueWaitMs p50 | queueWaitMs p95 | queueWaitMs p99 | queueWaitMs max | totalIndexingLagMs p50 | totalIndexingLagMs p95 | totalIndexingLagMs p99 | totalIndexingLagMs max | batchClaimCount | avgRowsPerClaim | maxRowsPerClaim | DONE | FAILED | PENDING | PROCESSING | retryCount | duplicateClaim | DB DONE = Prom processedRowsTotal |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
EOF
  cat "${MAIN_ROWS}" >> "${RESULT_PATH}"
  cat >> "${RESULT_PATH}" <<'EOF'

## Replica claim distribution

| case | claimed_by | rowCount |
|---|---|---:|
EOF
  cat "${REPLICA_ROWS}" >> "${RESULT_PATH}"
  cat >> "${RESULT_PATH}" <<'EOF'

## Idle polling

| case | schedulerRunCount | emptyRunCount | nonEmptyRunCount | emptyRunRatio | batchAttemptCount | emptyBatchAttemptCount | nonEmptyBatchAttemptCount | processedRowsTotal |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
EOF
  cat "${IDLE_ROWS}" >> "${RESULT_PATH}"
}

bash "${REPO_ROOT}/gradlew" --no-daemon bootJar
initialize_postgres_schema
start_prometheus
trap 'stop_prometheus; cleanup' EXIT

run_case 1 "baseline" "baseline" 100 5000 1
run_case 2 "shorter-polling" "shorter polling" 100 1000 1
run_case 3 "larger-batch" "larger batch" 500 5000 1
run_case 4 "multi-batch" "multi-batch per scheduler run" 100 5000 5

write_result
stop_prometheus
trap cleanup EXIT

echo "RESULT_PATH=${RESULT_PATH}"
