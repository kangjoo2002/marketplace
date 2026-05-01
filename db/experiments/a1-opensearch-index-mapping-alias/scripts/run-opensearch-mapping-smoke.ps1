param(
    [string] $OpenSearchUrl = $env:OPENSEARCH_URL,
    [string] $OpenSearchImage = $env:OPENSEARCH_IMAGE,
    [string] $IndexPrefix = "products_search_a17_smoke"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($OpenSearchUrl)) {
    $OpenSearchUrl = "http://localhost:9200"
}

if ([string]::IsNullOrWhiteSpace($OpenSearchImage)) {
    $OpenSearchImage = "opensearchproject/opensearch:2.15.0"
}

$OpenSearchUrl = $OpenSearchUrl.TrimEnd("/")

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$experimentDir = Resolve-Path (Join-Path $scriptDir "..")
$nestedMappingPath = Join-Path $experimentDir "mappings\products_v1_nested.json"
$flattenedMappingPath = Join-Path $experimentDir "mappings\products_v1_flattened_candidate.json"
$fixturePath = Join-Path $experimentDir "fixtures\sample-product-options.json"
$nestedNegativeQueryPath = Join-Path $experimentDir "queries\nested-option-filter-query.json"
$nestedPositiveQueryPath = Join-Path $experimentDir "queries\nested-option-filter-positive-query.json"
$flattenedQueryPath = Join-Path $experimentDir "queries\flattened-option-filter-query.json"

$nestedIndex = "$($IndexPrefix)_nested_v1"
$flattenedIndex = "$($IndexPrefix)_flattened_v1"
$readAlias = "$($IndexPrefix)_read"
$writeAlias = "$($IndexPrefix)_write"
$currentAlias = "$($IndexPrefix)_current"

function Invoke-OpenSearch {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Method,
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [string] $BodyPath,
        [object] $Body
    )

    $uri = "$OpenSearchUrl/$($Path.TrimStart('/'))"
    $params = @{
        Method = $Method
        Uri = $uri
    }

    if ($BodyPath) {
        $params["Body"] = Get-Content -Raw $BodyPath
        $params["ContentType"] = "application/json"
    }
    elseif ($null -ne $Body) {
        $params["Body"] = $Body | ConvertTo-Json -Depth 20
        $params["ContentType"] = "application/json"
    }

    Invoke-RestMethod @params
}

function Remove-SmokeIndex {
    param([string] $IndexName)

    try {
        Invoke-OpenSearch -Method "DELETE" -Path $IndexName | Out-Null
        Write-Host "Deleted index $IndexName"
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 404) {
            Write-Host "Index $IndexName did not exist"
            return
        }
        throw
    }
}

function Get-OpenSearchHitCount {
    param([object] $Response)

    if ($null -ne $Response.hits.total.value) {
        return [int] $Response.hits.total.value
    }

    return [int] $Response.hits.total
}

function Write-JsonArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Value,
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $Value | ConvertTo-Json -Depth 50 | Set-Content -Encoding UTF8 $Path
}

Write-Host "Using OpenSearch URL: $OpenSearchUrl"
$healthcheck = Invoke-OpenSearch -Method "GET" -Path "_cluster/health"

Remove-SmokeIndex -IndexName $nestedIndex
Remove-SmokeIndex -IndexName $flattenedIndex

Write-Host "Creating nested index $nestedIndex"
$nestedIndexCreate = Invoke-OpenSearch -Method "PUT" -Path $nestedIndex -BodyPath $nestedMappingPath

Write-Host "Creating aliases for nested index"
$aliasCreate = Invoke-OpenSearch -Method "POST" -Path "_aliases" -Body @{
    actions = @(
        @{ add = @{ index = $nestedIndex; alias = $readAlias } },
        @{ add = @{ index = $nestedIndex; alias = $writeAlias } },
        @{ add = @{ index = $nestedIndex; alias = $currentAlias } }
    )
}
$aliasVerification = Invoke-OpenSearch -Method "GET" -Path "$nestedIndex/_alias"

Write-Host "Indexing sample document into nested index"
$nestedIndexDocument = Invoke-OpenSearch -Method "PUT" -Path "$nestedIndex/_doc/1?refresh=true" -BodyPath $fixturePath

Write-Host "Running nested negative same-row query"
$nestedNegative = Invoke-OpenSearch -Method "POST" -Path "$nestedIndex/_search" -BodyPath $nestedNegativeQueryPath
$nestedNegativeCount = Get-OpenSearchHitCount -Response $nestedNegative

Write-Host "Running nested positive same-row query"
$nestedPositive = Invoke-OpenSearch -Method "POST" -Path "$nestedIndex/_search" -BodyPath $nestedPositiveQueryPath
$nestedPositiveCount = Get-OpenSearchHitCount -Response $nestedPositive

Write-Host "Creating flattened/object candidate index $flattenedIndex"
$flattenedIndexCreate = Invoke-OpenSearch -Method "PUT" -Path $flattenedIndex -BodyPath $flattenedMappingPath

Write-Host "Indexing sample document into flattened/object candidate index"
$flattenedIndexDocument = Invoke-OpenSearch -Method "PUT" -Path "$flattenedIndex/_doc/1?refresh=true" -BodyPath $fixturePath

Write-Host "Running flattened/object negative query"
$flattenedNegative = Invoke-OpenSearch -Method "POST" -Path "$flattenedIndex/_search" -BodyPath $flattenedQueryPath
$flattenedNegativeCount = Get-OpenSearchHitCount -Response $flattenedNegative

if ($nestedNegativeCount -ne 0) {
    throw "FAIL: nested negative query expected 0 hits, got $nestedNegativeCount"
}

if ($nestedPositiveCount -ne 1) {
    throw "FAIL: nested positive query expected 1 hit, got $nestedPositiveCount"
}

if ($flattenedNegativeCount -ne 1) {
    throw "FAIL: flattened/object candidate query expected 1 false-positive hit, got $flattenedNegativeCount"
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$resultDir = Join-Path $experimentDir "results\$timestamp"
New-Item -ItemType Directory -Force $resultDir | Out-Null

Write-JsonArtifact -Value $healthcheck -Path (Join-Path $resultDir "healthcheck-result.json")
Write-JsonArtifact -Value $nestedIndexCreate -Path (Join-Path $resultDir "nested-index-create-result.json")
Write-JsonArtifact -Value $aliasCreate -Path (Join-Path $resultDir "alias-create-result.json")
Write-JsonArtifact -Value $aliasVerification -Path (Join-Path $resultDir "alias-verification-result.json")
Write-JsonArtifact -Value $nestedIndexDocument -Path (Join-Path $resultDir "nested-document-index-result.json")
Write-JsonArtifact -Value $flattenedIndexCreate -Path (Join-Path $resultDir "flattened-index-create-result.json")
Write-JsonArtifact -Value $flattenedIndexDocument -Path (Join-Path $resultDir "flattened-document-index-result.json")
Write-JsonArtifact -Value $nestedNegative -Path (Join-Path $resultDir "nested-negative-query-result.json")
Write-JsonArtifact -Value $nestedPositive -Path (Join-Path $resultDir "nested-positive-query-result.json")
Write-JsonArtifact -Value $flattenedNegative -Path (Join-Path $resultDir "flattened-query-result.json")

$summary = @"
# PR-A17 OpenSearch Mapping Smoke Summary

- OpenSearch URL: $OpenSearchUrl
- OpenSearch image: $OpenSearchImage
- Nested index: $nestedIndex
- Flattened/object candidate index: $flattenedIndex
- Read alias: $readAlias
- Write alias: $writeAlias
- Current alias: $currentAlias

| check | hits | result |
|---|---:|---|
| healthcheck | n/a | PASS |
| nested index creation | n/a | PASS |
| alias creation | n/a | PASS |
| nested sample document indexing | n/a | PASS |
| nested negative BLACK / M / IN_STOCK | $nestedNegativeCount | PASS |
| nested positive BLACK / S / IN_STOCK | $nestedPositiveCount | PASS |
| flattened/object index creation | n/a | PASS |
| flattened/object sample document indexing | n/a | PASS |
| flattened/object negative BLACK / M / IN_STOCK | $flattenedNegativeCount | PASS, false positive demonstrated |

Selected option representation: nested.

This smoke result is not a production capacity or latency claim.
"@

$summary | Set-Content -Encoding UTF8 (Join-Path $resultDir "mapping-smoke-summary.md")

Write-Host "PASS: OpenSearch mapping smoke validation completed"
Write-Host "Result artifacts: $resultDir"
