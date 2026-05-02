\set ON_ERROR_STOP on

SELECT jsonb_build_object(
    'pendingAfterReplay', (
        SELECT COUNT(*)
        FROM search_outbox
        WHERE payload->>'smokeRun' = 'opensearch-catchup-dualrun'
          AND status = 'PENDING'
    ),
    'failedAfterReplay', (
        SELECT COUNT(*)
        FROM search_outbox
        WHERE payload->>'smokeRun' = 'opensearch-catchup-dualrun'
          AND status = 'FAILED'
    ),
    'doneAfterReplay', (
        SELECT COUNT(*)
        FROM search_outbox
        WHERE payload->>'smokeRun' = 'opensearch-catchup-dualrun'
          AND status = 'DONE'
    ),
    'processingAfterReplay', (
        SELECT COUNT(*)
        FROM search_outbox
        WHERE payload->>'smokeRun' = 'opensearch-catchup-dualrun'
          AND status = 'PROCESSING'
    )
)::TEXT;
