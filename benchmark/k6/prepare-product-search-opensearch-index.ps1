param(
    [string] $OpenSearchUrl = $(if ($env:OPENSEARCH_URL) { $env:OPENSEARCH_URL } else { "http://localhost:9200" }),

    [string] $IndexName = "products_search_benchmark_moderate_skew_v1",

    [string] $ReadAlias = "products_search_read",

    [string] $WriteAlias = "products_search_write",

    [string] $CurrentAlias = "products_search_current",

    [int] $BatchSize = 5000,

    [long] $StartAfterProductId = 0,

    [long] $MaxProducts = 0,

    [string] $ResultsRoot = "$PSScriptRoot/results/products_moderate_skew",

    [int] $MaxResultWindow = 10050,

    [switch] $CreateHelperIndexes,

    [switch] $ExplainOnly,

    [switch] $PromoteExisting,

    [switch] $DryRun,

    [switch] $KeepBatchFiles
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$OpenSearchUrl = $OpenSearchUrl.TrimEnd("/")
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$MappingPath = Join-Path $RepoRoot "db\experiments\a1-opensearch-index-mapping-alias\mappings\products_v1_nested.json"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RunMode = if ($MaxProducts -gt 0) { "partial-smoke" } else { "official-full" }
$EffectiveIndexName = if ($MaxProducts -gt 0) { "${IndexName}_partial_${Timestamp}" } else { $IndexName }
$ResultDir = Join-Path $ResultsRoot "opensearch_index_prepare_$Timestamp"
$ProgressDir = Join-Path $ResultDir "progress"
$TempDir = Join-Path $ResultDir "tmp"
$HelperIndexName = "idx_product_options_moderate_skew_product_id_benchmark_export"

function Write-JsonFile {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Path)
    ConvertTo-Json -InputObject $Value -Depth 100 | Set-Content -Encoding UTF8 -LiteralPath $Path
}

function Normalize-JsonArray {
    param([object] $Value)

    if ($null -eq $Value) {
        return @()
    }

    $items = @($Value)
    if ($items.Count -eq 1) {
        $single = $items[0]
        $propertyNames = @($single.PSObject.Properties.Name)
        if ($propertyNames -contains "value" -and $propertyNames -contains "Count") {
            return @($single.value)
        }
    }

    return $items
}

function Invoke-PsqlText {
    param([Parameter(Mandatory = $true)][string] $Sql)

    $output = $Sql | docker compose exec -T postgres psql -U readpath -d readpath_lab -v ON_ERROR_STOP=1 -q -t -A
    if ($LASTEXITCODE -ne 0) {
        throw "psql failed with exit code $LASTEXITCODE"
    }
    return ($output -join "`n").Trim()
}

function Invoke-PsqlJson {
    param([Parameter(Mandatory = $true)][string] $Sql)
    $text = Invoke-PsqlText -Sql $Sql
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "psql returned empty JSON result"
    }
    return $text | ConvertFrom-Json
}

function Get-SourceIndexInspection {
    Invoke-PsqlJson -Sql @"
SELECT json_agg(row_to_json(indexes) ORDER BY tablename, indexname)::TEXT
FROM (
    SELECT tablename, indexname, indexdef
    FROM pg_indexes
    WHERE tablename IN ('products_moderate_skew', 'product_options_moderate_skew')
    ORDER BY tablename, indexname
) indexes;
"@
}

function Test-ProductOptionsProductIdIndex {
    param([Parameter(Mandatory = $true)][object[]] $Indexes)

    foreach ($index in $Indexes) {
        if ($index.tablename -eq "product_options_moderate_skew" -and $index.indexdef -match "\(\s*product_id\s*(,|\))") {
            return $true
        }
    }
    return $false
}

function New-HelperIndex {
    $startedAt = Get-Date
    $sql = @"
CREATE INDEX IF NOT EXISTS $HelperIndexName
ON product_options_moderate_skew (product_id);
ANALYZE product_options_moderate_skew;
SELECT json_build_object(
    'indexName', '$HelperIndexName',
    'tableName', 'product_options_moderate_skew',
    'columns', json_build_array('product_id'),
    'purpose', 'local benchmark corpus export only',
    'applicationReadPathOptimizationClaim', false,
    'createdOrAlreadyExisted', true
)::TEXT;
"@
    $result = Invoke-PsqlJson -Sql $sql
    $result | Add-Member -NotePropertyName elapsedSeconds -NotePropertyValue ([Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 3)) -Force
    return $result
}

function Get-BatchExplainPlanText {
    param([long] $StartAfter, [int] $Limit)

    $sql = @"
EXPLAIN (FORMAT TEXT, COSTS, VERBOSE)
WITH batch AS (
    SELECT p.id,
           p.seller_id,
           p.category_id,
           p.brand_id,
           p.status,
           p.price,
           p.rating,
           p.review_count,
           p.created_at,
           p.updated_at
    FROM products_moderate_skew p
    WHERE p.id > $StartAfter
    ORDER BY p.id
    LIMIT $Limit
),
batch_options AS (
    SELECT po.product_id,
           json_agg(
               json_build_object(
                   'color', po.color,
                   'size', po.size,
                   'stockStatus', po.stock_status
               )
               ORDER BY po.id
           ) AS options
    FROM product_options_moderate_skew po
    JOIN batch b ON b.id = po.product_id
    GROUP BY po.product_id
),
lines AS (
    SELECT b.id,
           0 AS line_order,
           json_build_object('index', json_build_object('_id', b.id))::TEXT AS line
    FROM batch b
    UNION ALL
    SELECT b.id,
           1 AS line_order,
           json_build_object(
               'productId', b.id,
               'sellerId', b.seller_id,
               'categoryId', b.category_id,
               'brandId', b.brand_id,
               'status', b.status,
               'price', b.price,
               'rating', b.rating,
               'reviewCount', b.review_count,
               'createdAt', to_char(b.created_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
               'updatedAt', to_char(b.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
               'sourceUpdatedAt', to_char(b.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
               'documentRefreshedAt', to_char(clock_timestamp(), 'YYYY-MM-DD"T"HH24:MI:SS'),
               'options', COALESCE(bo.options, '[]'::json)
           )::TEXT AS line
    FROM batch b
    LEFT JOIN batch_options bo ON bo.product_id = b.id
)
SELECT line
FROM lines
ORDER BY id, line_order;
"@

    $output = $sql | docker compose exec -T postgres psql -U readpath -d readpath_lab -v ON_ERROR_STOP=1 -q -t -A
    if ($LASTEXITCODE -ne 0) {
        throw "EXPLAIN query failed with exit code $LASTEXITCODE"
    }
    return ($output -join "`n")
}

function Invoke-OpenSearch {
    param(
        [Parameter(Mandatory = $true)][string] $Method,
        [Parameter(Mandatory = $true)][string] $Path,
        [object] $Body,
        [string] $BodyPath
    )

    $params = @{
        Method = $Method
        Uri = "$OpenSearchUrl/$($Path.TrimStart('/'))"
    }
    if ($BodyPath) {
        $params["Body"] = Get-Content -Raw -LiteralPath $BodyPath
        $params["ContentType"] = "application/json"
    }
    elseif ($null -ne $Body) {
        $params["Body"] = $Body | ConvertTo-Json -Depth 100 -Compress
        $params["ContentType"] = "application/json"
    }
    Invoke-RestMethod @params
}

function Test-OpenSearchIndexExists {
    param([Parameter(Mandatory = $true)][string] $Name)
    try {
        Invoke-OpenSearch -Method "HEAD" -Path $Name | Out-Null
        return $true
    }
    catch {
        $statusCode = $null
        if ($null -ne $_.Exception.Response) {
            $statusCode = [int] $_.Exception.Response.StatusCode
        }
        if ($statusCode -eq 404) {
            return $false
        }
        throw
    }
}

function Remove-OpenSearchIndexIfExists {
    param([Parameter(Mandatory = $true)][string] $Name)
    if (Test-OpenSearchIndexExists -Name $Name) {
        Invoke-OpenSearch -Method "DELETE" -Path $Name | Out-Null
    }
}

function Get-SourceCounts {
    Invoke-PsqlJson -Sql @"
WITH status_counts AS (
    SELECT json_object_agg(status, count ORDER BY status) AS counts
    FROM (
        SELECT status, COUNT(*)::BIGINT AS count
        FROM products_moderate_skew
        GROUP BY status
    ) s
),
scenario_counts AS (
    SELECT json_object_agg(scenario, matching_count ORDER BY scenario) AS counts
    FROM (
        SELECT 'B1_selective_option_filter' AS scenario, COUNT(DISTINCT p.id)::BIGINT AS matching_count
        FROM products_moderate_skew p
        WHERE p.category_id = 75
          AND p.brand_id = 943
          AND p.status = 'ACTIVE'
          AND p.price >= 10000
          AND p.price <= 100000
          AND EXISTS (
              SELECT 1
              FROM product_options_moderate_skew po
              WHERE po.product_id = p.id
                AND po.color = 'BLACK'
                AND po.size = 'M'
                AND po.stock_status = 'IN_STOCK'
          )
        UNION ALL
        SELECT 'B2_broad_active_option_filter' AS scenario, COUNT(DISTINCT p.id)::BIGINT AS matching_count
        FROM products_moderate_skew p
        WHERE p.status = 'ACTIVE'
          AND EXISTS (
              SELECT 1
              FROM product_options_moderate_skew po
              WHERE po.product_id = p.id
                AND po.color = 'BLACK'
                AND po.size = 'M'
                AND po.stock_status = 'IN_STOCK'
          )
        UNION ALL
        SELECT 'B3_deep_offset_option_filter' AS scenario, COUNT(DISTINCT p.id)::BIGINT AS matching_count
        FROM products_moderate_skew p
        WHERE p.category_id = 75
          AND p.brand_id = 943
          AND p.status = 'ACTIVE'
          AND p.price >= 10000
          AND p.price <= 100000
          AND EXISTS (
              SELECT 1
              FROM product_options_moderate_skew po
              WHERE po.product_id = p.id
                AND po.color = 'BLACK'
                AND po.size = 'M'
                AND po.stock_status = 'IN_STOCK'
          )
    ) s
)
SELECT json_build_object(
    'productsModerateSkewCount', (SELECT COUNT(*)::BIGINT FROM products_moderate_skew),
    'productOptionsModerateSkewCount', (SELECT COUNT(*)::BIGINT FROM product_options_moderate_skew),
    'statusCounts', (SELECT counts FROM status_counts),
    'scenarioCounts', (SELECT counts FROM scenario_counts),
    'activeBlackMInStockProducts', (
        SELECT COUNT(DISTINCT p.id)::BIGINT
        FROM products_moderate_skew p
        WHERE p.status = 'ACTIVE'
          AND EXISTS (
              SELECT 1
              FROM product_options_moderate_skew po
              WHERE po.product_id = p.id
                AND po.color = 'BLACK'
                AND po.size = 'M'
                AND po.stock_status = 'IN_STOCK'
          )
    )
)::TEXT;
"@
}

function Get-BatchWindow {
    param([long] $StartAfter, [int] $Limit)
    $text = Invoke-PsqlText -Sql "SELECT COUNT(*)::TEXT || ',' || COALESCE(MAX(id), 0)::TEXT FROM (SELECT id FROM products_moderate_skew WHERE id > $StartAfter ORDER BY id LIMIT $Limit) s;"
    $parts = $text.Split(",")
    return [pscustomobject]@{
        Count = [int] $parts[0]
        LastProductId = [long] $parts[1]
    }
}

function Write-BatchNdjson {
    param(
        [long] $StartAfter,
        [int] $Limit,
        [string] $Path
    )

    $sql = @"
WITH batch AS (
    SELECT p.id,
           p.seller_id,
           p.category_id,
           p.brand_id,
           p.status,
           p.price,
           p.rating,
           p.review_count,
           p.created_at,
           p.updated_at
    FROM products_moderate_skew p
    WHERE p.id > $StartAfter
    ORDER BY p.id
    LIMIT $Limit
),
batch_options AS (
    SELECT po.product_id,
           json_agg(
               json_build_object(
                   'color', po.color,
                   'size', po.size,
                   'stockStatus', po.stock_status
               )
               ORDER BY po.id
           ) AS options
    FROM product_options_moderate_skew po
    JOIN batch b ON b.id = po.product_id
    GROUP BY po.product_id
),
lines AS (
    SELECT b.id,
           0 AS line_order,
           json_build_object('index', json_build_object('_id', b.id))::TEXT AS line
    FROM batch b
    UNION ALL
    SELECT b.id,
           1 AS line_order,
           json_build_object(
               'productId', b.id,
               'sellerId', b.seller_id,
               'categoryId', b.category_id,
               'brandId', b.brand_id,
               'status', b.status,
               'price', b.price,
               'rating', b.rating,
               'reviewCount', b.review_count,
               'createdAt', to_char(b.created_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
               'updatedAt', to_char(b.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
               'sourceUpdatedAt', to_char(b.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
               'documentRefreshedAt', to_char(clock_timestamp(), 'YYYY-MM-DD"T"HH24:MI:SS'),
               'options', COALESCE(bo.options, '[]'::json)
           )::TEXT AS line
    FROM batch b
    LEFT JOIN batch_options bo ON bo.product_id = b.id
)
SELECT line
FROM lines
ORDER BY id, line_order;
"@

    $output = $sql | docker compose exec -T postgres psql -U readpath -d readpath_lab -v ON_ERROR_STOP=1 -q -t -A
    if ($LASTEXITCODE -ne 0) {
        throw "batch NDJSON query failed with exit code $LASTEXITCODE"
    }
    $output | Set-Content -Encoding UTF8 -LiteralPath $Path
    Add-Content -Encoding UTF8 -LiteralPath $Path -Value ""
}

function Invoke-BulkIndex {
    param([Parameter(Mandatory = $true)][string] $BatchPath, [Parameter(Mandatory = $true)][string] $ResponsePath)

    $bulkUri = "$OpenSearchUrl/$EffectiveIndexName/_bulk?filter_path=errors,took,items.*.error"
    curl.exe -sS -X POST $bulkUri -H "Content-Type: application/x-ndjson" --data-binary "@$BatchPath" -o $ResponsePath
    if ($LASTEXITCODE -ne 0) {
        throw "curl bulk request failed with exit code $LASTEXITCODE"
    }
    $response = Get-Content -Raw -LiteralPath $ResponsePath | ConvertFrom-Json
    if ($response.errors -eq $true) {
        throw "OpenSearch bulk response contained errors. See $ResponsePath"
    }
    return $response
}

function Update-OfficialAliases {
    $actions = @()
    foreach ($alias in @($ReadAlias, $WriteAlias, $CurrentAlias)) {
        $existing = curl.exe -sS "$OpenSearchUrl/_cat/aliases/$($alias)?format=json" | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to inspect existing OpenSearch alias: $alias"
        }
        foreach ($entry in @($existing)) {
            if ($entry.index) {
                $actions += @{ remove = @{ index = $entry.index; alias = $alias } }
            }
        }
    }
    $actions += @{ add = @{ index = $EffectiveIndexName; alias = $ReadAlias } }
    $actions += @{ add = @{ index = $EffectiveIndexName; alias = $WriteAlias } }
    $actions += @{ add = @{ index = $EffectiveIndexName; alias = $CurrentAlias } }

    Invoke-OpenSearch -Method "POST" -Path "_aliases" -Body @{ actions = $actions } | Out-Null
}

function Update-BenchmarkIndexSettings {
    Invoke-OpenSearch -Method "PUT" -Path "$EffectiveIndexName/_settings" -Body @{
        index = @{
            max_result_window = $MaxResultWindow
        }
    } | Out-Null
}

function Get-MaxResultWindow {
    $settings = Invoke-OpenSearch -Method "GET" -Path "$EffectiveIndexName/_settings?filter_path=*.settings.index.max_result_window"
    $value = $settings.$EffectiveIndexName.settings.index.max_result_window
    if ($null -eq $value) {
        return 10000
    }
    return [int] $value
}

function Get-IndexValidation {
    param([Parameter(Mandatory = $true)][object] $SourceCounts)

    $mapping = Invoke-OpenSearch -Method "GET" -Path "$EffectiveIndexName/_mapping"
    $optionsType = $mapping.$EffectiveIndexName.mappings.properties.options.type
    $actualMaxResultWindow = Get-MaxResultWindow
    $countResult = Invoke-OpenSearch -Method "GET" -Path "$EffectiveIndexName/_count"
    $statusAgg = Invoke-OpenSearch -Method "POST" -Path "$EffectiveIndexName/_search" -Body @{
        size = 0
        aggs = @{
            by_status = @{
                terms = @{
                    field = "status"
                    size = 10
                }
            }
        }
    }
    $statusCounts = [ordered]@{}
    foreach ($bucket in $statusAgg.aggregations.by_status.buckets) {
        $statusCounts[$bucket.key] = [long] $bucket.doc_count
    }

    $preflight = @(
        Get-ScenarioCount -Name "B1_selective_option_filter" -RequiredCount 150 -Body (New-ScenarioQuery -Scenario "B1")
        Get-ScenarioCount -Name "B2_broad_active_option_filter" -RequiredCount 150 -Body (New-ScenarioQuery -Scenario "B2")
        Get-ScenarioCount -Name "B3_deep_offset_option_filter" -RequiredCount 10050 -Body (New-ScenarioQuery -Scenario "B3")
    )

    return [pscustomobject]@{
        mapping = [pscustomobject]@{
            index = $EffectiveIndexName
            optionsType = $optionsType
            passes = ($optionsType -eq "nested")
        }
        indexSettings = [pscustomobject]@{
            index = $EffectiveIndexName
            maxResultWindow = $actualMaxResultWindow
            requiredMinMaxResultWindow = $MaxResultWindow
            passes = ($actualMaxResultWindow -ge $MaxResultWindow)
        }
        indexCount = [pscustomobject]@{
            index = $EffectiveIndexName
            expected = [long] $SourceCounts.productsModerateSkewCount
            actual = [long] $countResult.count
            officialCorpus = ($MaxProducts -eq 0)
            passes = ($MaxProducts -eq 0 -and [long] $countResult.count -eq [long] $SourceCounts.productsModerateSkewCount)
        }
        statusCounts = [pscustomobject]@{
            expected = $SourceCounts.statusCounts
            actual = $statusCounts
            passes = (
                [long] $statusCounts.ACTIVE -eq [long] $SourceCounts.statusCounts.ACTIVE -and
                [long] $statusCounts.DELETED -eq [long] $SourceCounts.statusCounts.DELETED -and
                [long] $statusCounts.SOLD_OUT -eq [long] $SourceCounts.statusCounts.SOLD_OUT
            )
        }
        preflight = $preflight
    }
}

function New-ScenarioQuery {
    param([Parameter(Mandatory = $true)][string] $Scenario)

    $filters = @()
    if ($Scenario -eq "B1" -or $Scenario -eq "B3") {
        $filters += @{ term = @{ categoryId = 75 } }
        $filters += @{ term = @{ brandId = 943 } }
        $filters += @{ range = @{ price = @{ gte = 10000; lte = 100000 } } }
    }
    $filters += @{ term = @{ status = "ACTIVE" } }
    $filters += @{
        nested = @{
            path = "options"
            query = @{
                bool = @{
                    filter = @(
                        @{ term = @{ "options.color" = "BLACK" } },
                        @{ term = @{ "options.size" = "M" } },
                        @{ term = @{ "options.stockStatus" = "IN_STOCK" } }
                    )
                }
            }
        }
    }
    return @{ query = @{ bool = @{ filter = $filters } } }
}

function Get-ScenarioCount {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][long] $RequiredCount,
        [Parameter(Mandatory = $true)][object] $Body
    )

    $countResult = Invoke-OpenSearch -Method "POST" -Path "$EffectiveIndexName/_count" -Body $Body
    return [pscustomobject]@{
        scenario = $Name
        matchingCount = [long] $countResult.count
        requiredMinCount = $RequiredCount
        passes = ([long] $countResult.count -ge $RequiredCount)
    }
}

function Write-Summary {
    param([Parameter(Mandatory = $true)][object] $SourceCounts, [object] $Validation, [string] $Status, [string] $Message)

    $summary = @"
# OpenSearch Product Search Benchmark Index Prepare Summary

- status: $Status
- message: $Message
- run mode: $RunMode
- OpenSearch URL: $OpenSearchUrl
- physical index: $EffectiveIndexName
- official aliases: $ReadAlias, $WriteAlias, $CurrentAlias
- selected mapping: $MappingPath
- batch size: $BatchSize
- start after product id: $StartAfterProductId
- max products: $MaxProducts
- dry run: $DryRun
- explain only: $ExplainOnly
- promote existing: $PromoteExisting
- helper index flag: $CreateHelperIndexes
- helper index name: $HelperIndexName
- index max_result_window: $MaxResultWindow
- source product count: $($SourceCounts.productsModerateSkewCount)
- source option count: $($SourceCounts.productOptionsModerateSkewCount)

This is local benchmark corpus preparation only. It is not a production
migration, production readiness claim, capacity claim, SLA, or SLO.
"@
    if ($null -ne $Validation) {
        $summary += @"

Validation:

- options mapping type: $($Validation.mapping.optionsType)
- index max_result_window: $($Validation.indexSettings.maxResultWindow)
- indexed root document count: $($Validation.indexCount.actual)
- official root document count expected: $($Validation.indexCount.expected)
- official corpus ready: $($Validation.indexCount.passes)
- status count validation: $($Validation.statusCounts.passes)
"@
        foreach ($scenario in @($Validation.preflight)) {
            $summary += "`n- $($scenario.scenario) matching count: $($scenario.matchingCount) / required $($scenario.requiredMinCount) / passes $($scenario.passes)"
        }
        $summary += "`n"
    }
    if ($RunMode -eq "partial-smoke") {
        $summary += @"

Partial smoke/preflight runs are not official benchmark corpora. Official k6
measured runs must remain blocked until the full 10,000,000 root product
documents are indexed and validated.

B1/B2/B3 preflight failures in a partial smoke index are recorded but do not
make the smoke export itself official or eligible for k6 measurement.
"@
    }
    Set-Content -Encoding ASCII -LiteralPath (Join-Path $ResultDir "opensearch-index-prepare-summary.md") -Value $summary
}

New-Item -ItemType Directory -Force -Path $ResultDir, $ProgressDir, $TempDir | Out-Null

$success = $false
$sourceCounts = $null
$prepareStartedAt = Get-Date
try {
    if ($BatchSize -lt 1) {
        throw "BatchSize must be positive."
    }
    if (-not (Test-Path $MappingPath)) {
        throw "Selected nested mapping file was not found: $MappingPath"
    }

    Write-Host "Checking PostgreSQL source counts..."
    $sourceCounts = Get-SourceCounts
    Write-JsonFile -Value $sourceCounts -Path (Join-Path $ResultDir "source-counts.json")

    Write-Host "Inspecting source indexes..."
    $sourceIndexes = @(Normalize-JsonArray -Value (Get-SourceIndexInspection))
    Write-JsonFile -Value $sourceIndexes -Path (Join-Path $ResultDir "source-index-inspection.json")
    $hasProductIdIndex = Test-ProductOptionsProductIdIndex -Indexes $sourceIndexes
    if (-not $hasProductIdIndex) {
        if ($CreateHelperIndexes) {
            Write-Host "Creating local benchmark export helper index on product_options_moderate_skew(product_id)..."
            $helperIndexResult = New-HelperIndex
            Write-JsonFile -Value $helperIndexResult -Path (Join-Path $ResultDir "helper-index-result.json")
            $sourceIndexes = @(Normalize-JsonArray -Value (Get-SourceIndexInspection))
            Write-JsonFile -Value $sourceIndexes -Path (Join-Path $ResultDir "source-index-inspection-after-helper.json")
            $hasProductIdIndex = Test-ProductOptionsProductIdIndex -Indexes $sourceIndexes
        }
        else {
            Write-JsonFile -Value ([pscustomobject]@{
                indexName = $HelperIndexName
                tableName = "product_options_moderate_skew"
                required = $true
                present = $false
                created = $false
                message = "Run with -CreateHelperIndexes to create the local benchmark export helper index."
            }) -Path (Join-Path $ResultDir "helper-index-result.json")
        }
    }
    else {
        Write-JsonFile -Value ([pscustomobject]@{
            indexName = $HelperIndexName
            tableName = "product_options_moderate_skew"
            required = $true
            present = $true
            created = $false
            message = "A product_id-leading index is present."
        }) -Path (Join-Path $ResultDir "helper-index-result.json")
    }

    $explainPlan = Get-BatchExplainPlanText -StartAfter $StartAfterProductId -Limit ([Math]::Min($BatchSize, 1000))
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $ResultDir "explain-plan-result.txt") -Value $explainPlan

    Write-Host "Checking OpenSearch health..."
    $health = Invoke-OpenSearch -Method "GET" -Path "_cluster/health?wait_for_status=yellow&timeout=30s"
    Write-JsonFile -Value $health -Path (Join-Path $ResultDir "opensearch-health.json")

    if ($DryRun -or $ExplainOnly) {
        $mode = if ($ExplainOnly) { "explain-only" } else { "dry-run" }
        Write-Summary -SourceCounts $sourceCounts -Status $mode -Message "$mode completed; index was not modified."
        $success = $true
        Write-Host "$($mode.ToUpperInvariant()): source counts, index inspection, EXPLAIN, and OpenSearch health checks completed."
        return
    }

    if ($PromoteExisting) {
        if ($MaxProducts -gt 0) {
            throw "PromoteExisting cannot be used with MaxProducts; partial corpora must not use official aliases."
        }

        Write-Host "Validating existing OpenSearch benchmark index $EffectiveIndexName"
        Update-BenchmarkIndexSettings
        $validation = Get-IndexValidation -SourceCounts $sourceCounts
        Write-JsonFile -Value $validation.mapping -Path (Join-Path $ResultDir "mapping-validation-result.json")
        Write-JsonFile -Value $validation.indexSettings -Path (Join-Path $ResultDir "index-settings-validation-result.json")
        Write-JsonFile -Value $validation.indexCount -Path (Join-Path $ResultDir "index-count-validation-result.json")
        Write-JsonFile -Value $validation.statusCounts -Path (Join-Path $ResultDir "status-count-validation-result.json")
        Write-JsonFile -Value $validation.preflight -Path (Join-Path $ResultDir "b1-b2-b3-preflight-result.json")

        $preflightFailures = @($validation.preflight | Where-Object { -not $_.passes })
        if (-not $validation.mapping.passes) {
            throw "Mapping validation failed: options.type=$($validation.mapping.optionsType)"
        }
        if (-not $validation.indexSettings.passes) {
            throw "Index setting validation failed: max_result_window=$($validation.indexSettings.maxResultWindow), required=$($validation.indexSettings.requiredMinMaxResultWindow)"
        }
        if (-not $validation.indexCount.passes) {
            throw "Index count validation failed: expected=$($validation.indexCount.expected), actual=$($validation.indexCount.actual)"
        }
        if (-not $validation.statusCounts.passes) {
            throw "Status count validation failed."
        }
        if ($preflightFailures.Count -gt 0) {
            throw "B1/B2/B3 preflight validation failed."
        }

        Write-Host "Updating official aliases"
        Update-OfficialAliases
        $aliasValidation = Invoke-OpenSearch -Method "GET" -Path "_cat/aliases/${ReadAlias},${WriteAlias},${CurrentAlias}?format=json"
        Write-JsonFile -Value $aliasValidation -Path (Join-Path $ResultDir "alias-validation-result.json")

        $duration = (Get-Date) - $prepareStartedAt
        Write-Summary -SourceCounts $sourceCounts -Validation $validation -Status "pass" -Message "Existing OpenSearch benchmark index validated and promoted in $($duration.ToString())."
        $success = $true
        Write-Host "PASS: existing OpenSearch benchmark index validated and promoted."
        Write-Host "Result artifacts: $ResultDir"
        return
    }

    if (-not $hasProductIdIndex) {
        throw "Missing product_options_moderate_skew(product_id) helper index for bounded batch option lookup. Full indexing remains blocked."
    }

    if ($MaxProducts -gt 0) {
        Write-Host "Partial smoke mode: official aliases will not be updated."
    }

    Write-Host "Recreating OpenSearch benchmark index $EffectiveIndexName"
    Remove-OpenSearchIndexIfExists -Name $EffectiveIndexName
    Invoke-OpenSearch -Method "PUT" -Path $EffectiveIndexName -BodyPath $MappingPath | Out-Null
    Update-BenchmarkIndexSettings

    $lastProductId = $StartAfterProductId
    $indexedProducts = 0L
    $startedAt = Get-Date
    while ($true) {
        $remainingLimit = $BatchSize
        if ($MaxProducts -gt 0) {
            $remaining = $MaxProducts - $indexedProducts
            if ($remaining -le 0) {
                break
            }
            $remainingLimit = [int] [Math]::Min($BatchSize, $remaining)
        }

        $window = Get-BatchWindow -StartAfter $lastProductId -Limit $remainingLimit
        if ($window.Count -eq 0) {
            break
        }

        $batchPath = Join-Path $TempDir "bulk_after_${lastProductId}.ndjson"
        $responsePath = Join-Path $TempDir "bulk_after_${lastProductId}_response.json"
        Write-Host "Indexing batch: startAfter=$lastProductId count=$($window.Count) lastProductId=$($window.LastProductId)"
        Write-BatchNdjson -StartAfter $lastProductId -Limit $window.Count -Path $batchPath
        $bulkResponse = Invoke-BulkIndex -BatchPath $batchPath -ResponsePath $responsePath

        $indexedProducts += [long] $window.Count
        $lastProductId = [long] $window.LastProductId
        $checkpoint = [pscustomobject]@{
            timestamp = (Get-Date).ToString("o")
            runMode = $RunMode
            index = $EffectiveIndexName
            indexedProducts = $indexedProducts
            lastProductId = $lastProductId
            batchSize = $BatchSize
            lastBulkTookMs = $bulkResponse.took
        }
        Write-JsonFile -Value $checkpoint -Path (Join-Path $ProgressDir "checkpoint.json")
        if (-not $KeepBatchFiles) {
            Remove-Item -LiteralPath $batchPath -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $responsePath -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Refreshing $EffectiveIndexName"
    Invoke-OpenSearch -Method "POST" -Path "$EffectiveIndexName/_refresh" | Out-Null

    if ($MaxProducts -eq 0) {
        Write-Host "Updating official aliases"
        Update-OfficialAliases
    }

    $aliasValidation = if ($MaxProducts -eq 0) {
        Invoke-OpenSearch -Method "GET" -Path "_cat/aliases/${ReadAlias},${WriteAlias},${CurrentAlias}?format=json"
    }
    else {
        [pscustomobject]@{ skipped = $true; reason = "Partial smoke mode does not update official aliases." }
    }
    Write-JsonFile -Value $aliasValidation -Path (Join-Path $ResultDir "alias-validation-result.json")

    $validation = Get-IndexValidation -SourceCounts $sourceCounts
    Write-JsonFile -Value $validation.mapping -Path (Join-Path $ResultDir "mapping-validation-result.json")
    Write-JsonFile -Value $validation.indexSettings -Path (Join-Path $ResultDir "index-settings-validation-result.json")
    Write-JsonFile -Value $validation.indexCount -Path (Join-Path $ResultDir "index-count-validation-result.json")
    Write-JsonFile -Value $validation.statusCounts -Path (Join-Path $ResultDir "status-count-validation-result.json")
    Write-JsonFile -Value $validation.preflight -Path (Join-Path $ResultDir "b1-b2-b3-preflight-result.json")

    $preflightFailures = @($validation.preflight | Where-Object { -not $_.passes })
    if (-not $validation.mapping.passes) {
        throw "Mapping validation failed: options.type=$($validation.mapping.optionsType)"
    }
    if ($MaxProducts -eq 0 -and -not $validation.indexSettings.passes) {
        throw "Index setting validation failed: max_result_window=$($validation.indexSettings.maxResultWindow), required=$($validation.indexSettings.requiredMinMaxResultWindow)"
    }
    if ($MaxProducts -eq 0 -and -not $validation.indexCount.passes) {
        throw "Index count validation failed: expected=$($validation.indexCount.expected), actual=$($validation.indexCount.actual)"
    }
    if ($MaxProducts -eq 0 -and -not $validation.statusCounts.passes) {
        throw "Status count validation failed."
    }
    if ($MaxProducts -eq 0 -and $preflightFailures.Count -gt 0) {
        throw "B1/B2/B3 preflight validation failed."
    }

    $duration = (Get-Date) - $startedAt
    $status = if ($MaxProducts -gt 0) { "partial-smoke-pass" } else { "pass" }
    $message = if ($MaxProducts -gt 0) {
        "Partial OpenSearch benchmark export completed in $($duration.ToString()). This is not an official corpus and official k6 remains blocked."
    }
    else {
        "OpenSearch benchmark index preparation completed in $($duration.ToString())."
    }
    Write-Summary -SourceCounts $sourceCounts -Validation $validation -Status $status -Message $message
    $success = $true
    Write-Host "PASS: OpenSearch benchmark index preparation completed."
    Write-Host "Result artifacts: $ResultDir"
}
catch {
    $message = $_.Exception.Message
    if ($null -ne $sourceCounts) {
        Write-Summary -SourceCounts $sourceCounts -Status "blocked-or-partial" -Message $message
    }
    else {
        Set-Content -Encoding ASCII -LiteralPath (Join-Path $ResultDir "opensearch-index-prepare-summary.md") -Value "blocked-or-partial: $message"
    }
    Set-Content -Encoding ASCII -LiteralPath (Join-Path $ResultDir "FAILED_PARTIAL.txt") -Value $message
    Write-Host "Partial/blocked artifacts: $ResultDir"
    throw
}
finally {
    if (-not $success) {
        Write-Host "OpenSearch benchmark index preparation did not complete successfully."
    }
}
