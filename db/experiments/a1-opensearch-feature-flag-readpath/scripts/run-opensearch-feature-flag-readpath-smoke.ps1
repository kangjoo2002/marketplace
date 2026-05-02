param(
    [string] $OpenSearchUrl = $(if ($env:OPENSEARCH_URL) { $env:OPENSEARCH_URL } else { "http://localhost:9200" }),
    [string] $OpenSearchImage = "opensearchproject/opensearch:2.15.0",
    [int] $AppPort = $(if ($env:FEATURE_FLAG_SMOKE_APP_PORT) { [int] $env:FEATURE_FLAG_SMOKE_APP_PORT } else { 18080 }),
    [int] $AppReadyWaitSeconds = 120,
    [int] $OpenSearchWaitSeconds = 120,
    [int] $TimeoutMs = 500
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$OpenSearchUrl = $OpenSearchUrl.TrimEnd("/")

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$experimentDir = Resolve-Path (Join-Path $scriptDir "..")
$repoRoot = Resolve-Path (Join-Path $experimentDir "..\..\..")
$mappingPath = Join-Path $repoRoot "db\experiments\a1-opensearch-index-mapping-alias\mappings\products_v1_nested.json"
$outboxSchemaPath = Join-Path $repoRoot "db\init\002_create_search_outbox.sql"
$productOptionsSchemaPath = Join-Path $repoRoot "db\seed\product-options\product_options_schema.sql"
$prepareSqlPath = Join-Path $experimentDir "sql\prepare-feature-flag-smoke-data.sql"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$tempResultDir = Join-Path $experimentDir "results\$timestamp.partial"
$resultDir = Join-Path $experimentDir "results\$timestamp"

$indexName = "products_search_switch_smoke_v1"
$readAlias = "products_search_switch_smoke_read"
$queryPath = "/api/v1/products/search?categoryId=75&brandId=943&status=ACTIVE&color=BLACK&size=M&stockStatus=IN_STOCK&sort=reviewCountDesc&limit=2&offset=0"
$invalidQueryPath = "/api/v1/products/search?sort=ratingDesc"

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

function Wait-OpenSearchHealth {
    $lastError = $null
    $deadline = (Get-Date).AddSeconds($OpenSearchWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            return Invoke-RestMethod -Method GET -Uri "$OpenSearchUrl/_cluster/health"
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }
    throw "OpenSearch healthcheck did not succeed within $OpenSearchWaitSeconds seconds. Last error: $lastError"
}

function Invoke-OpenSearch {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Method,
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [object] $Body,
        [string] $BodyPath
    )

    $params = @{
        Method = $Method
        Uri = "$OpenSearchUrl/$($Path.TrimStart('/'))"
    }
    if ($BodyPath) {
        $params["Body"] = Get-Content -Raw $BodyPath
        $params["ContentType"] = "application/json"
    }
    elseif ($null -ne $Body) {
        $params["Body"] = $Body | ConvertTo-Json -Depth 80 -Compress
        $params["ContentType"] = "application/json"
    }
    Invoke-RestMethod @params
}

function Remove-SmokeIndex {
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
}

function New-SmokeDocument {
    param(
        [long] $ProductId,
        [long] $SellerId,
        [int] $ReviewCount,
        [string] $CreatedAt
    )

    return @{
        productId = $ProductId
        sellerId = $SellerId
        categoryId = 75
        brandId = 943
        status = "ACTIVE"
        price = 20000 + $ReviewCount
        rating = 4.50
        reviewCount = $ReviewCount
        createdAt = $CreatedAt
        updatedAt = $CreatedAt
        sourceUpdatedAt = $CreatedAt
        documentRefreshedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        options = @(
            @{
                color = "BLACK"
                size = "M"
                stockStatus = "IN_STOCK"
            }
        )
    }
}

function Initialize-OpenSearchSmokeIndex {
    Remove-SmokeIndex
    Invoke-OpenSearch -Method "PUT" -Path $indexName -BodyPath $mappingPath | Out-Null
    Invoke-OpenSearch -Method "POST" -Path "_aliases" -Body @{
        actions = @(
            @{ add = @{ index = $indexName; alias = $readAlias } }
        )
    } | Out-Null

    $documents = @(
        (New-SmokeDocument -ProductId (-22002003) -SellerId 22003 -ReviewCount 330 -CreatedAt "2026-05-02T16:00:03"),
        (New-SmokeDocument -ProductId (-22002002) -SellerId 22002 -ReviewCount 320 -CreatedAt "2026-05-02T16:00:02"),
        (New-SmokeDocument -ProductId (-22002001) -SellerId 22001 -ReviewCount 310 -CreatedAt "2026-05-02T16:00:01")
    )

    foreach ($document in $documents) {
        Invoke-OpenSearch -Method "PUT" -Path "$indexName/_doc/$($document.productId)?refresh=true" -Body $document | Out-Null
    }

    return [pscustomobject]@{
        indexName = $indexName
        readAlias = $readAlias
        indexedDocumentCount = $documents.Count
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Value,
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $Value | ConvertTo-Json -Depth 80 | Set-Content -Encoding UTF8 $Path
}

function Stop-ProcessTree {
    param([int] $ProcessId)

    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        Stop-ProcessTree -ProcessId $child.ProcessId
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Stop-SmokePortOwner {
    $connections = Get-NetTCPConnection -LocalPort $AppPort -State Listen -ErrorAction SilentlyContinue
    foreach ($connection in $connections) {
        $ownerProcessId = [int] $connection.OwningProcess
        if ($ownerProcessId -le 0) {
            continue
        }

        $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerProcessId" -ErrorAction SilentlyContinue
        if ($null -ne $owner -and $owner.CommandLine -like "*$repoRoot*" -and $owner.CommandLine -like "*--server.port=$AppPort*") {
            Stop-ProcessTree -ProcessId $ownerProcessId
        }
        else {
            throw "Port $AppPort is already in use by process $ownerProcessId and does not look like this smoke app"
        }
    }
}

function Start-SmokeApp {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ReadPath,
        [Parameter(Mandatory = $true)]
        [string] $ScenarioName,
        [string] $ScenarioOpenSearchUrl = $OpenSearchUrl
    )

    Stop-SmokePortOwner

    $stdoutPath = Join-Path $tempResultDir "$ScenarioName-app-stdout.log"
    $stderrPath = Join-Path $tempResultDir "$ScenarioName-app-stderr.log"
    $env:GRADLE_USER_HOME = "C:\gradle-cache\readpath-lab"

    $bootArgs = @(
        "--server.port=$AppPort",
        "--readpath.product-search.read-path=$ReadPath",
        "--readpath.product-search.baseline.products-table=products",
        "--readpath.product-search.baseline.product-options-table=product_options_moderate_skew",
        "--readpath.product-search.open-search.base-url=$ScenarioOpenSearchUrl",
        "--readpath.product-search.open-search.index-alias=$readAlias",
        "--readpath.product-search.open-search.timeout-ms=$TimeoutMs"
    ) -join " "

    $process = Start-Process `
        -FilePath (Join-Path $repoRoot "gradlew.bat") `
        -ArgumentList @("--no-daemon", "--max-workers=1", "bootRun", "--args=`"$bootArgs`"") `
        -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden `
        -PassThru

    return [pscustomobject]@{
        process = $process
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        readPath = $ReadPath
        openSearchUrl = $ScenarioOpenSearchUrl
    }
}

function Stop-SmokeApp {
    param([object] $App)

    if ($null -eq $App) {
        return
    }
    if (-not $App.process.HasExited) {
        Stop-ProcessTree -ProcessId $App.process.Id
        $App.process.WaitForExit(10000) | Out-Null
    }
    Stop-SmokePortOwner
}

function Wait-AppReady {
    $deadline = (Get-Date).AddSeconds($AppReadyWaitSeconds)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-RestMethod -Method GET -Uri "http://localhost:$AppPort/actuator/health"
            if ($response.status -eq "UP") {
                return $response
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds 2
    }
    throw "Application did not become ready within $AppReadyWaitSeconds seconds. Last error: $lastError"
}

function Invoke-AppRequest {
    param([string] $Path)

    $uri = "http://localhost:$AppPort$Path"
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method GET -Uri $uri
        return [pscustomobject]@{
            statusCode = [int] $response.StatusCode
            body = $response.Content
            json = $response.Content | ConvertFrom-Json
        }
    }
    catch {
        $statusCode = $null
        $body = ""
        if ($null -ne $_.Exception.Response) {
            $statusCode = [int] $_.Exception.Response.StatusCode
            $stream = $_.Exception.Response.GetResponseStream()
            if ($null -ne $stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
            }
        }
        return [pscustomobject]@{
            statusCode = $statusCode
            body = $body
            json = $null
        }
    }
}

function Invoke-SmokeScenario {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ScenarioName,
        [Parameter(Mandatory = $true)]
        [string] $ReadPath,
        [string] $ScenarioOpenSearchUrl = $OpenSearchUrl,
        [string] $RequestPath = $queryPath,
        [int] $ExpectedStatus = 200
    )

    $app = $null
    $startedAt = Get-Date
    try {
        $app = Start-SmokeApp -ReadPath $ReadPath -ScenarioName $ScenarioName -ScenarioOpenSearchUrl $ScenarioOpenSearchUrl
        $stdoutPath = $app.stdoutPath
        Wait-AppReady | Out-Null
        $response = Invoke-AppRequest -Path $RequestPath
        $finishedAt = Get-Date
        Stop-SmokeApp -App $app
        $app = $null

        $fallbackLogCount = 0
        $fallbackSuccessLogCount = 0
        $timeoutLogCount = 0
        if (Test-Path $stdoutPath) {
            $logText = Get-Content -Raw $stdoutPath
            if ($null -eq $logText) {
                $logText = ""
            }
            $fallbackLogCount = ([regex]::Matches($logText, "product_search_opensearch_fallback")).Count
            $fallbackSuccessLogCount = ([regex]::Matches($logText, "product_search_db_fallback_success")).Count
            $timeoutLogCount = ([regex]::Matches($logText, "reason=TIMEOUT")).Count
        }

        $itemCount = if ($null -ne $response.json -and $null -ne $response.json.items) { @($response.json.items).Count } else { 0 }
        $shapeMatches = $response.statusCode -eq 200 -and $null -ne $response.json.items -and $null -ne $response.json.page
        return [pscustomobject]@{
            scenario = $ScenarioName
            readPath = $ReadPath
            openSearchUrl = $ScenarioOpenSearchUrl
            statusCode = $response.statusCode
            expectedStatusCode = $ExpectedStatus
            itemCount = $itemCount
            responseShapeMatches = $shapeMatches
            fallbackLogCount = $fallbackLogCount
            fallbackSuccessLogCount = $fallbackSuccessLogCount
            timeoutLogCount = $timeoutLogCount
            durationMs = [int] ($finishedAt - $startedAt).TotalMilliseconds
            result = $(if ($response.statusCode -eq $ExpectedStatus) { "pass" } else { "fail" })
            responseBody = $response.body
        }
    }
    finally {
        Stop-SmokeApp -App $app
    }
}

Push-Location $repoRoot
$success = $false
try {
    New-Item -ItemType Directory -Force -Path $tempResultDir | Out-Null

    Write-Host "Checking OpenSearch health at $OpenSearchUrl"
    $health = Wait-OpenSearchHealth

    Write-Host "Applying PostgreSQL schemas and preparing smoke data"
    Invoke-PsqlFile -SqlPath $outboxSchemaPath | Out-Null
    Invoke-PsqlFile -SqlPath $productOptionsSchemaPath | Out-Null
    $prepareResult = Invoke-PsqlFile -SqlPath $prepareSqlPath -TuplesOnly | ConvertFrom-Json

    Write-Host "Creating OpenSearch switch smoke index"
    $openSearchSetup = Initialize-OpenSearchSmokeIndex

    Write-Host "Running flag-off DB path smoke"
    $dbScenario = Invoke-SmokeScenario -ScenarioName "flag-off-db" -ReadPath "db"

    Write-Host "Running flag-on OpenSearch path smoke"
    $searchScenario = Invoke-SmokeScenario -ScenarioName "flag-on-opensearch" -ReadPath "opensearch"

    Write-Host "Running OpenSearch unavailable fallback smoke"
    $fallbackScenario = Invoke-SmokeScenario `
        -ScenarioName "opensearch-unavailable-fallback" `
        -ReadPath "opensearch" `
        -ScenarioOpenSearchUrl "http://127.0.0.1:1"

    Write-Host "Running non-fallback validation error smoke"
    $validationScenario = Invoke-SmokeScenario `
        -ScenarioName "non-fallback-validation-error" `
        -ReadPath "opensearch" `
        -ScenarioOpenSearchUrl "http://127.0.0.1:1" `
        -RequestPath $invalidQueryPath `
        -ExpectedStatus 400

    Write-Host "Running flag rollback to DB smoke"
    $rollbackStartedAt = Get-Date
    $rollbackScenario = Invoke-SmokeScenario -ScenarioName "flag-rollback-db" -ReadPath "db"
    $rollbackFinishedAt = Get-Date
    $rollbackDurationMs = [int] ($rollbackFinishedAt - $rollbackStartedAt).TotalMilliseconds

    $fallbackCount = $fallbackScenario.fallbackLogCount
    $fallbackSuccessCount = $fallbackScenario.fallbackSuccessLogCount
    $timeoutCount = $fallbackScenario.timeoutLogCount
    $openSearchFailureScenarioCount = 1

    $manualFutureScenarios = [pscustomobject]@{
        openSearch5xxScenario = "manual/future validation; no deterministic fake OpenSearch 5xx server is started by this smoke"
        malformedSearchResponseScenario = "manual/future validation; no deterministic malformed Search server is started by this smoke"
    }

    $metrics = [pscustomobject]@{
        flagName = "readpath.product-search.read-path"
        flagSource = "Spring application property or environment override"
        defaultFlagValue = "db"
        dbPathSmokeResult = $dbScenario.result
        searchPathSmokeResult = $searchScenario.result
        fallbackScenarioResult = $fallbackScenario.result
        fallbackCount = $fallbackCount
        fallbackSuccessCount = $fallbackSuccessCount
        timeoutCount = $timeoutCount
        openSearchFailureScenarioCount = $openSearchFailureScenarioCount
        nonFallbackValidationErrorResult = $validationScenario.result
        flagRollbackPass = $rollbackScenario.result -eq "pass"
        flagRollbackTimeMs = $rollbackDurationMs
        circuitBreakerImplemented = $false
        circuitBreakerFollowUpDocumented = $true
    }

    if ($dbScenario.result -ne "pass" -or -not $dbScenario.responseShapeMatches) {
        throw "DB path smoke failed"
    }
    if ($searchScenario.result -ne "pass" -or -not $searchScenario.responseShapeMatches) {
        throw "OpenSearch path smoke failed"
    }
    if ($fallbackScenario.result -ne "pass" -or -not $fallbackScenario.responseShapeMatches) {
        throw "Fallback smoke failed"
    }
    if ($fallbackCount -lt 1 -or $fallbackSuccessCount -lt 1) {
        throw "Fallback logs were not observed"
    }
    if ($validationScenario.statusCode -ne 400 -or $validationScenario.fallbackLogCount -ne 0) {
        throw "Non-fallback validation error smoke failed"
    }
    if ($rollbackScenario.result -ne "pass" -or -not $rollbackScenario.responseShapeMatches) {
        throw "Flag rollback smoke failed"
    }

    Write-JsonFile -Value $prepareResult -Path (Join-Path $tempResultDir "prepare-result.json")
    Write-JsonFile -Value $openSearchSetup -Path (Join-Path $tempResultDir "opensearch-smoke-index-result.json")
    Write-JsonFile -Value $dbScenario -Path (Join-Path $tempResultDir "db-path-smoke-result.json")
    Write-JsonFile -Value $searchScenario -Path (Join-Path $tempResultDir "search-path-smoke-result.json")
    Write-JsonFile -Value $fallbackScenario -Path (Join-Path $tempResultDir "fallback-smoke-result.json")
    Write-JsonFile -Value $validationScenario -Path (Join-Path $tempResultDir "non-fallback-validation-result.json")
    Write-JsonFile -Value $rollbackScenario -Path (Join-Path $tempResultDir "flag-rollback-result.json")
    Write-JsonFile -Value $manualFutureScenarios -Path (Join-Path $tempResultDir "manual-future-failure-scenarios.json")
    Write-JsonFile -Value $metrics -Path (Join-Path $tempResultDir "feature-flag-readpath-metrics.json")

    $summary = @"
# OpenSearch Feature Flag Read Path Smoke Summary

- PostgreSQL target: docker compose postgres/readpath_lab
- OpenSearch URL: $OpenSearchUrl
- OpenSearch image: $OpenSearchImage
- Smoke index: $indexName
- Smoke read alias: $readAlias
- Feature flag: readpath.product-search.read-path
- Default flag value: db
- Timeout ms: $TimeoutMs
- Circuit breaker implemented: false
- Final smoke status: pass

| metric | value |
|---|---:|
| DB path smoke result | $($dbScenario.result) |
| Search path smoke result | $($searchScenario.result) |
| fallback smoke result | $($fallbackScenario.result) |
| fallback count | $fallbackCount |
| fallback success count | $fallbackSuccessCount |
| timeout count | $timeoutCount |
| OpenSearch failure scenario count | $openSearchFailureScenarioCount |
| non-fallback validation error result | $($validationScenario.result) |
| flag rollback pass | $($metrics.flagRollbackPass) |
| flag rollback time ms | $rollbackDurationMs |

OpenSearch HTTP 5xx and malformed Search response fallback scenarios are documented as manual/future smoke cases in this task.
Actual circuit breaker state management is excluded and remains a later hardening task.
This smoke result is not a k6 benchmark, production readiness claim, or production SLA/SLO.
"@

    $summary | Set-Content -Encoding UTF8 (Join-Path $tempResultDir "feature-flag-readpath-summary.md")

    Move-Item -LiteralPath $tempResultDir -Destination $resultDir -Force
    $success = $true

    Write-Host "PASS: OpenSearch feature flag read-path smoke validation completed"
    Write-Host "Result artifacts: $resultDir"
} catch {
    if (Test-Path $tempResultDir) {
        "FAILED/PARTIAL: $($_.Exception.Message)" | Set-Content -Encoding UTF8 (Join-Path $tempResultDir "FAILED_PARTIAL.txt")
    }
    throw
} finally {
    Pop-Location
}
