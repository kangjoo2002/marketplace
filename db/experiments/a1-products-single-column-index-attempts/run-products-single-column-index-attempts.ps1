param(
    [ValidateSet("all", "products_uniform", "products_moderate_skew", "products_high_skew")]
    [string] $Profile = "products_moderate_skew"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$experimentDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $experimentDir "..\..\..")
$sqlPath = Join-Path $experimentDir "products_single_column_index_attempts.sql"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

if ($Profile -eq "all") {
    $profiles = @("products_uniform", "products_moderate_skew", "products_high_skew")
} else {
    $profiles = @($Profile)
}

Push-Location $repoRoot
try {
    foreach ($targetTable in $profiles) {
        $resultDir = Join-Path $experimentDir "results\$targetTable"
        New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

        $outputFile = Join-Path $resultDir "$($targetTable)_single_column_index_attempts_$timestamp.txt"

        Write-Host "Running single-column index attempts for target_table=$targetTable"
        Get-Content -Raw $sqlPath |
            docker compose exec -T postgres psql -U readpath -d readpath_lab -v target_table=$targetTable |
            Tee-Object -FilePath $outputFile

        if ($LASTEXITCODE -ne 0) {
            throw "psql failed for target_table=$targetTable with exit code $LASTEXITCODE"
        }

        Write-Host "Saved $outputFile"
    }
} finally {
    Pop-Location
}
