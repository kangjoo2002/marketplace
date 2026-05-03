param(
    [ValidateSet("moderate_skew")]
    [string] $Profile = "moderate_skew",

    [string] $OpenSearchUrl = $(if ($env:OPENSEARCH_URL) { $env:OPENSEARCH_URL } else { "http://localhost:9200" }),

    [string] $OpenSearchAlias = "products_search_read",

    [string] $ExpectedOpenSearchIndexName = "products_search_benchmark_moderate_skew_v1",

    [int] $ExpectedMaxResultWindow = 10050,

    [int] $AppPort = 18082,

    [int] $VUs = 10,

    [string] $WarmupDuration = "1m",

    [string] $Duration = "10m",

    [string] $ResultsRoot = "$PSScriptRoot/results",

    [int] $ExpectedDockerMemoryMiB = 4096,

    [int] $TimeoutMs = 500,

    [int] $FailureThreshold = 3,

    [int] $OpenWaitMs = 1000,

    [int] $HalfOpenPermittedCalls = 1,

    [int] $AppReadyTimeoutSeconds = 300,

    [switch] $SkipAppStart
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$OpenSearchUrl = $OpenSearchUrl.TrimEnd("/")
$BaseUrl = "http://localhost:$AppPort"
$ScriptPath = Join-Path $PSScriptRoot "product-search-opensearch.js"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ProfileResultDir = Join-Path $ResultsRoot "products_$Profile"
$SummaryPath = Join-Path $ProfileResultDir "product_search_opensearch_products_${Profile}_${Timestamp}_summary.json"
$ObservationsPath = Join-Path $ProfileResultDir "product_search_opensearch_products_${Profile}_${Timestamp}_observations.md"
$BlockedObservationsPath = Join-Path $ProfileResultDir "product_search_opensearch_products_${Profile}_${Timestamp}_blocked_observations.md"

$RequestScenarios = @(
    [pscustomobject]@{
        Name = "B1_selective_option_filter"
        Weight = 40
        RequiredMinCount = 150
        Query = [ordered]@{
            categoryId = 75
            brandId = 943
            status = "ACTIVE"
            minPrice = 10000
            maxPrice = 100000
            color = "BLACK"
            size = "M"
            stockStatus = "IN_STOCK"
            sort = "reviewCountDesc"
            limit = 50
            offset = 100
        }
    },
    [pscustomobject]@{
        Name = "B2_broad_active_option_filter"
        Weight = 40
        RequiredMinCount = 150
        Query = [ordered]@{
            status = "ACTIVE"
            color = "BLACK"
            size = "M"
            stockStatus = "IN_STOCK"
            sort = "createdAtDesc"
            limit = 50
            offset = 100
        }
    },
    [pscustomobject]@{
        Name = "B3_deep_offset_option_filter"
        Weight = 20
        RequiredMinCount = 10050
        Query = [ordered]@{
            categoryId = 75
            brandId = 943
            status = "ACTIVE"
            minPrice = 10000
            maxPrice = 100000
            color = "BLACK"
            size = "M"
            stockStatus = "IN_STOCK"
            sort = "reviewCountDesc"
            limit = 50
            offset = 10000
        }
    }
)

function Read-DockerDesktopSettings {
    $settingsPath = Join-Path $env:APPDATA "Docker/settings.json"
    if (-not (Test-Path $settingsPath)) {
        throw "Docker Desktop settings file was not found: $settingsPath"
    }

    Get-Content $settingsPath -Raw | ConvertFrom-Json
}

function Assert-K6Installed {
    $k6Command = Get-Command k6 -ErrorAction SilentlyContinue
    if (-not $k6Command -and (Test-Path "C:\Program Files\k6\k6.exe")) {
        $env:PATH = "C:\Program Files\k6;$env:PATH"
        $k6Command = Get-Command k6 -ErrorAction SilentlyContinue
    }

    if (-not $k6Command) {
        throw "k6 is not installed or is not on PATH. Install k6 manually before running this benchmark."
    }

    Write-Host "k6 version:"
    k6 version
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to execute k6 version."
    }
}

function Assert-DockerMemorySetting {
    $settings = Read-DockerDesktopSettings
    if ($settings.memoryMiB -ne $ExpectedDockerMemoryMiB) {
        throw "Docker Desktop memoryMiB is $($settings.memoryMiB), expected $ExpectedDockerMemoryMiB. Do not run official measurements until Docker Desktop memory is set to $ExpectedDockerMemoryMiB MiB."
    }

    Write-Host "Docker Desktop resource setting: cpus=$($settings.cpus), memoryMiB=$($settings.memoryMiB), swapMiB=$($settings.swapMiB), diskSizeMiB=$($settings.diskSizeMiB)"
}

function Assert-PostgresHealthy {
    $status = docker inspect --format "{{.State.Health.Status}}" readpath-postgres 2>$null
    if ($LASTEXITCODE -ne 0 -or $status -ne "healthy") {
        throw "PostgreSQL container readpath-postgres is not healthy. Current health: $status"
    }
    Write-Host "PostgreSQL container readpath-postgres is healthy."
}

function Invoke-OpenSearch {
    param(
        [Parameter(Mandatory = $true)][string] $Method,
        [Parameter(Mandatory = $true)][string] $Path,
        [object] $Body
    )

    $parameters = @{
        Method = $Method
        Uri = "$OpenSearchUrl/$($Path.TrimStart('/'))"
    }
    if ($null -ne $Body) {
        $parameters["Body"] = $Body | ConvertTo-Json -Depth 80 -Compress
        $parameters["ContentType"] = "application/json"
    }
    Invoke-RestMethod @parameters
}

function Assert-OpenSearchHealthy {
    $health = Invoke-OpenSearch -Method "GET" -Path "_cluster/health?wait_for_status=yellow&timeout=30s"
    if ($health.status -notin @("green", "yellow")) {
        throw "OpenSearch health is $($health.status), expected green or yellow."
    }
    Write-Host "OpenSearch health: $($health.status)"
    return $health
}

function Get-SourceCounts {
    $sql = @"
WITH status_counts AS (
    SELECT json_object_agg(status, count ORDER BY status) AS counts
    FROM (
        SELECT status, COUNT(*)::BIGINT AS count
        FROM products_moderate_skew
        GROUP BY status
    ) s
)
SELECT json_build_object(
    'productsModerateSkewCount', (SELECT COUNT(*)::BIGINT FROM products_moderate_skew),
    'productOptionsModerateSkewCount', (SELECT COUNT(*)::BIGINT FROM product_options_moderate_skew),
    'statusCounts', (SELECT counts FROM status_counts)
)::TEXT;
"@
    $output = $sql | docker compose exec -T postgres psql -U readpath -d readpath_lab -v ON_ERROR_STOP=1 -q -t -A
    if ($LASTEXITCODE -ne 0) {
        throw "source count query failed with exit code $LASTEXITCODE"
    }
    return (($output -join "`n").Trim() | ConvertFrom-Json)
}

function Build-OpenSearchQuery {
    param([object] $Scenario)

    $filters = @()
    if ($Scenario.Query.Contains("categoryId")) {
        $filters += @{ term = @{ categoryId = $Scenario.Query.categoryId } }
    }
    if ($Scenario.Query.Contains("brandId")) {
        $filters += @{ term = @{ brandId = $Scenario.Query.brandId } }
    }
    if ($Scenario.Query.Contains("status")) {
        $filters += @{ term = @{ status = $Scenario.Query.status } }
    }
    if ($Scenario.Query.Contains("minPrice") -or $Scenario.Query.Contains("maxPrice")) {
        $range = [ordered]@{}
        if ($Scenario.Query.Contains("minPrice")) {
            $range.gte = $Scenario.Query.minPrice
        }
        if ($Scenario.Query.Contains("maxPrice")) {
            $range.lte = $Scenario.Query.maxPrice
        }
        $filters += @{ range = @{ price = $range } }
    }

    $optionFilters = @()
    if ($Scenario.Query.Contains("color")) {
        $optionFilters += @{ term = @{ "options.color" = $Scenario.Query.color } }
    }
    if ($Scenario.Query.Contains("size")) {
        $optionFilters += @{ term = @{ "options.size" = $Scenario.Query.size } }
    }
    if ($Scenario.Query.Contains("stockStatus")) {
        $optionFilters += @{ term = @{ "options.stockStatus" = $Scenario.Query.stockStatus } }
    }
    if ($optionFilters.Count -gt 0) {
        $filters += @{
            nested = @{
                path = "options"
                query = @{ bool = @{ filter = $optionFilters } }
            }
        }
    }

    return @{ query = @{ bool = @{ filter = $filters } } }
}

function Test-OpenSearchBenchmarkReadiness {
    $sourceCounts = Get-SourceCounts
    $aliasInfo = Invoke-OpenSearch -Method "GET" -Path "_cat/aliases/${OpenSearchAlias}?format=json"
    if (-not $aliasInfo -or @($aliasInfo).Count -eq 0) {
        throw "OpenSearch alias $OpenSearchAlias was not found."
    }
    $aliasRows = @($aliasInfo)
    $readAliasRow = $aliasRows | Select-Object -First 1
    if ($readAliasRow.index -ne $ExpectedOpenSearchIndexName) {
        throw "OpenSearch alias $OpenSearchAlias points to $($readAliasRow.index), expected $ExpectedOpenSearchIndexName for the official benchmark corpus."
    }

    $mapping = Invoke-OpenSearch -Method "GET" -Path "$OpenSearchAlias/_mapping"
    $indexMapping = $mapping.$ExpectedOpenSearchIndexName
    if ($null -eq $indexMapping) {
        throw "OpenSearch mapping response did not include expected index $ExpectedOpenSearchIndexName."
    }
    $optionsType = $indexMapping.mappings.properties.options.type
    if ($optionsType -ne "nested") {
        throw "OpenSearch alias $OpenSearchAlias does not use selected nested mapping. options.type=$optionsType"
    }

    $settings = Invoke-OpenSearch -Method "GET" -Path "$ExpectedOpenSearchIndexName/_settings?filter_path=*.settings.index.max_result_window"
    $actualMaxResultWindow = $settings.$ExpectedOpenSearchIndexName.settings.index.max_result_window
    if ($null -eq $actualMaxResultWindow) {
        $actualMaxResultWindow = 10000
    }
    $actualMaxResultWindow = [int] $actualMaxResultWindow
    if ($actualMaxResultWindow -lt $ExpectedMaxResultWindow) {
        throw "OpenSearch index $ExpectedOpenSearchIndexName max_result_window=$actualMaxResultWindow, expected at least $ExpectedMaxResultWindow for B3 offset=10000 limit=50."
    }

    $indexCountResult = Invoke-OpenSearch -Method "GET" -Path "$OpenSearchAlias/_count"
    if ([long] $indexCountResult.count -ne [long] $sourceCounts.productsModerateSkewCount) {
        throw "OpenSearch alias $OpenSearchAlias is not the official full corpus. Indexed root documents=$($indexCountResult.count), expected=$($sourceCounts.productsModerateSkewCount). Partial/smoke subsets must not be used for official measured runs."
    }

    $statusAgg = Invoke-OpenSearch -Method "POST" -Path "$OpenSearchAlias/_search" -Body @{
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
    if (
        [long] $statusCounts.ACTIVE -ne [long] $sourceCounts.statusCounts.ACTIVE -or
        [long] $statusCounts.DELETED -ne [long] $sourceCounts.statusCounts.DELETED -or
        [long] $statusCounts.SOLD_OUT -ne [long] $sourceCounts.statusCounts.SOLD_OUT
    ) {
        throw "OpenSearch status counts do not match products_moderate_skew source counts."
    }

    $rows = foreach ($scenario in $RequestScenarios) {
        $countResult = Invoke-OpenSearch -Method "POST" -Path "$OpenSearchAlias/_count" -Body (Build-OpenSearchQuery -Scenario $scenario)
        [pscustomobject]@{
            scenario = $scenario.Name
            matchingCount = [long] $countResult.count
            requiredMinCount = [long] $scenario.RequiredMinCount
            passes = ([long] $countResult.count -ge [long] $scenario.RequiredMinCount)
        }
    }

    $failed = @($rows | Where-Object { -not $_.passes })
    if ($failed.Count -gt 0) {
        $failedText = $failed | Format-Table -AutoSize | Out-String
        throw "OpenSearch alias $OpenSearchAlias is not ready for product-search-baseline-v1. Required counts are not met:`n$failedText"
    }

    Write-Host "OpenSearch alias $OpenSearchAlias has the official full corpus and enough matching documents for B1/B2/B3."
    return [pscustomobject]@{
        alias = $OpenSearchAlias
        expectedIndex = $ExpectedOpenSearchIndexName
        aliasInfo = $aliasInfo
        optionsType = $optionsType
        maxResultWindow = $actualMaxResultWindow
        sourceCounts = $sourceCounts
        indexedRootDocumentCount = [long] $indexCountResult.count
        statusCounts = $statusCounts
        scenarioCounts = $rows
    }
}

function Stop-ProcessTree {
    param([int] $ProcessId)
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        Stop-ProcessTree -ProcessId $child.ProcessId
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Stop-AppPortOwner {
    $connections = Get-NetTCPConnection -LocalPort $AppPort -State Listen -ErrorAction SilentlyContinue
    foreach ($connection in $connections) {
        $ownerProcessId = [int] $connection.OwningProcess
        if ($ownerProcessId -le 0) {
            continue
        }
        $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerProcessId" -ErrorAction SilentlyContinue
        if ($null -ne $owner -and $owner.CommandLine -like "*$RepoRoot*" -and $owner.CommandLine -like "*--server.port=$AppPort*") {
            Stop-ProcessTree -ProcessId $ownerProcessId
        }
        else {
            throw "Port $AppPort is already in use by process $ownerProcessId and does not look like this benchmark app."
        }
    }
}

function Start-BenchmarkApp {
    param([Parameter(Mandatory = $true)][string] $RunName)

    if ($SkipAppStart) {
        return [pscustomobject]@{
            process = $null
            stdoutPath = $null
            stderrPath = $null
            externallyManaged = $true
        }
    }

    Stop-AppPortOwner
    $logDir = Join-Path $ProfileResultDir "product_search_opensearch_products_${Profile}_${Timestamp}_${RunName}_logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $stdoutPath = Join-Path $logDir "app-stdout.log"
    $stderrPath = Join-Path $logDir "app-stderr.log"
    $env:GRADLE_USER_HOME = "C:\gradle-cache\readpath-lab-opensearch-k6"

    $bootArgs = @(
        "--server.port=$AppPort",
        "--readpath.product-search.read-path=opensearch",
        "--readpath.product-search.baseline.products-table=products_moderate_skew",
        "--readpath.product-search.baseline.product-options-table=product_options_moderate_skew",
        "--readpath.product-search.open-search.base-url=$OpenSearchUrl",
        "--readpath.product-search.open-search.index-alias=$OpenSearchAlias",
        "--readpath.product-search.open-search.timeout-ms=$TimeoutMs",
        "--readpath.product-search.open-search.circuit-breaker.enabled=true",
        "--readpath.product-search.open-search.circuit-breaker.failure-threshold=$FailureThreshold",
        "--readpath.product-search.open-search.circuit-breaker.open-wait-ms=$OpenWaitMs",
        "--readpath.product-search.open-search.circuit-breaker.half-open-permitted-calls=$HalfOpenPermittedCalls"
    ) -join " "

    $process = Start-Process `
        -FilePath (Join-Path $RepoRoot "gradlew.bat") `
        -ArgumentList @("--no-daemon", "--max-workers=1", "bootRun", "--args=`"$bootArgs`"") `
        -WorkingDirectory $RepoRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden `
        -PassThru

    return [pscustomobject]@{
        process = $process
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        externallyManaged = $false
    }
}

function Stop-BenchmarkApp {
    param([object] $App)
    if ($null -eq $App -or $App.externallyManaged) {
        return
    }
    if ($null -ne $App.process -and -not $App.process.HasExited) {
        Stop-ProcessTree -ProcessId $App.process.Id
        $App.process.WaitForExit(10000) | Out-Null
    }
    Stop-AppPortOwner
}

function Wait-AppReady {
    $deadline = (Get-Date).AddSeconds($AppReadyTimeoutSeconds)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-RestMethod -Method GET -Uri "$BaseUrl/actuator/health"
            if ($response.status -eq "UP") {
                Write-Host "Application health: UP"
                return
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds 2
    }
    throw "Application did not become ready within $AppReadyTimeoutSeconds seconds. Last error: $lastError"
}

function Scenario-QueryString {
    param([object] $Scenario)
    return (($Scenario.Query.GetEnumerator() | ForEach-Object {
        "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString([string]$_.Value))"
    }) -join "&")
}

function Invoke-HttpSmoke {
    $results = foreach ($scenario in $RequestScenarios) {
        $uri = "$BaseUrl/api/v1/products/search?$(Scenario-QueryString -Scenario $scenario)"
        $response = Invoke-WebRequest -UseBasicParsing -Method GET -Uri $uri
        $json = $response.Content | ConvertFrom-Json
        $itemsLength = @($json.items).Count
        $passed = [int] $response.StatusCode -eq 200 `
            -and $itemsLength -eq [int] $scenario.Query.limit `
            -and [int] $json.page.limit -eq [int] $scenario.Query.limit `
            -and [int] $json.page.offset -eq [int] $scenario.Query.offset `
            -and [int] $json.page.returnedCount -eq [int] $scenario.Query.limit

        [pscustomobject]@{
            scenario = $scenario.Name
            statusCode = [int] $response.StatusCode
            itemsLength = $itemsLength
            pageLimit = [int] $json.page.limit
            pageOffset = [int] $json.page.offset
            returnedCount = [int] $json.page.returnedCount
            result = $(if ($passed) { "pass" } else { "fail" })
        }
    }

    $failed = @($results | Where-Object { $_.result -ne "pass" })
    if ($failed.Count -gt 0) {
        $failedText = $failed | Format-Table -AutoSize | Out-String
        throw "HTTP smoke failed:`n$failedText"
    }
    Write-Host "HTTP smoke passed for all B1/B2/B3 scenarios."
    return $results
}

function Invoke-K6Run {
    param(
        [Parameter(Mandatory = $true)][string] $RunName,
        [Parameter(Mandatory = $true)][string] $RunDuration,
        [string] $RunSummaryPath,
        [switch] $SmokeOnly,
        [switch] $Quiet
    )

    $env:PROFILE = $Profile
    $env:BASE_URL = $BaseUrl
    $env:VUS = "$VUs"
    $env:DURATION = $RunDuration
    $env:OPEN_SEARCH_ALIAS = $OpenSearchAlias
    $env:OPEN_SEARCH_TIMEOUT_MS = "$TimeoutMs"
    $env:CIRCUIT_BREAKER_ENABLED = "true"

    if ($SmokeOnly) {
        $env:SMOKE_ONLY = "true"
        Remove-Item Env:SUMMARY_JSON -ErrorAction SilentlyContinue
    }
    else {
        $env:SMOKE_ONLY = "false"
        if ($RunSummaryPath) {
            $env:SUMMARY_JSON = $RunSummaryPath
        }
        else {
            Remove-Item Env:SUMMARY_JSON -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Running $RunName..."
    if ($Quiet) {
        k6 run --quiet $ScriptPath
    }
    else {
        k6 run $ScriptPath
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$RunName failed with exit code $LASTEXITCODE."
    }
}

function Get-LogCounts {
    param([string] $StdoutPath)
    $logText = ""
    if ($StdoutPath -and (Test-Path $StdoutPath)) {
        $logText = Get-Content -Raw $StdoutPath
        if ($null -eq $logText) {
            $logText = ""
        }
    }
    return [pscustomobject]@{
        fallbackCount = ([regex]::Matches($logText, "product_search_opensearch_fallback")).Count
        fallbackSuccessCount = ([regex]::Matches($logText, "product_search_db_fallback_success")).Count
        timeoutCount = ([regex]::Matches($logText, "reason=TIMEOUT")).Count
        circuitBreakerOpenCount = ([regex]::Matches($logText, "product_search_opensearch_circuit_breaker_open")).Count
        shortCircuitedRequestCount = ([regex]::Matches($logText, "product_search_opensearch_circuit_breaker_short_circuit")).Count
    }
}

function Add-OperationalMetricsToSummary {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][object] $Counts)

    $summary = Get-Content $Path -Raw | ConvertFrom-Json
    $summary.benchmark | Add-Member -NotePropertyName operationalMetricsSource -NotePropertyValue "measured app stdout log counts" -Force
    $summary.benchmark | Add-Member -NotePropertyName officialResultRequirements -NotePropertyValue ([pscustomobject]@{
        failedChecks = 0
        errorRate = 0
        fallbackCount = 0
        fallbackSuccessCount = 0
        timeoutCount = 0
        circuitBreakerOpenCount = 0
        shortCircuitedRequestCount = 0
    }) -Force
    $summary | Add-Member -NotePropertyName operationalMetrics -NotePropertyValue $Counts -Force
    $summary | ConvertTo-Json -Depth 100 | Set-Content -Encoding UTF8 -LiteralPath $Path
}

function MetricValue {
    param([object] $Summary, [string] $MetricName, [string] $ValueName)
    $metric = $Summary.summary.metrics.$MetricName
    if ($null -eq $metric -or $null -eq $metric.values) {
        return "N"
    }
    $value = $metric.values.$ValueName
    if ($null -eq $value) {
        return "N"
    }
    return $value
}

function Find-OfficialSummary {
    param([string] $Pattern)
    Get-ChildItem -Path $ProfileResultDir -Filter $Pattern -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "_failed_|_fallback_involved_" } |
        Sort-Object Name -Descending |
        Select-Object -First 1
}

function New-ComparisonRows {
    $sources = @(
        [pscustomobject]@{ Name = "Baseline API"; File = Find-OfficialSummary -Pattern "product_search_baseline_products_${Profile}_*_summary.json" },
        [pscustomobject]@{ Name = "DB tuned API"; File = Find-OfficialSummary -Pattern "product_search_db_tuned_products_${Profile}_*_summary.json" },
        [pscustomobject]@{ Name = "Denormalized DB API"; File = Find-OfficialSummary -Pattern "product_search_denormalized_db_products_${Profile}_*_summary.json" },
        [pscustomobject]@{ Name = "OpenSearch API"; File = Get-Item -LiteralPath $SummaryPath -ErrorAction SilentlyContinue }
    )

    foreach ($source in $sources) {
        if ($null -eq $source.File) {
            continue
        }
        $summary = Get-Content $source.File.FullName -Raw | ConvertFrom-Json
        "| $($source.Name) | $(MetricValue -Summary $summary -MetricName "http_reqs" -ValueName "count") | $(MetricValue -Summary $summary -MetricName "http_req_duration" -ValueName "p(95)") ms | $(MetricValue -Summary $summary -MetricName "b1_selective_option_filter_duration" -ValueName "p(95)") ms | $(MetricValue -Summary $summary -MetricName "b2_broad_active_option_filter_duration" -ValueName "p(95)") ms | $(MetricValue -Summary $summary -MetricName "b3_deep_offset_option_filter_duration" -ValueName "p(95)") ms | $(MetricValue -Summary $summary -MetricName "http_reqs" -ValueName "rate") req/s | $(MetricValue -Summary $summary -MetricName "http_req_failed" -ValueName "rate") | $(MetricValue -Summary $summary -MetricName "checks" -ValueName "fails") |"
    }
}

function Write-Observations {
    param(
        [Parameter(Mandatory = $true)][object] $Readiness,
        [Parameter(Mandatory = $true)][object[]] $HttpSmoke,
        [Parameter(Mandatory = $true)][object] $Counts
    )

    $summary = Get-Content $SummaryPath -Raw | ConvertFrom-Json
    $metrics = $summary.summary.metrics
    $dockerSettings = Read-DockerDesktopSettings
    $scenarioCountLines = foreach ($row in $Readiness.scenarioCounts) {
        "- $($row.scenario): matching_count=$($row.matchingCount), required_min_count=$($row.requiredMinCount), passes=$($row.passes)"
    }
    $httpSmokeLines = foreach ($row in $HttpSmoke) {
        "| $($row.scenario) | $($row.statusCode) | $($row.itemsLength) | $($row.pageLimit) | $($row.pageOffset) | $($row.returnedCount) | $($row.result) |"
    }
    $comparisonRows = @(New-ComparisonRows)
    if ($comparisonRows.Count -eq 0) {
        $comparisonRows = @("| No previous official result files found | N | N | N | N | N | N | N | N |")
    }

    $content = @"
# Product Search OpenSearch API k6 Observation

## Run Identity

| Item | Value |
|---|---|
| Status | official primary OpenSearch local synthetic result |
| Scenario set | product-search-baseline-v1 |
| Workload version | product-search-baseline-v1 |
| Profile | $Profile |
| Read path flag state | readpath.product-search.read-path=opensearch |
| Endpoint | GET /api/v1/products/search |
| OpenSearch URL | $OpenSearchUrl |
| OpenSearch read alias | $OpenSearchAlias |
| OpenSearch expected index | $ExpectedOpenSearchIndexName |
| OpenSearch max_result_window | $($readiness.maxResultWindow) |
| OpenSearch timeout | ${TimeoutMs} ms |
| Circuit breaker enabled | true |
| Circuit breaker threshold | $FailureThreshold |
| Circuit breaker open wait | ${OpenWaitMs} ms |
| Circuit breaker half-open permitted calls | $HalfOpenPermittedCalls |
| App execution mode | Gradle bootRun |
| k6 execution mode | local k6 |
| VUs | $VUs |
| Warm-up duration | $WarmupDuration |
| Measured duration | $Duration |
| Timestamp | $Timestamp |
| Docker memory setting | $($dockerSettings.memoryMiB) MiB |
| Official summary JSON | $SummaryPath |

This is a local synthetic moderate_skew benchmark result, not a production
capacity claim. It does not define production readiness, capacity, SLA, or SLO.

## Environment / Control Checks

- PostgreSQL container: readpath-postgres, healthy before measured run.
- OpenSearch health: green/yellow check passed before measured run.
- Dataset profile: products_moderate_skew.
- Scenario version: product-search-baseline-v1.
- OpenSearch alias points to expected full-corpus benchmark index: $ExpectedOpenSearchIndexName.
- OpenSearch options mapping type: $($Readiness.optionsType).
- Indexed root document count: $($Readiness.indexedRootDocumentCount).
- No seed, migration, index creation, backfill, catch-up replay, or relay process was intentionally started by this benchmark runner.
- The measured app process was freshly started before the measured run, so fallback/circuit-breaker counters began from process-local zero.
- Circuit breaker was expected to start closed in the fresh measured app process.

## OpenSearch Alias Readiness

$($scenarioCountLines -join "`n")

## Scenario Constants

| Scenario | Weight | Parameters |
|---|---:|---|
| B1_selective_option_filter | 40% | categoryId=75, brandId=943, status=ACTIVE, minPrice=10000, maxPrice=100000, color=BLACK, size=M, stockStatus=IN_STOCK, sort=reviewCountDesc, limit=50, offset=100 |
| B2_broad_active_option_filter | 40% | status=ACTIVE, color=BLACK, size=M, stockStatus=IN_STOCK, sort=createdAtDesc, limit=50, offset=100 |
| B3_deep_offset_option_filter | 20% | categoryId=75, brandId=943, status=ACTIVE, minPrice=10000, maxPrice=100000, color=BLACK, size=M, stockStatus=IN_STOCK, sort=reviewCountDesc, limit=50, offset=10000 |

## Commands

~~~powershell
.\benchmark\k6\run-product-search-opensearch.ps1 -Profile $Profile -OpenSearchUrl $OpenSearchUrl -OpenSearchAlias $OpenSearchAlias -VUs $VUs -WarmupDuration $WarmupDuration -Duration $Duration -TimeoutMs $TimeoutMs -AppReadyTimeoutSeconds $AppReadyTimeoutSeconds
~~~

The runner executed HTTP smoke, k6 smoke, warm-up, then measured run. HTTP
smoke, k6 smoke, and warm-up are not official benchmark artifacts.

## HTTP Smoke

| Scenario | HTTP status | items length | page.limit | page.offset | returnedCount | Result |
|---|---:|---:|---:|---:|---:|---|
$($httpSmokeLines -join "`n")

## k6 Smoke

Result: pass, exit code 0, failed checks 0. k6 smoke is not an official result.

## Warm-up

Result: pass, exit code 0. Warm-up is excluded from official results.

## Measured Run

| Metric | Value |
|---|---:|
| Mixed p95 | $($metrics.http_req_duration.values.'p(95)') ms |
| B1 p95 | $($metrics.b1_selective_option_filter_duration.values.'p(95)') ms |
| B2 p95 | $($metrics.b2_broad_active_option_filter_duration.values.'p(95)') ms |
| B3 p95 | $($metrics.b3_deep_offset_option_filter_duration.values.'p(95)') ms |
| Throughput | $($metrics.http_reqs.values.rate) req/s |
| Error rate | $($metrics.http_req_failed.values.rate) |
| Failed checks | $($metrics.checks.values.fails) |
| Total requests | $($metrics.http_reqs.values.count) |
| Fallback count | $($Counts.fallbackCount) |
| Fallback success count | $($Counts.fallbackSuccessCount) |
| Timeout count | $($Counts.timeoutCount) |
| Circuit breaker open count | $($Counts.circuitBreakerOpenCount) |
| Short-circuited request count | $($Counts.shortCircuitedRequestCount) |

Primary official OpenSearch result: yes. The measured run had failed checks 0,
error rate 0, fallback count 0, fallback success count 0, timeout count 0,
circuit breaker open count 0, and short-circuited request count 0.

## Scenario Iteration Counts

| Scenario | Iterations |
|---|---:|
| B1 | $($metrics.b1_selective_option_filter_iterations.values.count) |
| B2 | $($metrics.b2_broad_active_option_filter_iterations.values.count) |
| B3 | $($metrics.b3_deep_offset_option_filter_iterations.values.count) |

## Comparison Table

Comparison uses existing official local synthetic artifacts when present.

| Read path | Total requests | Mixed p95 | B1 p95 | B2 p95 | B3 p95 | Throughput | Error rate | Failed checks |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
$($comparisonRows -join "`n")

## Limitations

- Local workstation and Docker Desktop result only.
- No production capacity, readiness, SLA, or SLO claim.
- No relevance tuning, synonym search, typo tolerance, autocomplete, Kafka, Debezium, CDC pipeline, production monitoring, or dashboarding was added.
- API p95 must not be compared with PostgreSQL EXPLAIN Execution Time.
"@

    Set-Content -LiteralPath $ObservationsPath -Value $content -Encoding ASCII
}

function Write-BlockedObservations {
    param([Parameter(Mandatory = $true)][string] $Reason)

    New-Item -ItemType Directory -Force -Path $ProfileResultDir | Out-Null
    $content = @"
# Product Search OpenSearch API k6 Observation

## Status

Blocked before official k6 measurement.

Reason:

~~~text
$Reason
~~~

No official OpenSearch k6 summary JSON was created. No smoke, warm-up, or
measured result is treated as official.

## Intended Command

~~~powershell
.\benchmark\k6\run-product-search-opensearch.ps1 -Profile $Profile -OpenSearchUrl $OpenSearchUrl -OpenSearchAlias $OpenSearchAlias -VUs $VUs -WarmupDuration $WarmupDuration -Duration $Duration -TimeoutMs $TimeoutMs -AppReadyTimeoutSeconds $AppReadyTimeoutSeconds
~~~

## Required Environment

- PostgreSQL container healthy.
- OpenSearch healthy.
- readpath.product-search.read-path=opensearch.
- OpenSearch read alias $OpenSearchAlias points to a prepared
  products_moderate_skew full benchmark index.
- The alias must point to $ExpectedOpenSearchIndexName.
- The index must contain the full products_moderate_skew root document count,
  not a smoke/preflight subset.
- B1/B2/B3 matching document counts satisfy the
  product-search-baseline-v1 offsets and limits.
- No seed, migration, backfill, catch-up replay, index creation, or unrelated
  heavy task is running during the measured run.

This blocked observation is a local synthetic benchmark control artifact, not a
production capacity claim.
"@

    Set-Content -LiteralPath $BlockedObservationsPath -Value $content -Encoding ASCII
    Write-Host "Blocked observation: $BlockedObservationsPath"
}

New-Item -ItemType Directory -Force -Path $ProfileResultDir | Out-Null

$setupApp = $null
$measuredApp = $null
try {
    Assert-K6Installed
    Assert-DockerMemorySetting
    Assert-PostgresHealthy
    Assert-OpenSearchHealthy | Out-Null
    $readiness = Test-OpenSearchBenchmarkReadiness

    $setupApp = Start-BenchmarkApp -RunName "smoke-warmup"
    Wait-AppReady
    $httpSmoke = @(Invoke-HttpSmoke)
    Invoke-K6Run -RunName "k6 smoke" -RunDuration "1s" -SmokeOnly
    Invoke-K6Run -RunName "warm-up run" -RunDuration $WarmupDuration -Quiet
    Stop-BenchmarkApp -App $setupApp
    $setupApp = $null

    $measuredApp = Start-BenchmarkApp -RunName "measured"
    Wait-AppReady
    try {
        Invoke-K6Run -RunName "measured run" -RunDuration $Duration -RunSummaryPath $SummaryPath -Quiet
    }
    catch {
        if (Test-Path $SummaryPath) {
            $failedSummaryPath = $SummaryPath -replace "_summary\.json$", "_failed_summary.json"
            Move-Item -LiteralPath $SummaryPath -Destination $failedSummaryPath -Force
            Write-Host "Failed measured summary saved as non-official artifact: $failedSummaryPath"
        }
        throw
    }
    Stop-BenchmarkApp -App $measuredApp
    $counts = Get-LogCounts -StdoutPath $measuredApp.stdoutPath
    $measuredApp = $null

    Add-OperationalMetricsToSummary -Path $SummaryPath -Counts $counts

    if ($counts.fallbackCount -ne 0 -or $counts.fallbackSuccessCount -ne 0 -or $counts.timeoutCount -ne 0 -or $counts.circuitBreakerOpenCount -ne 0 -or $counts.shortCircuitedRequestCount -ne 0) {
        $fallbackSummaryPath = $SummaryPath -replace "_summary\.json$", "_fallback_involved_summary.json"
        Move-Item -LiteralPath $SummaryPath -Destination $fallbackSummaryPath -Force
        throw "Measured run involved fallback or circuit breaker activity. Non-official artifact: $fallbackSummaryPath"
    }

    Write-Observations -Readiness $readiness -HttpSmoke $httpSmoke -Counts $counts

    Write-Host "Measured summary JSON: $SummaryPath"
    Write-Host "Observations: $ObservationsPath"
}
catch {
    if (-not (Test-Path $SummaryPath)) {
        Write-BlockedObservations -Reason $_.Exception.Message
    }
    throw
}
finally {
    Stop-BenchmarkApp -App $setupApp
    Stop-BenchmarkApp -App $measuredApp
}
