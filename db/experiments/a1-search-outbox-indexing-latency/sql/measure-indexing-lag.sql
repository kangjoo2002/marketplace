\set ON_ERROR_STOP on

\if :{?window_start}
\else
\set window_start ''
\endif

\if :{?window_end}
\else
\set window_end ''
\endif

\if :{?smoke_run}
\else
\set smoke_run ''
\endif

-- Optional psql variables:
--   -v window_start='2026-05-10T00:00:00Z'
--   -v window_end='2026-05-10T01:00:00Z'
--   -v smoke_run='local-smoke-run-id'
--
-- If smoke_run is provided, only rows where payload->>'smokeRun' equals that value are included.
-- If a window bound is omitted, that side is unbounded.

WITH params AS (
    SELECT
        NULLIF(:'window_start', '')::timestamptz AS window_start,
        NULLIF(:'window_end', '')::timestamptz AS window_end,
        NULLIF(:'smoke_run', '') AS smoke_run
),
scoped AS (
    SELECT so.*
    FROM search_outbox so
    CROSS JOIN params p
    WHERE (p.window_start IS NULL OR so.created_at >= p.window_start)
      AND (p.window_end IS NULL OR so.created_at < p.window_end)
      AND (p.smoke_run IS NULL OR so.payload->>'smokeRun' = p.smoke_run)
),
done_lag AS (
    SELECT
        EXTRACT(EPOCH FROM (processed_at - created_at)) * 1000.0 AS total_indexing_lag_ms
    FROM scoped
    WHERE status = 'DONE'
      AND processed_at IS NOT NULL
),
status_counts AS (
    SELECT
        COUNT(*) FILTER (WHERE status = 'PENDING') AS pending_count,
        COUNT(*) FILTER (WHERE status = 'PROCESSING') AS processing_count,
        COUNT(*) FILTER (WHERE status = 'FAILED') AS failed_count,
        COUNT(*) FILTER (WHERE status = 'DONE') AS done_count,
        COALESCE(
            MAX(EXTRACT(EPOCH FROM (now() - created_at)) * 1000.0) FILTER (WHERE status = 'PENDING'),
            0
        ) AS oldest_pending_age_ms
    FROM scoped
),
retry_distribution AS (
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'retryCount', retry_count,
                'eventCount', event_count
            )
            ORDER BY retry_count
        ),
        '[]'::jsonb
    ) AS distribution
    FROM (
        SELECT retry_count, COUNT(*) AS event_count
        FROM scoped
        GROUP BY retry_count
    ) retries
)
SELECT jsonb_build_object(
    'window', jsonb_build_object(
        'windowStart', (SELECT window_start FROM params),
        'windowEnd', (SELECT window_end FROM params),
        'smokeRun', (SELECT smoke_run FROM params)
    ),
    'statusCounts', jsonb_build_object(
        'pendingCount', status_counts.pending_count,
        'processingCount', status_counts.processing_count,
        'failedCount', status_counts.failed_count,
        'doneCount', status_counts.done_count,
        'oldestPendingAgeMs', status_counts.oldest_pending_age_ms
    ),
    'totalIndexingLagMs', jsonb_build_object(
        'doneCount', (SELECT COUNT(*) FROM done_lag),
        'p50', COALESCE((SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY total_indexing_lag_ms) FROM done_lag), 0),
        'p95', COALESCE((SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY total_indexing_lag_ms) FROM done_lag), 0),
        'p99', COALESCE((SELECT percentile_cont(0.99) WITHIN GROUP (ORDER BY total_indexing_lag_ms) FROM done_lag), 0),
        'max', COALESCE((SELECT MAX(total_indexing_lag_ms) FROM done_lag), 0)
    ),
    'retryCountDistribution', retry_distribution.distribution
)::TEXT
FROM status_counts
CROSS JOIN retry_distribution;
