#!/usr/bin/env bash
set -euo pipefail

RUN_ID="${RUN_ID:-spring-replica-scaling-smoke-local-$(date +%Y%m%d-%H%M)}"
EVENT_COUNT="${EVENT_COUNT:-1000}"
BATCH_SIZE="${BATCH_SIZE:-100}"
REPLICA_COUNTS="${REPLICA_COUNTS:-1 2 4}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-180}"
STABILIZATION_SECONDS="${STABILIZATION_SECONDS:-3}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-readpath-baseline-postgres}"
POSTGRES_USER="${POSTGRES_USER:-marketplace}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-marketplace}"
POSTGRES_DATABASE="${POSTGRES_DATABASE:-marketplace}"
OPENSEARCH_URL="${OPENSEARCH_URL:-http://localhost:9200}"
APP_PORT_BASE="${APP_PORT_BASE:-18080}"
APP_JAVA_OPTS="${APP_JAVA_OPTS:--Xms64m -Xmx160m}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${EXPERIMENT_DIR}/../../.." && pwd)"
MAPPING_PATH="${REPO_ROOT}/db/experiments/a1-opensearch-index-mapping-alias/mappings/products_v1_nested.json"
MEASURE_SQL_PATH="${EXPERIMENT_DIR}/sql/measure-indexing-lag.sql"
RESULT_DIR="${EXPERIMENT_DIR}/results/${RUN_ID}"
WRITE_ALIAS="products_search_spring_replica_smoke_write"
PRODUCT_START_ID="-36000000"
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

CREATE INDEX IF NOT EXISTS idx_product_options_color_size_stock_product
ON product_options(color, size, stock_status, product_id);

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
DELETE FROM search_outbox WHERE payload->>'smokeRun' LIKE 'spring-replica-%';
DELETE FROM product_options WHERE product_id BETWEEN -36010000 AND -36000001;
DELETE FROM products WHERE id BETWEEN -36010000 AND -36000001;
SQL
}

initialize_postgres_rows() {
  local case_run_id="$1"
  psql_text false <<SQL >/dev/null
INSERT INTO products (id, seller_id, category_id, brand_id, status, price, rating, review_count, created_at, updated_at)
SELECT
    ${PRODUCT_START_ID} - seq,
    3500 + seq,
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
  local deadline=$((SECONDS + 180))
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
    if [[ "${#ports[@]}" -eq "${replica_count}" ]]; then
      local healthy=0
      for port in "${ports[@]}"; do
        health_body="$(curl -fsS "http://localhost:${port}/actuator/health" 2>/dev/null || true)"
        if [[ -n "${health_body}" ]] && printf '%s' "${health_body}" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("status") == "UP" else 1)' >/dev/null 2>&1; then
          healthy=$((healthy + 1))
        fi
      done
      if [[ "${healthy}" -eq "${replica_count}" ]]; then
        printf '%s\n' "${ports[@]}"
        return 0
      fi
    fi
    sleep 1
  done
  echo "Spring app replicas did not become healthy within ${HEALTH_TIMEOUT_SECONDS} seconds" >&2
  return 1
}

stop_spring_replicas() {
  local pids=("$@")
  for pid in "${pids[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
    fi
  done
  for pid in "${pids[@]}"; do
    wait "${pid}" 2>/dev/null || true
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

summarize_case() {
  local replica_count="$1"
  local case_run_id="$2"
  local total_processing_time_ms="$3"
  local counts_json="$4"
  local lag_json="$5"
  local health_ports_json="$6"
  local summary_path="${RESULT_DIR}/replica-${replica_count}-summary.json"

  local db_summary_json
  db_summary_json="$(psql_text true <<SQL
WITH scoped AS (
    SELECT *
    FROM search_outbox
    WHERE payload->>'smokeRun' = '${case_run_id}'
),
replicas AS (
    SELECT 'spring-app-' || generate_series(1, ${replica_count}) AS claimed_by
),
replica_stats AS (
    SELECT
        r.claimed_by,
        COUNT(s.id) AS claim_count,
        COUNT(DISTINCT s.claimed_at) FILTER (WHERE s.claimed_at IS NOT NULL) AS batch_claim_count,
        MIN(s.claimed_at) AS first_claim_at,
        MAX(s.processed_at) FILTER (WHERE s.status = 'DONE') AS last_done_at
    FROM replicas r
    LEFT JOIN scoped s ON s.claimed_by = r.claimed_by
    GROUP BY r.claimed_by
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
    'claimedRowCount', COUNT(*) FILTER (WHERE claimed_by IS NOT NULL),
    'batchClaimCount', (SELECT COUNT(*) FROM batch_claims),
    'firstClaimAt', MIN(claimed_at),
    'lastDoneAt', MAX(processed_at) FILTER (WHERE status = 'DONE'),
    'replicaClaimStats', (
        SELECT jsonb_agg(jsonb_build_object(
            'replica', claimed_by,
            'claimCount', claim_count,
            'claimedRowCount', claim_count,
            'batchClaimCount', batch_claim_count,
            'firstClaimAt', first_claim_at,
            'lastDoneAt', last_done_at
        ) ORDER BY claimed_by)
        FROM replica_stats
    ),
    'duplicateClaimDetected', EXISTS (SELECT 1 FROM duplicate_aggregates),
    'duplicateClaimEventIds', COALESCE((SELECT jsonb_agg(aggregate_id ORDER BY aggregate_id) FROM duplicate_aggregates), '[]'::jsonb)
)::text
FROM scoped;
SQL
)"

  python3 - "${replica_count}" "${case_run_id}" "${EVENT_COUNT}" "${BATCH_SIZE}" \
    "${total_processing_time_ms}" "${counts_json}" "${lag_json}" "${db_summary_json}" \
    "${health_ports_json}" "${STABILIZATION_SECONDS}" "${summary_path}" "${WRITE_ALIAS}" <<'PY'
import json
import sys
from pathlib import Path

replica_count = int(sys.argv[1])
case_run_id = sys.argv[2]
event_count = int(sys.argv[3])
batch_size = int(sys.argv[4])
total_processing_time_ms = int(sys.argv[5])
counts = json.loads(sys.argv[6])
lag = json.loads(sys.argv[7])
db_summary = json.loads(sys.argv[8])
health_ports = json.loads(sys.argv[9])
stabilization_seconds = int(sys.argv[10])
summary_path = Path(sys.argv[11])
write_alias = sys.argv[12]

summary = {
    "runId": case_run_id,
    "environment": "local synthetic / local PostgreSQL + OpenSearch smoke",
    "eventCount": event_count,
    "batchSize": batch_size,
    "replicaCount": replica_count,
    "doneEvents": int(counts["doneCount"]),
    "failedEvents": int(counts["failedCount"]),
    "pendingCount": int(counts["pendingCount"]),
    "processingCount": int(counts["processingCount"]),
    "retryCount": int(counts["retryCount"]),
    "totalProcessingTimeMs": total_processing_time_ms,
    "totalIndexingLagMs": lag["totalIndexingLagMs"],
    "breakdown": {"queueWaitMs": db_summary["queueWaitMs"]},
    "claimedRowCount": int(db_summary["claimedRowCount"]),
    "batchClaimCount": int(db_summary["batchClaimCount"]),
    "firstClaimAt": db_summary["firstClaimAt"],
    "lastDoneAt": db_summary["lastDoneAt"],
    "replicaClaimStats": db_summary["replicaClaimStats"],
    "duplicateClaimDetected": bool(db_summary["duplicateClaimDetected"]),
    "duplicateClaimEventIds": db_summary["duplicateClaimEventIds"],
    "retryOrFailedDetected": int(counts["retryCount"]) > 0 or int(counts["failedCount"]) > 0,
    "healthPorts": health_ports,
    "stabilizationSeconds": stabilization_seconds,
    "writeAlias": write_alias,
}
summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
print(json.dumps(summary))
PY
}

run_case() {
  local replica_count="$1"
  local case_run_id="${RUN_ID}-replica-${replica_count}"
  local index_name="products_search_spring_replica_smoke_$(printf '%s' "${case_run_id}" | tr -cd '0-9')"

  initialize_opensearch_target "${index_name}"
  initialize_postgres_schema
  clear_postgres_smoke_rows

  local pids=()
  trap 'stop_spring_replicas "${pids[@]}"' RETURN
  local health_ports=()
  for replica_index in $(seq 1 "${replica_count}"); do
    local port=$((APP_PORT_BASE + replica_count * 10 + replica_index))
    local replica_name="spring-app-${replica_index}"
    local app_log_path="/tmp/${RUN_ID}-replica-${replica_count}-${replica_name}.log"
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
      export READPATH_PRODUCT_SEARCH_INDEXING_RELAY_INSTANCE_ID="${replica_name}"
      export MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE="health"
      exec java -jar "${APP_JAR}" --server.port="${port}"
    ) > "${app_log_path}" 2>&1 &
    pids+=("$!")
    health_ports+=("${port}")
    wait_spring_replicas_healthy 1 "${port}" >/dev/null
  done

  local health_ports_json
  local counts_json
  local lag_json
  local summary_json
  local start_ms
  local end_ms

  wait_spring_replicas_healthy "${replica_count}" "${health_ports[@]}" >/dev/null
  sleep "${STABILIZATION_SECONDS}"

  initialize_postgres_rows "${case_run_id}"
  start_ms="$(date +%s%3N)"
  counts_json="$(wait_case_done "${case_run_id}")"
  end_ms="$(date +%s%3N)"
  stop_spring_replicas "${pids[@]}"
  trap - RETURN

  lag_json="$(measure_lag "${case_run_id}")"
  health_ports_json="$(python3 -c 'import json,sys; print(json.dumps([int(x) for x in sys.argv[1:]]))' "${health_ports[@]}")"
  summary_json="$(summarize_case "${replica_count}" "${case_run_id}" "$((end_ms - start_ms))" "${counts_json}" "${lag_json}" "${health_ports_json}")"

  python3 - "${summary_json}" "${EVENT_COUNT}" <<'PY'
import json
import sys
summary = json.loads(sys.argv[1])
event_count = int(sys.argv[2])
errors = []
if summary["doneEvents"] != event_count:
    errors.append(f"Expected DONE {event_count}, got {summary['doneEvents']}")
if summary["failedEvents"] != 0 or summary["pendingCount"] != 0 or summary["processingCount"] != 0:
    errors.append(
        "Expected FAILED/PENDING/PROCESSING 0, got "
        f"failed={summary['failedEvents']} pending={summary['pendingCount']} processing={summary['processingCount']}"
    )
if summary["claimedRowCount"] != event_count:
    errors.append(f"Expected timing line count {event_count}, got {summary['claimedRowCount']}")
if summary["duplicateClaimDetected"]:
    errors.append("Duplicate claim detected")
if summary["retryOrFailedDetected"]:
    errors.append("Retry or failed relay detected")
if errors:
    raise SystemExit("\n".join(errors))
PY

  echo "REPLICA_COUNT=${replica_count}"
  echo "RUN_ID=${case_run_id}"
  python3 - "${summary_json}" <<'PY'
import json
import sys
s = json.loads(sys.argv[1])
print(f"TOTAL_PROCESSING_TIME_MS={s['totalProcessingTimeMs']}")
print(f"TOTAL_P95_MS={s['totalIndexingLagMs']['p95']} QUEUE_P95_MS={s['breakdown']['queueWaitMs']['p95']} BATCH_CLAIMS={s['batchClaimCount']}")
PY
}

bash "${REPO_ROOT}/gradlew" --no-daemon bootJar

for replica_count in ${REPLICA_COUNTS}; do
  run_case "${replica_count}"
done

python3 - "${RESULT_DIR}" "${RUN_ID}" "${EVENT_COUNT}" "${BATCH_SIZE}" "${STABILIZATION_SECONDS}" <<'PY'
import json
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
run_id = sys.argv[2]
event_count = int(sys.argv[3])
batch_size = int(sys.argv[4])
stabilization_seconds = int(sys.argv[5])

cases = []
for path in sorted(result_dir.glob("replica-*-summary.json"), key=lambda item: int(item.stem.split("-")[1])):
    summary = json.loads(path.read_text(encoding="utf-8"))
    cases.append({
        "replicaCount": summary["replicaCount"],
        "batchSize": summary["batchSize"],
        "runId": summary["runId"],
        "eventCount": summary["eventCount"],
        "doneEvents": summary["doneEvents"],
        "failedEvents": summary["failedEvents"],
        "pendingCount": summary["pendingCount"],
        "processingCount": summary["processingCount"],
        "retryCount": summary["retryCount"],
        "totalProcessingTimeMs": summary["totalProcessingTimeMs"],
        "totalIndexingLagMs": summary["totalIndexingLagMs"],
        "queueWaitMs": summary["breakdown"]["queueWaitMs"],
        "claimedRowCount": summary["claimedRowCount"],
        "batchClaimCount": summary["batchClaimCount"],
        "firstClaimAt": summary["firstClaimAt"],
        "lastDoneAt": summary["lastDoneAt"],
        "replicaClaimStats": summary["replicaClaimStats"],
        "duplicateClaimDetected": summary["duplicateClaimDetected"],
        "retryOrFailedDetected": summary["retryOrFailedDetected"],
        "healthPorts": summary["healthPorts"],
        "stabilizationSeconds": summary["stabilizationSeconds"],
    })

comparison = {
    "runId": run_id,
    "analysisScope": "primary local synthetic steady-state Spring replica scaling smoke",
    "environment": "local synthetic / local PostgreSQL + OpenSearch smoke",
    "eventCount": event_count,
    "batchSize": batch_size,
    "healthCheck": "all Spring app replicas returned actuator health UP before smoke rows were inserted",
    "stabilizationSeconds": stabilization_seconds,
    "cases": cases,
    "resultFiles": {
        "comparisonSummary": "comparison-summary.json",
        "replica1Summary": "replica-1-summary.json",
        "replica2Summary": "replica-2-summary.json",
        "replica4Summary": "replica-4-summary.json",
        "relayLogSample": "relay-log-sample.txt",
    },
}
result_dir.joinpath("comparison-summary.json").write_text(json.dumps(comparison, indent=2) + "\n", encoding="utf-8")

with result_dir.joinpath("relay-log-sample.txt").open("w", encoding="utf-8") as output:
    for case in cases:
        replica_count = case["replicaCount"]
        output.write(f"# replicaCount={replica_count}\n")
        output.write(json.dumps({
            "runId": case["runId"],
            "replicaClaimStats": case["replicaClaimStats"],
            "batchClaimCount": case["batchClaimCount"],
            "firstClaimAt": case["firstClaimAt"],
            "lastDoneAt": case["lastDoneAt"],
        }, indent=2))
        output.write("\n\n")
PY

rm -f /tmp/"${RUN_ID}"-replica-*-spring-app-*.log

echo "RUN_ID=${RUN_ID}"
echo "RESULT_DIR=${RESULT_DIR}"
