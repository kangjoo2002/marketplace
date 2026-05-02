param(
    [string] $OpenSearchUrl = $(if ($env:OPENSEARCH_URL) { $env:OPENSEARCH_URL } else { "http://localhost:9200" }),
    [string] $OpenSearchImage = "opensearchproject/opensearch:2.15.0",
    [int] $AppPort = $(if ($env:CIRCUIT_BREAKER_SMOKE_APP_PORT) { [int] $env:CIRCUIT_BREAKER_SMOKE_APP_PORT } else { 18081 }),
    [int] $AppReadyWaitSeconds = 120,
    [int] $OpenSearchWaitSeconds = 120,
    [int] $TimeoutMs = 500,
    [int] $FailureThreshold = 3,
    [int] $OpenWaitMs = 1000,
    [int] $HalfOpenPermittedCalls = 1
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$OpenSearchUrl = $OpenSearchUrl.TrimEnd("/")

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$experimentDir = Resolve-Path (Join-Path $scriptDir "..")
$repoRoot = Resolve-Path (Join-Path $experimentDir "..\..\..")
$mappingPath = Join-Path $repoRoot "db\experiments\a1-opensearch-index-mapping-alias\mappings\products_v1_nested.json"
$openSearchComposePath = Join-Path $repoRoot "db\experiments\a1-opensearch-index-mapping-alias\docker-compose.opensearch-smoke.yml"
$outboxSchemaPath = Join-Path $repoRoot "db\init\002_create_search_outbox.sql"
$productOptionsSchemaPath = Join-Path $repoRoot "db\seed\product-options\product_options_schema.sql"
$prepareSqlPath = Join-Path $experimentDir "sql\prepare-circuit-breaker-smoke-data.sql"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$tempResultDir = Join-Path $experimentDir "results\$timestamp.partial"
$resultDir = Join-Path $experimentDir "results\$timestamp"

$indexName = "products_search_circuit_breaker_smoke_v1"
$readAlias = "products_search_circuit_breaker_smoke_read"
$queryPath = "/api/v1/products/search?categoryId=23075&brandId=23943&status=ACTIVE&color=BLACK&size=M&stockStatus=IN_STOCK&sort=reviewCountDesc&limit=2&offset=0"
$invalidQueryPath = "/api/v1/products/search?sort=ratingDesc"

function Invoke-PsqlText {
    param([Parameter(Mandatory = $true)][string] $Sql, [switch] $TuplesOnly)

    $arguments = @("compose", "exec", "-T", "postgres", "psql", "-U", "readpath", "-d", "readpath_lab", "-v", "ON_ERROR_STOP=1", "-q")
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
    param([Parameter(Mandatory = $true)][string] $SqlPath, [switch] $TuplesOnly)
    return Invoke-PsqlText -Sql (Get-Content -Raw $SqlPath) -TuplesOnly:$TuplesOnly
}

function Start-OpenSearchSmokeService {
    docker compose -f $openSearchComposePath up -d | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "OpenSearch smoke compose up failed"
    }
}

function Stop-OpenSearchSmokeService {
    docker compose -f $openSearchComposePath stop opensearch-smoke | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "OpenSearch smoke compose stop failed"
    }
}

function Wait-OpenSearchHealth {
    $lastError = $null
    $deadline = (Get-Date).AddSeconds($OpenSearchWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            return Invoke-RestMethod -Method GET -Uri "$OpenSearchUrl/_cluster/health?wait_for_status=yellow&timeout=30s"
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
        [Parameter(Mandatory = $true)][string] $Method,
        [Parameter(Mandatory = $true)][string] $Path,
        [object] $Body,
        [string] $BodyPath
    )

    $params = @{ Method = $Method; Uri = "$OpenSearchUrl/$($Path.TrimStart('/'))" }
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
    param([long] $ProductId, [long] $SellerId, [int] $Price, [decimal] $Rating, [int] $ReviewCount, [string] $CreatedAt)
    return @{
        productId = $ProductId
        sellerId = $SellerId
        categoryId = 23075
        brandId = 23943
        status = "ACTIVE"
        price = $Price
        rating = $Rating
        reviewCount = $ReviewCount
        createdAt = $CreatedAt
        updatedAt = $CreatedAt
        sourceUpdatedAt = $CreatedAt
        documentRefreshedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        options = @(@{ color = "BLACK"; size = "M"; stockStatus = "IN_STOCK" })
    }
}

function Initialize-OpenSearchSmokeIndex {
    Remove-SmokeIndex
    Invoke-OpenSearch -Method "PUT" -Path $indexName -BodyPath $mappingPath | Out-Null
    Invoke-OpenSearch -Method "POST" -Path "_aliases" -Body @{ actions = @(@{ add = @{ index = $indexName; alias = $readAlias } }) } | Out-Null
    $documents = @(
        (New-SmokeDocument -ProductId (-23002003) -SellerId 23003 -Price 23900 -Rating 4.53 -ReviewCount 330 -CreatedAt "2026-05-02T17:00:03"),
        (New-SmokeDocument -ProductId (-23002002) -SellerId 23002 -Price 22900 -Rating 4.52 -ReviewCount 320 -CreatedAt "2026-05-02T17:00:02"),
        (New-SmokeDocument -ProductId (-23002001) -SellerId 23001 -Price 21900 -Rating 4.51 -ReviewCount 310 -CreatedAt "2026-05-02T17:00:01")
    )
    foreach ($document in $documents) {
        Invoke-OpenSearch -Method "PUT" -Path "$indexName/_doc/$($document.productId)?refresh=true" -Body $document | Out-Null
    }
    return [pscustomobject]@{ indexName = $indexName; readAlias = $readAlias; indexedDocumentCount = $documents.Count }
}

function Write-JsonFile {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Path)
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
        [Parameter(Mandatory = $true)][string] $ReadPath,
        [Parameter(Mandatory = $true)][string] $ScenarioName,
        [string] $ScenarioOpenSearchUrl = $OpenSearchUrl,
        [int] $ScenarioFailureThreshold = $FailureThreshold,
        [int] $ScenarioOpenWaitMs = $OpenWaitMs
    )

    Stop-SmokePortOwner
    $stdoutPath = Join-Path $tempResultDir "$ScenarioName-app-stdout.log"
    $stderrPath = Join-Path $tempResultDir "$ScenarioName-app-stderr.log"
    $env:GRADLE_USER_HOME = "C:\gradle-cache\readpath-lab-circuit-breaker"

    $bootArgs = @(
        "--server.port=$AppPort",
        "--readpath.product-search.read-path=$ReadPath",
        "--readpath.product-search.baseline.products-table=products",
        "--readpath.product-search.baseline.product-options-table=product_options_moderate_skew",
        "--readpath.product-search.open-search.base-url=$ScenarioOpenSearchUrl",
        "--readpath.product-search.open-search.index-alias=$readAlias",
        "--readpath.product-search.open-search.timeout-ms=$TimeoutMs",
        "--readpath.product-search.open-search.circuit-breaker.enabled=true",
        "--readpath.product-search.open-search.circuit-breaker.failure-threshold=$ScenarioFailureThreshold",
        "--readpath.product-search.open-search.circuit-breaker.open-wait-ms=$ScenarioOpenWaitMs",
        "--readpath.product-search.open-search.circuit-breaker.half-open-permitted-calls=$HalfOpenPermittedCalls"
    ) -join " "

    $process = Start-Process `
        -FilePath (Join-Path $repoRoot "gradlew.bat") `
        -ArgumentList @("--no-daemon", "--max-workers=1", "bootRun", "--args=`"$bootArgs`"") `
        -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden `
        -PassThru

    return [pscustomobject]@{ process = $process; stdoutPath = $stdoutPath; stderrPath = $stderrPath; readPath = $ReadPath; openSearchUrl = $ScenarioOpenSearchUrl }
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
        return [pscustomobject]@{ statusCode = [int] $response.StatusCode; body = $response.Content; json = $response.Content | ConvertFrom-Json }
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
        return [pscustomObject]@{ statusCode = $statusCode; body = $body; json = $null }
    }
}

function Get-LogCounts {
    param([string] $StdoutPath)
    $logText = ""
    if (Test-Path $StdoutPath) {
        $logText = Get-Content -Raw $StdoutPath
        if ($null -eq $logText) {
            $logText = ""
        }
    }
    return [pscustomobject]@{
        fallbackLogCount = ([regex]::Matches($logText, "product_search_opensearch_fallback")).Count
        fallbackSuccessLogCount = ([regex]::Matches($logText, "product_search_db_fallback_success")).Count
        timeoutLogCount = ([regex]::Matches($logText, "reason=TIMEOUT")).Count
        connectionFailureLogCount = ([regex]::Matches($logText, "reason=CONNECTION_FAILURE")).Count
        http5xxLogCount = ([regex]::Matches($logText, "reason=HTTP_5XX")).Count
        circuitOpenFallbackLogCount = ([regex]::Matches($logText, "reason=CIRCUIT_OPEN")).Count
        circuitBreakerOpenCount = ([regex]::Matches($logText, "product_search_opensearch_circuit_breaker_open")).Count
        shortCircuitedRequestCount = ([regex]::Matches($logText, "product_search_opensearch_circuit_breaker_short_circuit")).Count
        halfOpenAttemptCount = ([regex]::Matches($logText, "product_search_opensearch_circuit_breaker_half_open_attempt")).Count
        halfOpenSuccessCount = ([regex]::Matches($logText, "product_search_opensearch_circuit_breaker_closed")).Count
        halfOpenFailureCount = ([regex]::Matches($logText, "product_search_opensearch_circuit_breaker_half_open_failure")).Count
    }
}

function New-ScenarioResult {
    param([string] $ScenarioName, [string] $ReadPath, [object[]] $Responses, [object] $Counts, [int] $ExpectedStatus = 200)
    $lastResponse = $Responses[-1]
    $shapeMatches = $lastResponse.statusCode -eq 200 -and $null -ne $lastResponse.json -and $null -ne $lastResponse.json.items -and $null -ne $lastResponse.json.page
    return [pscustomobject]@{
        scenario = $ScenarioName
        readPath = $ReadPath
        statusCodes = @($Responses | ForEach-Object { $_.statusCode })
        expectedStatusCode = $ExpectedStatus
        itemCount = $(if ($shapeMatches) { @($lastResponse.json.items).Count } else { 0 })
        responseShapeMatches = $shapeMatches
        fallbackLogCount = $Counts.fallbackLogCount
        fallbackSuccessLogCount = $Counts.fallbackSuccessLogCount
        timeoutLogCount = $Counts.timeoutLogCount
        openSearchFailureCount = $Counts.connectionFailureLogCount + $Counts.timeoutLogCount + $Counts.http5xxLogCount
        circuitOpenFallbackLogCount = $Counts.circuitOpenFallbackLogCount
        circuitBreakerOpenCount = $Counts.circuitBreakerOpenCount
        shortCircuitedRequestCount = $Counts.shortCircuitedRequestCount
        halfOpenAttemptCount = $Counts.halfOpenAttemptCount
        halfOpenSuccessCount = $Counts.halfOpenSuccessCount
        halfOpenFailureCount = $Counts.halfOpenFailureCount
        result = $(if ((@($Responses | Where-Object { $_.statusCode -ne $ExpectedStatus }).Count -eq 0)) { "pass" } else { "fail" })
        responseBody = $lastResponse.body
    }
}

function Invoke-BasicScenario {
    param(
        [Parameter(Mandatory = $true)][string] $ScenarioName,
        [Parameter(Mandatory = $true)][string] $ReadPath,
        [string] $ScenarioOpenSearchUrl = $OpenSearchUrl,
        [string] $RequestPath = $queryPath,
        [int] $ExpectedStatus = 200,
        [int] $RequestCount = 1,
        [int] $ScenarioFailureThreshold = $FailureThreshold
    )
    $app = $null
    try {
        $app = Start-SmokeApp -ReadPath $ReadPath -ScenarioName $ScenarioName -ScenarioOpenSearchUrl $ScenarioOpenSearchUrl -ScenarioFailureThreshold $ScenarioFailureThreshold
        Wait-AppReady | Out-Null
        $responses = @()
        for ($i = 0; $i -lt $RequestCount; $i++) {
            $responses += Invoke-AppRequest -Path $RequestPath
        }
        Stop-SmokeApp -App $app
        $counts = Get-LogCounts -StdoutPath $app.stdoutPath
        $result = New-ScenarioResult -ScenarioName $ScenarioName -ReadPath $ReadPath -Responses $responses -Counts $counts -ExpectedStatus $ExpectedStatus
        $app = $null
        return $result
    }
    finally {
        Stop-SmokeApp -App $app
    }
}

function Invoke-HalfOpenScenario {
    param([Parameter(Mandatory = $true)][string] $ScenarioName, [Parameter(Mandatory = $true)][bool] $RecoverOpenSearch)
    $app = $null
    try {
        $app = Start-SmokeApp -ReadPath "opensearch" -ScenarioName $ScenarioName -ScenarioFailureThreshold 1 -ScenarioOpenWaitMs $OpenWaitMs
        Wait-AppReady | Out-Null
        Stop-OpenSearchSmokeService
        $responses = @()
        $responses += Invoke-AppRequest -Path $queryPath
        Start-Sleep -Milliseconds ($OpenWaitMs + 250)
        if ($RecoverOpenSearch) {
            Start-OpenSearchSmokeService
            Wait-OpenSearchHealth | Out-Null
            Start-Sleep -Seconds 3
            $responses += Invoke-AppRequest -Path $queryPath
        }
        else {
            $responses += Invoke-AppRequest -Path $queryPath
            $responses += Invoke-AppRequest -Path $queryPath
            Start-OpenSearchSmokeService
            Wait-OpenSearchHealth | Out-Null
        }
        Stop-SmokeApp -App $app
        $counts = Get-LogCounts -StdoutPath $app.stdoutPath
        $result = New-ScenarioResult -ScenarioName $ScenarioName -ReadPath "opensearch" -Responses $responses -Counts $counts
        $app = $null
        return $result
    }
    finally {
        Start-OpenSearchSmokeService
        Stop-SmokeApp -App $app
    }
}

Push-Location $repoRoot
$success = $false
try {
    New-Item -ItemType Directory -Force -Path $tempResultDir | Out-Null

    Write-Host "Starting PostgreSQL and OpenSearch smoke services"
    docker compose up -d postgres | Out-Null
    Start-OpenSearchSmokeService
    $health = Wait-OpenSearchHealth

    Write-Host "Applying PostgreSQL schemas and preparing circuit breaker smoke data"
    Invoke-PsqlFile -SqlPath $outboxSchemaPath | Out-Null
    Invoke-PsqlFile -SqlPath $productOptionsSchemaPath | Out-Null
    $prepareResult = Invoke-PsqlFile -SqlPath $prepareSqlPath -TuplesOnly | ConvertFrom-Json

    Write-Host "Creating OpenSearch circuit breaker smoke index"
    $openSearchSetup = Initialize-OpenSearchSmokeIndex

    Write-Host "Running closed state OpenSearch success smoke"
    $closedScenario = Invoke-BasicScenario -ScenarioName "closed-state-search-success" -ReadPath "opensearch"

    Write-Host "Running repeated failure open transition + short-circuit smoke"
    $openScenario = Invoke-BasicScenario `
        -ScenarioName "repeated-failure-open-short-circuit" `
        -ReadPath "opensearch" `
        -ScenarioOpenSearchUrl "http://127.0.0.1:1" `
        -RequestCount ($FailureThreshold + 1)

    Write-Host "Running half-open recovery success smoke"
    $halfOpenSuccessScenario = Invoke-HalfOpenScenario -ScenarioName "half-open-recovery-success" -RecoverOpenSearch $true

    Write-Host "Running half-open failure reopen smoke"
    $halfOpenFailureScenario = Invoke-HalfOpenScenario -ScenarioName "half-open-failure-reopen" -RecoverOpenSearch $false

    Write-Host "Running non-fallback validation error smoke"
    $validationScenario = Invoke-BasicScenario `
        -ScenarioName "non-fallback-validation-error" `
        -ReadPath "opensearch" `
        -ScenarioOpenSearchUrl "http://127.0.0.1:1" `
        -RequestPath $invalidQueryPath `
        -ExpectedStatus 400

    Write-Host "Running flag off DB path smoke"
    $dbScenario = Invoke-BasicScenario -ScenarioName "flag-off-db" -ReadPath "db"

    $fallbackCount = $openScenario.fallbackLogCount + $halfOpenSuccessScenario.fallbackLogCount + $halfOpenFailureScenario.fallbackLogCount
    $fallbackSuccessCount = $openScenario.fallbackSuccessLogCount + $halfOpenSuccessScenario.fallbackSuccessLogCount + $halfOpenFailureScenario.fallbackSuccessLogCount
    $circuitBreakerOpenCount = $openScenario.circuitBreakerOpenCount + $halfOpenSuccessScenario.circuitBreakerOpenCount + $halfOpenFailureScenario.circuitBreakerOpenCount
    $shortCircuitedRequestCount = $openScenario.shortCircuitedRequestCount + $halfOpenSuccessScenario.shortCircuitedRequestCount + $halfOpenFailureScenario.shortCircuitedRequestCount
    $halfOpenAttemptCount = $halfOpenSuccessScenario.halfOpenAttemptCount + $halfOpenFailureScenario.halfOpenAttemptCount
    $halfOpenSuccessCount = $halfOpenSuccessScenario.halfOpenSuccessCount + $halfOpenFailureScenario.halfOpenSuccessCount
    $halfOpenFailureCount = $halfOpenSuccessScenario.halfOpenFailureCount + $halfOpenFailureScenario.halfOpenFailureCount
    $openSearchFailureCount = $openScenario.openSearchFailureCount + $halfOpenSuccessScenario.openSearchFailureCount + $halfOpenFailureScenario.openSearchFailureCount
    $timeoutCount = $openScenario.timeoutLogCount + $halfOpenSuccessScenario.timeoutLogCount + $halfOpenFailureScenario.timeoutLogCount

    $metrics = [pscustomobject]@{
        circuitBreakerEnabled = $true
        failureThreshold = $FailureThreshold
        openWaitMs = $OpenWaitMs
        halfOpenPermittedCalls = $HalfOpenPermittedCalls
        finalCircuitBreakerState = "scenario-local; closed/open states are validated per app run"
        closedStateSearchSuccessResult = $closedScenario.result
        openTransitionResult = $(if ($openScenario.circuitBreakerOpenCount -ge 1) { "pass" } else { "fail" })
        shortCircuitFallbackResult = $(if ($openScenario.shortCircuitedRequestCount -ge 1 -and $openScenario.circuitOpenFallbackLogCount -ge 1) { "pass" } else { "fail" })
        halfOpenRecoveryResult = $(if ($halfOpenSuccessScenario.halfOpenAttemptCount -ge 1 -and $halfOpenSuccessScenario.halfOpenSuccessCount -ge 1) { "pass" } else { "fail" })
        halfOpenFailureResult = $(if ($halfOpenFailureScenario.halfOpenAttemptCount -ge 1 -and $halfOpenFailureScenario.halfOpenFailureCount -ge 1) { "pass" } else { "fail" })
        nonFallbackValidationErrorResult = $validationScenario.result
        flagOffDbPathResult = $dbScenario.result
        fallbackCount = $fallbackCount
        fallbackSuccessCount = $fallbackSuccessCount
        circuitBreakerOpenCount = $circuitBreakerOpenCount
        shortCircuitedRequestCount = $shortCircuitedRequestCount
        halfOpenAttemptCount = $halfOpenAttemptCount
        halfOpenSuccessCount = $halfOpenSuccessCount
        halfOpenFailureCount = $halfOpenFailureCount
        openSearchFailureCount = $openSearchFailureCount
        timeoutCount = $timeoutCount
        k6Run = $false
    }

    if ($closedScenario.result -ne "pass" -or -not $closedScenario.responseShapeMatches -or $closedScenario.fallbackLogCount -ne 0 -or $closedScenario.shortCircuitedRequestCount -ne 0) {
        throw "Closed state Search success smoke failed"
    }
    if ($openScenario.result -ne "pass" -or $openScenario.circuitBreakerOpenCount -lt 1 -or $openScenario.shortCircuitedRequestCount -lt 1 -or $openScenario.circuitOpenFallbackLogCount -lt 1) {
        throw "Open transition or short-circuit smoke failed"
    }
    if ($halfOpenSuccessScenario.result -ne "pass" -or $halfOpenSuccessScenario.halfOpenAttemptCount -lt 1 -or $halfOpenSuccessScenario.halfOpenSuccessCount -lt 1) {
        throw "Half-open recovery success smoke failed"
    }
    if ($halfOpenFailureScenario.result -ne "pass" -or $halfOpenFailureScenario.halfOpenAttemptCount -lt 1 -or $halfOpenFailureScenario.halfOpenFailureCount -lt 1) {
        throw "Half-open failure reopen smoke failed"
    }
    if ($validationScenario.statusCodes[0] -ne 400 -or $validationScenario.fallbackLogCount -ne 0 -or $validationScenario.circuitBreakerOpenCount -ne 0) {
        throw "Non-fallback validation error smoke failed"
    }
    if ($dbScenario.result -ne "pass" -or -not $dbScenario.responseShapeMatches -or $dbScenario.fallbackLogCount -ne 0 -or $dbScenario.shortCircuitedRequestCount -ne 0) {
        throw "Flag off DB path smoke failed"
    }

    Write-JsonFile -Value $prepareResult -Path (Join-Path $tempResultDir "prepare-result.json")
    Write-JsonFile -Value $openSearchSetup -Path (Join-Path $tempResultDir "opensearch-smoke-index-result.json")
    Write-JsonFile -Value $closedScenario -Path (Join-Path $tempResultDir "closed-state-search-success-result.json")
    Write-JsonFile -Value $openScenario -Path (Join-Path $tempResultDir "open-transition-short-circuit-result.json")
    Write-JsonFile -Value $halfOpenSuccessScenario -Path (Join-Path $tempResultDir "half-open-recovery-success-result.json")
    Write-JsonFile -Value $halfOpenFailureScenario -Path (Join-Path $tempResultDir "half-open-failure-reopen-result.json")
    Write-JsonFile -Value $validationScenario -Path (Join-Path $tempResultDir "non-fallback-validation-result.json")
    Write-JsonFile -Value $dbScenario -Path (Join-Path $tempResultDir "flag-off-db-result.json")
    Write-JsonFile -Value $metrics -Path (Join-Path $tempResultDir "circuit-breaker-metrics.json")

    $summary = @"
# OpenSearch Circuit Breaker Smoke Summary

- PostgreSQL target: docker compose postgres/readpath_lab
- OpenSearch URL: $OpenSearchUrl
- OpenSearch image: $OpenSearchImage
- Smoke index: $indexName
- Smoke read alias: $readAlias
- Read path flag: readpath.product-search.read-path
- Default read path: db
- Circuit breaker enabled: true
- Failure threshold: $FailureThreshold
- Open wait ms: $OpenWaitMs
- Half-open permitted calls: $HalfOpenPermittedCalls
- Timeout ms: $TimeoutMs
- Final smoke status: pass

| metric | value |
|---|---:|
| closed state Search success result | $($closedScenario.result) |
| open transition result | $($metrics.openTransitionResult) |
| short-circuit fallback result | $($metrics.shortCircuitFallbackResult) |
| half-open recovery result | $($metrics.halfOpenRecoveryResult) |
| half-open failure result | $($metrics.halfOpenFailureResult) |
| non-fallback validation error result | $($validationScenario.result) |
| flag off DB path result | $($dbScenario.result) |
| fallback count | $fallbackCount |
| fallback success count | $fallbackSuccessCount |
| OpenSearch failure count | $openSearchFailureCount |
| timeout count | $timeoutCount |
| circuit breaker open count | $circuitBreakerOpenCount |
| short-circuited request count | $shortCircuitedRequestCount |
| half-open attempt count | $halfOpenAttemptCount |
| half-open success count | $halfOpenSuccessCount |
| half-open failure count | $halfOpenFailureCount |

This smoke result is not a k6 benchmark, production readiness claim, or production SLA/SLO.
"@

    $summary | Set-Content -Encoding UTF8 (Join-Path $tempResultDir "circuit-breaker-summary.md")

    Move-Item -LiteralPath $tempResultDir -Destination $resultDir -Force
    $success = $true

    Write-Host "PASS: OpenSearch circuit breaker smoke validation completed"
    Write-Host "Result artifacts: $resultDir"
}
catch {
    if (Test-Path $tempResultDir) {
        "FAILED/PARTIAL: $($_.Exception.Message)" | Set-Content -Encoding UTF8 (Join-Path $tempResultDir "FAILED_PARTIAL.txt")
    }
    throw
}
finally {
    if (-not $success -and (Test-Path $tempResultDir)) {
        Write-Host "Partial artifacts retained at $tempResultDir"
    }
    Pop-Location
}
