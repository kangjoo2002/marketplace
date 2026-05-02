\set ON_ERROR_STOP on

WITH scoped AS (
    SELECT *
    FROM search_outbox
    WHERE aggregate_type = 'PRODUCT'
      AND (
          aggregate_id BETWEEN -18002999 AND -18002000
          OR payload->>'smokeRun' IN (
              'outbox-relay-opensearch-sync',
              'outbox-relay-opensearch-sync-failure',
              'outbox-relay-opensearch-sync-cleanup'
          )
      )
),
relay_events AS (
    SELECT *
    FROM scoped
    WHERE payload->>'smokeRun' = 'outbox-relay-opensearch-sync'
),
failure_events AS (
    SELECT *
    FROM scoped
    WHERE payload->>'smokeRun' = 'outbox-relay-opensearch-sync-failure'
),
cleanup_events AS (
    SELECT *
    FROM scoped
    WHERE payload->>'smokeRun' = 'outbox-relay-opensearch-sync-cleanup'
),
pending_age AS (
    SELECT COALESCE(MAX(EXTRACT(EPOCH FROM now() - created_at)), 0)::NUMERIC(12,3) AS oldest_pending_age_seconds
    FROM scoped
    WHERE status = 'PENDING'
)
SELECT jsonb_build_object(
    'processedEventCount', COUNT(*) FILTER (
        WHERE relay_events.status = 'DONE'
    ),
    'relayPendingEventCount', COUNT(*) FILTER (
        WHERE relay_events.status = 'PENDING'
    ),
    'relayProcessingEventCount', COUNT(*) FILTER (
        WHERE relay_events.status = 'PROCESSING'
    ),
    'failureScenarioFailedEventCount', (
        SELECT COUNT(*) FROM failure_events WHERE status = 'FAILED'
    ),
    'failureScenarioRetryCount', (
        SELECT COALESCE(SUM(retry_count), 0) FROM failure_events WHERE status = 'FAILED'
    ),
    'failureScenarioLastErrorCount', (
        SELECT COUNT(*) FROM failure_events WHERE status = 'FAILED' AND COALESCE(last_error, '') <> ''
    ),
    'cleanupPendingEventCount', (
        SELECT COUNT(*) FROM cleanup_events WHERE status = 'PENDING'
    ),
    'cleanupFailedEventCount', (
        SELECT COUNT(*) FROM cleanup_events WHERE status = 'FAILED'
    ),
    'cleanupRecentDoneEventCount', (
        SELECT COUNT(*) FROM cleanup_events WHERE status = 'DONE'
    ),
    'oldestPendingAgeSeconds', (
        SELECT oldest_pending_age_seconds FROM pending_age
    )
)::TEXT
FROM relay_events;
