param(
    [ValidateSet("all", "products_uniform", "products_moderate_skew", "products_high_skew")]
    [string] $Profile = "products_moderate_skew"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$experimentDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $experimentDir "..\..\..")
$sqlPath = Join-Path $experimentDir "product_options_exists_rewrite_comparison.sql"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

if ($Profile -eq "all") {
    $profiles = @("products_uniform", "products_moderate_skew", "products_high_skew")
} else {
    $profiles = @($Profile)
}

function Get-ProductOptionsTable {
    param([string] $ProductsTable)

    switch ($ProductsTable) {
        "products_uniform" { "product_options_uniform" }
        "products_moderate_skew" { "product_options_moderate_skew" }
        "products_high_skew" { "product_options_high_skew" }
        default { throw "Unsupported products profile: $ProductsTable" }
    }
}

Push-Location $repoRoot
try {
    foreach ($productsTable in $profiles) {
        $productOptionsTable = Get-ProductOptionsTable -ProductsTable $productsTable
        $resultDir = Join-Path $experimentDir "results\$productsTable"
        New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

        $outputFile = Join-Path $resultDir "$($productsTable)_product_options_exists_rewrite_comparison_$timestamp.txt"

        Write-Host "Running product_options EXISTS rewrite comparison for products_table=$productsTable product_options_table=$productOptionsTable"
        Get-Content -Raw $sqlPath |
            docker compose exec -T postgres psql -U readpath -d readpath_lab -v products_table=$productsTable -v product_options_table=$productOptionsTable |
            Tee-Object -FilePath $outputFile

        if ($LASTEXITCODE -ne 0) {
            throw "psql failed for products_table=$productsTable product_options_table=$productOptionsTable with exit code $LASTEXITCODE"
        }

        Write-Host "Saved $outputFile"
    }
} finally {
    Pop-Location
}
