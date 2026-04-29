param(
    [ValidateSet(
        "backfill",
        "explain",
        "validate-cheap",
        "validate-product-id-set",
        "validate-api-fields",
        "validate-signature-count",
        "validate-equivalence-b1",
        "validate-equivalence-b2",
        "validate-equivalence-b3",
        "validate-all"
    )]
    [string] $Action = "backfill"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$experimentDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $experimentDir "..\..\..")
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$resultDir = Join-Path $experimentDir "results\$timestamp"

$backfillSqlPath = Join-Path $experimentDir "product_search_documents_moderate_skew.sql"
$explainSqlPath = Join-Path $experimentDir "explain-product-search-documents-moderate-skew.sql"

$validationActions = [ordered]@{
    "validate-cheap" = @{
        SqlPath = Join-Path $experimentDir "validate-product-search-documents-moderate-skew-cheap.sql"
        OutputName = "product_search_documents_moderate_skew_validate_cheap"
    }
    "validate-product-id-set" = @{
        SqlPath = Join-Path $experimentDir "validate-product-search-documents-moderate-skew-product-id-set.sql"
        OutputName = "product_search_documents_moderate_skew_validate_product_id_set"
    }
    "validate-api-fields" = @{
        SqlPath = Join-Path $experimentDir "validate-product-search-documents-moderate-skew-api-fields.sql"
        OutputName = "product_search_documents_moderate_skew_validate_api_fields"
    }
    "validate-signature-count" = @{
        SqlPath = Join-Path $experimentDir "validate-product-search-documents-moderate-skew-signature-count.sql"
        OutputName = "product_search_documents_moderate_skew_validate_signature_count"
    }
    "validate-equivalence-b1" = @{
        SqlPath = Join-Path $experimentDir "validate-product-search-documents-moderate-skew-equivalence-b1.sql"
        OutputName = "product_search_documents_moderate_skew_validate_equivalence_b1"
    }
    "validate-equivalence-b2" = @{
        SqlPath = Join-Path $experimentDir "validate-product-search-documents-moderate-skew-equivalence-b2.sql"
        OutputName = "product_search_documents_moderate_skew_validate_equivalence_b2"
    }
    "validate-equivalence-b3" = @{
        SqlPath = Join-Path $experimentDir "validate-product-search-documents-moderate-skew-equivalence-b3.sql"
        OutputName = "product_search_documents_moderate_skew_validate_equivalence_b3"
    }
}

function Invoke-ExperimentSql {
    param(
        [string] $SqlPath,
        [string] $OutputFile
    )

    $tempOutputFile = "$OutputFile.tmp"
    if (Test-Path $tempOutputFile) {
        Remove-Item -LiteralPath $tempOutputFile -Force
    }

    Write-Host "Running $SqlPath"
    Get-Content -Raw $SqlPath |
        docker compose exec -T postgres psql -U readpath -d readpath_lab |
        Tee-Object -FilePath $tempOutputFile

    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $tempOutputFile) {
            Remove-Item -LiteralPath $tempOutputFile -Force
        }
        throw "psql failed for $SqlPath with exit code $LASTEXITCODE"
    }

    Move-Item -LiteralPath $tempOutputFile -Destination $OutputFile -Force
    Write-Host "Saved $OutputFile"
}

Push-Location $repoRoot
try {
    New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

    if ($Action -eq "backfill") {
        $backfillOutput = Join-Path $resultDir "product_search_documents_moderate_skew_backfill_$timestamp.txt"
        Invoke-ExperimentSql -SqlPath $backfillSqlPath -OutputFile $backfillOutput
    }

    if ($validationActions.Contains($Action)) {
        $validationAction = $validationActions[$Action]
        $validationOutput = Join-Path $resultDir "$($validationAction.OutputName)_$timestamp.txt"
        Invoke-ExperimentSql -SqlPath $validationAction.SqlPath -OutputFile $validationOutput
    }

    if ($Action -eq "validate-all") {
        foreach ($validationActionName in $validationActions.Keys) {
            $validationAction = $validationActions[$validationActionName]
            $validationOutput = Join-Path $resultDir "$($validationAction.OutputName)_$timestamp.txt"
            Invoke-ExperimentSql -SqlPath $validationAction.SqlPath -OutputFile $validationOutput
        }
    }

    if ($Action -eq "explain") {
        $explainOutput = Join-Path $resultDir "product_search_documents_moderate_skew_explain_$timestamp.txt"
        Invoke-ExperimentSql -SqlPath $explainSqlPath -OutputFile $explainOutput
    }
} finally {
    Pop-Location
}
