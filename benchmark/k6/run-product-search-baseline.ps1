param(
    [ValidateSet("uniform", "moderate_skew", "high_skew")]
    [string] $Profile = "moderate_skew",

    [string] $BaseUrl = "http://localhost:8080",

    [int] $VUs = 10,

    [string] $WarmupDuration = "30s",

    [string] $Duration = "1m",

    [string] $ResultsRoot = "$PSScriptRoot/results",

    [int] $ExpectedDockerMemoryMiB = 4096
)

$ErrorActionPreference = "Stop"

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

function Invoke-K6Run {
    param(
        [string] $RunName,
        [string] $RunDuration,
        [string] $SummaryPath,
        [switch] $SmokeOnly
    )

    $env:PROFILE = $Profile
    $env:BASE_URL = $BaseUrl
    $env:VUS = "$VUs"
    $env:DURATION = $RunDuration

    if ($SmokeOnly) {
        $env:SMOKE_ONLY = "true"
        Remove-Item Env:SUMMARY_JSON -ErrorAction SilentlyContinue
    } else {
        $env:SMOKE_ONLY = "false"
        if ($SummaryPath) {
            $env:SUMMARY_JSON = $SummaryPath
        } else {
            Remove-Item Env:SUMMARY_JSON -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Running $RunName..."
    k6 run "$PSScriptRoot/product-search-baseline.js"
    if ($LASTEXITCODE -ne 0) {
        throw "$RunName failed with exit code $LASTEXITCODE."
    }
}

function Invoke-SqlValidation {
    $validationSqlPath = Join-Path $PSScriptRoot "product-search-baseline-scenario-validation.sql"
    if (-not (Test-Path $validationSqlPath)) {
        throw "SQL validation script was not found: $validationSqlPath"
    }

    Write-Host "Running SQL scenario validation..."
    $validationCsv = Get-Content -Raw $validationSqlPath |
        docker compose exec -T postgres psql -U readpath -d readpath_lab --csv -q
    if ($LASTEXITCODE -ne 0) {
        throw "SQL scenario validation failed with exit code $LASTEXITCODE."
    }

    $rows = $validationCsv | ConvertFrom-Csv
    if (-not $rows) {
        throw "SQL scenario validation returned no rows."
    }

    $failedRows = @($rows | Where-Object { $_.passes -ne "t" })
    if ($failedRows.Count -gt 0) {
        $failedText = $failedRows | Format-Table -AutoSize | Out-String
        throw "SQL scenario validation did not pass for all profile/scenario rows:`n$failedText"
    }

    $selectedOffsets = @($rows | Select-Object -ExpandProperty selected_b3_offset -Unique)
    if ($selectedOffsets.Count -ne 1 -or $selectedOffsets[0] -ne "10000") {
        throw "Unexpected B3 selected offset from SQL validation: $($selectedOffsets -join ', ')"
    }

    Write-Host "SQL scenario validation passed for all profiles. selected_b3_offset=$($selectedOffsets[0])"
    return $rows
}

function Write-Observations {
    param(
        [string] $SummaryPath,
        [string] $ObservationsPath,
        [string] $Timestamp,
        [object[]] $ValidationRows
    )

    $summary = Get-Content $SummaryPath -Raw | ConvertFrom-Json
    $metrics = $summary.summary.metrics
    $dockerSettings = Read-DockerDesktopSettings

    $p95 = $metrics.http_req_duration.values.'p(95)'
    $throughput = $metrics.http_reqs.values.rate
    $errorRate = $metrics.http_req_failed.values.rate
    $failedChecks = $metrics.checks.values.fails
    $scenarioReturnCounts = @(
        [pscustomobject]@{
            Name = "B1_selective_option_filter"
            Weight = "40%"
            Metric = $metrics.b1_selective_option_filter_returned_count
        },
        [pscustomobject]@{
            Name = "B2_broad_active_option_filter"
            Weight = "40%"
            Metric = $metrics.b2_broad_active_option_filter_returned_count
        },
        [pscustomobject]@{
            Name = "B3_deep_offset_option_filter"
            Weight = "20%"
            Metric = $metrics.b3_deep_offset_option_filter_returned_count
        }
    )
    $littleOrNoData = $false
    $returnCountLines = foreach ($scenario in $scenarioReturnCounts) {
        if ($null -eq $scenario.Metric -or $null -eq $scenario.Metric.values) {
            $littleOrNoData = $true
            "- $($scenario.Name): no returnedCount metric recorded"
        } else {
            $min = $scenario.Metric.values.min
            $avg = $scenario.Metric.values.avg
            $max = $scenario.Metric.values.max
            if ($max -eq 0) {
                $littleOrNoData = $true
            }
            "- $($scenario.Name): returnedCount min=$min, avg=$avg, max=$max"
        }
    }
    $littleOrNoDataText = if ($littleOrNoData) { "yes" } else { "no" }
    $profileValidationRows = @($ValidationRows | Where-Object { $_.profile -eq $Profile } | Sort-Object scenario_name)
    if ($profileValidationRows.Count -ne 3) {
        throw "Expected 3 SQL validation rows for profile=$Profile, found $($profileValidationRows.Count)."
    }

    $validationLines = foreach ($row in $profileValidationRows) {
        "- $($row.scenario_name): matching_count=$($row.matching_count), required_min_count=$($row.required_min_count), passes=$($row.passes)"
    }

    $constantLines = foreach ($scenario in $summary.requestScenarios) {
        $paramText = ($scenario.params.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ", "
        "- $($scenario.name) ($($scenario.weight)%): $paramText"
    }

    $selectedB3Offset = ($profileValidationRows | Where-Object { $_.scenario_name -eq "B3_deep_offset_option_filter" } | Select-Object -First 1).selected_b3_offset
    $selectedB3OffsetReason = ($profileValidationRows | Where-Object { $_.scenario_name -eq "B3_deep_offset_option_filter" } | Select-Object -First 1).selected_b3_offset_reason

    $content = @"
# Product Search Baseline k6 Observations

- profile: $Profile
- timestamp: $Timestamp
- scenario set version: product-search-baseline-v1
- VUs: $VUs
- duration: $Duration
- warm-up duration: $WarmupDuration
- base URL: $BaseUrl
- app execution mode: Gradle bootRun
- Docker memory setting: $($dockerSettings.memoryMiB) MiB
- p95 latency: $p95 ms
- throughput: $throughput req/s
- error rate: $errorRate
- failed checks: $failedChecks
- scenario smoke validation passed: yes
- any scenario returned little or no data: $littleOrNoDataText
- selected B3 offset: $selectedB3Offset
- selected B3 offset reason: $selectedB3OffsetReason
- result artifact path: $SummaryPath

## Scenario Weights

- B1_selective_option_filter: 40%
- B2_broad_active_option_filter: 40%
- B3_deep_offset_option_filter: 20%

## Scenario Constants

$($constantLines -join "`n")

## SQL Validation

$($validationLines -join "`n")

## Scenario Returned Counts

$($returnCountLines -join "`n")

This is a local synthetic benchmark artifact for the baseline API only. Warm-up results are excluded.
"@

    Set-Content -LiteralPath $ObservationsPath -Value $content -Encoding ASCII
}

Assert-K6Installed
Assert-DockerMemorySetting
$validationRows = Invoke-SqlValidation

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$profileResultDir = Join-Path $ResultsRoot "products_$Profile"
New-Item -ItemType Directory -Force -Path $profileResultDir | Out-Null

$summaryPath = Join-Path $profileResultDir "product_search_baseline_${Profile}_${timestamp}_summary.json"
$observationsPath = Join-Path $profileResultDir "product_search_baseline_${Profile}_${timestamp}_observations.md"

Invoke-K6Run -RunName "scenario smoke validation" -RunDuration "1s" -SmokeOnly
Invoke-K6Run -RunName "warm-up run" -RunDuration $WarmupDuration

try {
    Invoke-K6Run -RunName "measured run" -RunDuration $Duration -SummaryPath $summaryPath
    Write-Observations -SummaryPath $summaryPath -ObservationsPath $observationsPath -Timestamp $timestamp -ValidationRows $validationRows
} catch {
    if (Test-Path $summaryPath) {
        $failedSummaryPath = $summaryPath -replace "_summary\.json$", "_failed_summary.json"
        Move-Item -LiteralPath $summaryPath -Destination $failedSummaryPath -Force
        Write-Host "Failed measured summary saved as non-official artifact: $failedSummaryPath"
    }
    throw
}

Write-Host "Measured summary JSON: $summaryPath"
Write-Host "Observations: $observationsPath"
