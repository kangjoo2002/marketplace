\set ON_ERROR_STOP on

-- Aggregates final DB-side counts for the lag/fallback/rollback operations
-- smoke. The runner records pre-recovery backlog metrics separately before
-- relay processing.

WITH scoped AS (
    SELECT *
    FROM search_outbox
    WHERE payload->>'smokeRun' IN (
        'opensearch-lag-fallback-rollback-normal',
        'opensearch-lag-fallback-rollback-backlog'
    )
),
normal_events AS (
    SELECT *
    FROM scoped
    WHERE payload->>'smokeRun' = 'opensearch-lag-fallback-rollback-normal'
),
backlog_events AS (
    SELECT *
    FROM scoped
    WHERE payload->>'smokeRun' = 'opensearch-lag-fallback-rollback-backlog'
)
SELECT jsonb_build_object(
    'normalProcessedEventCount', (
        SELECT COUNT(*) FROM normal_events WHERE status = 'DONE'
    ),
    'normalFailedEventCount', (
        SELECT COUNT(*) FROM normal_events WHERE status = 'FAILED'
    ),
    'normalRetryCount', (
        SELECT COALESCE(SUM(retry_count), 0) FROM normal_events
    ),
    'normalP95EventLagSeconds', (
        SELECT COALESCE(
            percentile_cont(0.95) WITHIN GROUP (
                ORDER BY EXTRACT(EPOCH FROM (processed_at - created_at))
            ) FILTER (WHERE status = 'DONE'),
            0
        )
        FROM normal_events
    ),
    'normalMaxEventLagSeconds', (
        SELECT COALESCE(
            MAX(EXTRACT(EPOCH FROM (processed_at - created_at))) FILTER (WHERE status = 'DONE'),
            0
        )
        FROM normal_events
    ),
    'backlogProcessedEventCount', (
        SELECT COUNT(*) FROM backlog_events WHERE status = 'DONE'
    ),
    'backlogPendingEventCountAfterRecovery', (
        SELECT COUNT(*) FROM backlog_events WHERE status = 'PENDING'
    ),
    'backlogOldestPendingAgeSecondsAfterRecovery', (
        SELECT COALESCE(
            MAX(EXTRACT(EPOCH FROM (now() - created_at))) FILTER (WHERE status = 'PENDING'),
            0
        )
        FROM backlog_events
    ),
    'backlogFailedEventCountAfterRecovery', (
        SELECT COUNT(*) FROM backlog_events WHERE status = 'FAILED'
    ),
    'allNamespacedEventCount', (
        SELECT COUNT(*) FROM scoped
    )
)::TEXT;
