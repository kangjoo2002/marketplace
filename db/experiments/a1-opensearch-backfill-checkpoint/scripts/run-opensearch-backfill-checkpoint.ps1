param(
    [string] $OpenSearchUrl = $env:OPENSEARCH_URL,
    [string] $OpenSearchImage = "opensearchproject/opensearch:2.15.0",
    [int] $BatchSize = $(if ($env:BACKFILL_BATCH_SIZE) { [int] $env:BACKFILL_BATCH_SIZE } else { 2 })
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($OpenSearchUrl)) {
    $OpenSearchUrl = "http://localhost:9200"
}

$OpenSearchUrl = $OpenSearchUrl.TrimEnd("/")

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$experimentDir = Resolve-Path (Join-Path $scriptDir "..")
$repoRoot = Resolve-Path (Join-Path $experimentDir "..\..\..")
$mappingPath = Join-Path $repoRoot "db\experiments\a1-opensearch-index-mapping-alias\mappings\products_v1_nested.json"
$outboxSchemaPath = Join-Path $repoRoot "db\init\002_create_search_outbox.sql"
$productOptionsSchemaPath = Join-Path $repoRoot "db\seed\product-options\product_options_schema.sql"
$prepareSqlPath = Join-Path $experimentDir "sql\prepare-backfill-checkpoint.sql"
$validateSqlPath = Join-Path $experimentDir "sql\validate-backfill-results.sql"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$tempResultDir = Join-Path $experimentDir "results\$timestamp.partial"
$resultDir = Join-Path $experimentDir "results\$timestamp"

$indexName = "products_search_backfill_smoke_v1"
$readAlias = "products_search_backfill_smoke_read"
$writeAlias = "products_search_backfill_smoke_write"
$currentAlias = "products_search_backfill_smoke_current"
$sourceMinId = -19002999
$sourceMaxId = -19002000

function Invoke-PsqlText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Sql,
        [switch] $TuplesOnly
    )

    $arguments = @(
        "compose",
        "exec",
        "-T",
        "postgres",
        "psql",
        "-U",
        "readpath",
        "-d",
        "readpath_lab",
        "-v",
        "ON_ERROR_STOP=1",
        "-q"
    )

    if ($TuplesOnly) {
        $arguments += @("-t", "-A")
    }

    $output = $Sql | docker @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "psql failed with exit code $LASTEXITCODE"
    }

    return ($output -join "`n").Trim()
}

function Invoke-PsqlFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SqlPath,
        [switch] $TuplesOnly
    )

    $sql = Get-Content -Raw $SqlPath
    return Invoke-PsqlText -Sql $sql -TuplesOnly:$TuplesOnly
}

function Invoke-OpenSearch {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Method,
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [string] $BodyPath,
        [object] $Body,
        [string] $ContentType = "application/json"
    )

    $uri = "$OpenSearchUrl/$($Path.TrimStart('/'))"
    $params = @{
        Method = $Method
        Uri = $uri
    }

    if ($BodyPath) {
        $params["Body"] = Get-Content -Raw $BodyPath
        $params["ContentType"] = $ContentType
    }
    elseif ($null -ne $Body) {
        if ($Body -is [string]) {
            $params["Body"] = $Body
        }
        else {
            $params["Body"] = $Body | ConvertTo-Json -Depth 50 -Compress
        }
        $params["ContentType"] = $ContentType
    }

    Invoke-RestMethod @params
}

function Get-JsonLines {
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    return @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        $_ | ConvertFrom-Json
    })
}

function Get-SourceDocuments {
    param(
        [long] $AfterProductId,
        [int] $Limit
    )

    $sql = @"
WITH next_products AS (
    SELECT p.*
    FROM products p
    WHERE p.id BETWEEN $sourceMinId AND $sourceMaxId
      AND p.id > $AfterProductId
    ORDER BY p.id ASC
    LIMIT $Limit
),
documents AS (
    SELECT
        p.id AS product_id,
        jsonb_build_object(
            'productId', p.id,
            'sellerId', p.seller_id,
            'categoryId', p.category_id,
            'brandId', p.brand_id,
            'status', p.status,
            'price', p.price,
            'rating', p.rating,
            'reviewCount', p.review_count,
            'createdAt', to_char(p.created_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
            'updatedAt', to_char(p.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
            'sourceUpdatedAt', to_char(p.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
            'documentRefreshedAt', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS'),
            'options', COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'color', po.color,
                        'size', po.size,
                        'stockStatus', po.stock_status
                    )
                    ORDER BY po.id
                ) FILTER (WHERE po.product_id IS NOT NULL),
                '[]'::jsonb
            )
        ) AS document
    FROM next_products p
    LEFT JOIN product_options_moderate_skew po ON po.product_id = p.id
    GROUP BY
        p.id,
        p.seller_id,
        p.category_id,
        p.brand_id,
        p.status,
        p.price,
        p.rating,
        p.review_count,
        p.created_at,
        p.updated_at
)
SELECT jsonb_build_object(
    'productId', product_id,
    'document', document
)::TEXT
FROM documents
ORDER BY product_id ASC;
"@

    return Get-JsonLines -Text (Invoke-PsqlText -Sql $sql -TuplesOnly)
}

function Get-SourceDocumentById {
    param([long] $ProductId)

    $documents = @(Get-SourceDocuments -AfterProductId ($ProductId - 1) -Limit 1)
    if ($documents.Count -eq 0 -or [long] $documents[0].productId -ne $ProductId) {
        return $null
    }
    return $documents[0].document
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Value,
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $Value | ConvertTo-Json -Depth 60 | Set-Content -Encoding UTF8 $Path
}

function Write-Checkpoint {
    param(
        [long] $LastProcessedProductId,
        [string] $Status,
        [string] $CompletedAt = $null
    )

    $checkpoint = [pscustomobject]@{
        backfillRunId = $timestamp
        lastProcessedProductId = $LastProcessedProductId
        batchSize = $BatchSize
        status = $Status
        startedAt = $script:StartedAt
        updatedAt = (Get-Date).ToString("o")
        completedAt = $CompletedAt
    }

    Write-JsonFile -Value $checkpoint -Path (Join-Path $tempResultDir "checkpoint-result.json")
    return $checkpoint
}

function Invoke-BulkIndex {
    param([array] $Documents)

    if ($Documents.Count -eq 0) {
        return [pscustomobject]@{
            indexed = 0
            errors = $false
            response = $null
        }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Documents) {
        $productId = [long] $item.productId
        $lines.Add((@{ index = @{ _id = "$productId" } } | ConvertTo-Json -Depth 5 -Compress))
        $lines.Add(($item.document | ConvertTo-Json -Depth 50 -Compress))
    }
    $bulkBody = ($lines -join "`n") + "`n"
    $response = Invoke-OpenSearch -Method "POST" -Path "$writeAlias/_bulk?refresh=true" -Body $bulkBody -ContentType "application/x-ndjson"

    return [pscustomobject]@{
        indexed = $Documents.Count
        errors = [bool] $response.errors
        response = $response
    }
}

function Invoke-BackfillBatches {
    param(
        [long] $StartAfterProductId,
        [int] $MaxBatches = 0
    )

    $lastProcessedProductId = $StartAfterProductId
    $processedProductCount = 0
    $batchCount = 0
    $failedBatchCount = 0
    $retriedBatchCount = 0
    $bulkResponses = @()

    while ($true) {
        if ($MaxBatches -gt 0 -and $batchCount -ge $MaxBatches) {
            break
        }

        $batch = @(Get-SourceDocuments -AfterProductId $lastProcessedProductId -Limit $BatchSize)
        if ($batch.Count -eq 0) {
            break
        }

        $bulkResult = Invoke-BulkIndex -Documents $batch
        if ($bulkResult.errors) {
            $failedBatchCount++
            $retriedBatchCount++
            $bulkResult = Invoke-BulkIndex -Documents $batch
            if ($bulkResult.errors) {
                throw "OpenSearch bulk indexing failed after retry"
            }
        }

        $batchCount++
        $processedProductCount += $batch.Count
        $lastProcessedProductId = [long] $batch[-1].productId
        $bulkResponses += [pscustomobject]@{
            batchNumber = $batchCount
            lastProcessedProductId = $lastProcessedProductId
            indexed = $bulkResult.indexed
            errors = $bulkResult.errors
        }
        Write-Checkpoint -LastProcessedProductId $lastProcessedProductId -Status "RUNNING" | Out-Null
    }

    return [pscustomobject]@{
        lastProcessedProductId = $lastProcessedProductId
        processedProductCount = $processedProductCount
        batchCount = $batchCount
        failedBatchCount = $failedBatchCount
        retriedBatchCount = $retriedBatchCount
        bulkResponses = $bulkResponses
    }
}

function Get-OpenSearchProductIds {
    $response = Invoke-OpenSearch -Method "POST" -Path "$writeAlias/_search" -Body @{
        size = 1000
        _source = @("productId")
        sort = @(@{ productId = @{ order = "asc" } })
        query = @{ match_all = @{} }
    }

    return @($response.hits.hits | ForEach-Object { [long] $_._source.productId })
}

function Compare-SampleDocuments {
    param([long[]] $SampleIds)

    $results = @()
    foreach ($sampleId in $SampleIds) {
        $source = Get-SourceDocumentById -ProductId $sampleId
        $target = (Invoke-OpenSearch -Method "GET" -Path "$writeAlias/_doc/$sampleId")._source
        $mismatches = @()

        foreach ($field in @("productId", "sellerId", "categoryId", "brandId", "status", "price", "reviewCount", "createdAt", "updatedAt")) {
            if ($source.$field -ne $target.$field) {
                $mismatches += "$field source=$($source.$field) target=$($target.$field)"
            }
        }

        if ([decimal] $source.rating -ne [decimal] $target.rating) {
            $mismatches += "rating source=$($source.rating) target=$($target.rating)"
        }

        if ($source.options.Count -ne $target.options.Count) {
            $mismatches += "options.count source=$($source.options.Count) target=$($target.options.Count)"
        }
        else {
            for ($i = 0; $i -lt $source.options.Count; $i++) {
                foreach ($field in @("color", "size", "stockStatus")) {
                    if ($source.options[$i].$field -ne $target.options[$i].$field) {
                        $mismatches += "options[$i].$field source=$($source.options[$i].$field) target=$($target.options[$i].$field)"
                    }
                }
            }
        }

        $results += [pscustomobject]@{
            productId = $sampleId
            mismatchCount = $mismatches.Count
            mismatches = $mismatches
        }
    }

    return [pscustomobject]@{
        sampleDocumentComparisonCount = $results.Count
        sampleDocumentMismatchCount = ($results | Measure-Object -Property mismatchCount -Sum).Sum
        samples = $results
    }
}

Push-Location $repoRoot
$success = $false
try {
    $script:StartedAt = (Get-Date).ToString("o")

    Write-Host "Checking OpenSearch health at $OpenSearchUrl"
    $health = Invoke-OpenSearch -Method "GET" -Path "_cluster/health"

    Write-Host "Applying PostgreSQL backfill smoke schemas"
    Invoke-PsqlFile -SqlPath $outboxSchemaPath | Out-Null
    Invoke-PsqlFile -SqlPath $productOptionsSchemaPath | Out-Null

    New-Item -ItemType Directory -Force -Path $tempResultDir | Out-Null

    Write-Host "Preparing PostgreSQL source slice"
    $prepareResult = Invoke-PsqlFile -SqlPath $prepareSqlPath -TuplesOnly | ConvertFrom-Json
    $sourceValidation = Invoke-PsqlFile -SqlPath $validateSqlPath -TuplesOnly | ConvertFrom-Json

    $backfillStartOutboxIdText = Invoke-PsqlText -Sql "SELECT COALESCE(MAX(id), 0)::TEXT FROM search_outbox;" -TuplesOnly
    $backfillStartOutboxId = [long] $backfillStartOutboxIdText

    Write-Host "Resetting backfill smoke OpenSearch index"
    try {
        Invoke-OpenSearch -Method "DELETE" -Path $indexName | Out-Null
    }
    catch {
        $statusCode = $null
        if ($null -ne $_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
        }
        if ($statusCode -ne 404) {
            throw
        }
    }

    $indexCreate = Invoke-OpenSearch -Method "PUT" -Path $indexName -BodyPath $mappingPath
    $aliasCreate = Invoke-OpenSearch -Method "POST" -Path "_aliases" -Body @{
        actions = @(
            @{ add = @{ index = $indexName; alias = $readAlias } },
            @{ add = @{ index = $indexName; alias = $writeAlias } },
            @{ add = @{ index = $indexName; alias = $currentAlias } }
        )
    }

    Write-Host "Initializing checkpoint"
    Write-Checkpoint -LastProcessedProductId $sourceMinId -Status "RUNNING" | Out-Null

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host "Running controlled partial backfill"
    $partial = Invoke-BackfillBatches -StartAfterProductId $sourceMinId -MaxBatches 1
    $checkpointAfterInterruption = Get-Content -Raw (Join-Path $tempResultDir "checkpoint-result.json") | ConvertFrom-Json

    if ([long] $checkpointAfterInterruption.lastProcessedProductId -le $sourceMinId) {
        throw "Checkpoint did not advance after controlled interruption"
    }

    Write-Host "Resuming from checkpoint"
    $resume = Invoke-BackfillBatches -StartAfterProductId ([long] $checkpointAfterInterruption.lastProcessedProductId)
    $completedAt = (Get-Date).ToString("o")
    $finalCheckpoint = Write-Checkpoint -LastProcessedProductId ([long] $resume.lastProcessedProductId) -Status "COMPLETED" -CompletedAt $completedAt

    $stopwatch.Stop()

    $indexedIds = @(Get-OpenSearchProductIds)
    $sourceIds = @(Get-JsonLines -Text (Invoke-PsqlText -Sql "SELECT jsonb_build_object('productId', id)::TEXT FROM products WHERE id BETWEEN $sourceMinId AND $sourceMaxId ORDER BY id;" -TuplesOnly) | ForEach-Object { [long] $_.productId })

    $missingIds = @($sourceIds | Where-Object { $indexedIds -notcontains $_ })
    $extraIds = @($indexedIds | Where-Object { $sourceIds -notcontains $_ })

    $sourceProductCount = [int] $sourceValidation.sourceProductCount
    $indexedDocumentCount = $indexedIds.Count
    $missingDocumentCount = $missingIds.Count
    $extraDocumentCount = $extraIds.Count

    $sampleIds = @(
        [long] $sourceValidation.firstProductId,
        -19002004,
        -19002002,
        [long] $sourceValidation.lastProductId
    ) | Select-Object -Unique
    $sampleComparison = Compare-SampleDocuments -SampleIds $sampleIds

    $failedBatchCount = $partial.failedBatchCount + $resume.failedBatchCount
    $retriedBatchCount = $partial.retriedBatchCount + $resume.retriedBatchCount
    $processedProductCount = $partial.processedProductCount + $resume.processedProductCount
    $durationSeconds = [Math]::Max($stopwatch.Elapsed.TotalSeconds, 0.001)
    $throughputProductsPerSecond = [Math]::Round($processedProductCount / $durationSeconds, 3)

    $resumeResult = [pscustomobject]@{
        checkpointPositionAfterInterruption = [long] $checkpointAfterInterruption.lastProcessedProductId
        resumeStartAfterProductId = [long] $checkpointAfterInterruption.lastProcessedProductId
        resumeFinalCheckpointPosition = [long] $finalCheckpoint.lastProcessedProductId
        resumeSuccess = $true
        partialBatchCount = $partial.batchCount
        resumedBatchCount = $resume.batchCount
    }

    $countValidation = [pscustomobject]@{
        sourceFilter = "products.id BETWEEN $sourceMinId AND $sourceMaxId"
        sourceProductCount = $sourceProductCount
        indexedDocumentCount = $indexedDocumentCount
        countsMatch = ($sourceProductCount -eq $indexedDocumentCount)
    }

    $missingExtraValidation = [pscustomobject]@{
        missingDocumentCount = $missingDocumentCount
        missingProductIds = $missingIds
        extraDocumentCount = $extraDocumentCount
        extraProductIds = $extraIds
    }

    $batchStats = [pscustomobject]@{
        batchSize = $BatchSize
        processedProductCount = $processedProductCount
        partialBatchCount = $partial.batchCount
        resumedBatchCount = $resume.batchCount
        totalBatchCount = $partial.batchCount + $resume.batchCount
        failedBatchCount = $failedBatchCount
        retriedBatchCount = $retriedBatchCount
        backfillDurationMs = $stopwatch.ElapsedMilliseconds
        backfillThroughputProductsPerSecond = $throughputProductsPerSecond
    }

    if ($sourceProductCount -ne 4) { throw "Expected source product count 4, got $sourceProductCount" }
    if ($indexedDocumentCount -ne $sourceProductCount) { throw "Indexed document count mismatch" }
    if ($missingDocumentCount -ne 0) { throw "Expected missing document count 0, got $missingDocumentCount" }
    if ($extraDocumentCount -ne 0) { throw "Expected extra document count 0, got $extraDocumentCount" }
    if ($sampleComparison.sampleDocumentMismatchCount -ne 0) { throw "Expected sample mismatch count 0, got $($sampleComparison.sampleDocumentMismatchCount)" }
    if ($failedBatchCount -ne 0) { throw "Expected failed batch count 0, got $failedBatchCount" }
    if ($retriedBatchCount -ne 0) { throw "Expected retried batch count 0, got $retriedBatchCount" }
    if (-not $resumeResult.resumeSuccess) { throw "Resume validation did not pass" }

    $highWatermark = [pscustomobject]@{
        backfillStartOutboxId = $backfillStartOutboxId
        catchUpReplayPredicate = "search_outbox.id > $backfillStartOutboxId"
    }

    $summary = @"
# OpenSearch Backfill Checkpoint Smoke Summary

- PostgreSQL target: docker compose postgres/readpath_lab
- OpenSearch URL: $OpenSearchUrl
- OpenSearch image: $OpenSearchImage
- Smoke index: $indexName
- Write alias: $writeAlias
- Source filter: products.id BETWEEN $sourceMinId AND $sourceMaxId
- Final smoke status: pass

| metric | value |
|---|---:|
| backfill start outbox id | $backfillStartOutboxId |
| source product count | $sourceProductCount |
| indexed document count | $indexedDocumentCount |
| missing document count | $missingDocumentCount |
| extra document count | $extraDocumentCount |
| sample document comparison count | $($sampleComparison.sampleDocumentComparisonCount) |
| sample document mismatch count | $($sampleComparison.sampleDocumentMismatchCount) |
| backfill duration ms | $($stopwatch.ElapsedMilliseconds) |
| backfill throughput products/sec | $throughputProductsPerSecond |
| failed batch count | $failedBatchCount |
| retried batch count | $retriedBatchCount |
| checkpoint position after interruption | $($resumeResult.checkpointPositionAfterInterruption) |
| final checkpoint position | $($finalCheckpoint.lastProcessedProductId) |
| resume success | $($resumeResult.resumeSuccess) |

This smoke result is not a benchmark or production migration readiness claim.
"@

    Write-JsonFile -Value $highWatermark -Path (Join-Path $tempResultDir "high-watermark-result.json")
    Write-JsonFile -Value $resumeResult -Path (Join-Path $tempResultDir "resume-result.json")
    Write-JsonFile -Value $countValidation -Path (Join-Path $tempResultDir "count-validation-result.json")
    Write-JsonFile -Value $missingExtraValidation -Path (Join-Path $tempResultDir "missing-extra-validation-result.json")
    Write-JsonFile -Value $sampleComparison -Path (Join-Path $tempResultDir "sample-document-comparison-result.json")
    Write-JsonFile -Value $batchStats -Path (Join-Path $tempResultDir "batch-stats-result.json")
    $summary | Set-Content -Encoding UTF8 (Join-Path $tempResultDir "backfill-summary.md")

    Move-Item -LiteralPath $tempResultDir -Destination $resultDir -Force
    $success = $true

    Write-Host "PASS: OpenSearch backfill checkpoint smoke validation completed"
    Write-Host "Result artifacts: $resultDir"
} finally {
    Pop-Location
    if (-not $success -and (Test-Path $tempResultDir)) {
        Remove-Item -LiteralPath $tempResultDir -Recurse -Force
    }
}
