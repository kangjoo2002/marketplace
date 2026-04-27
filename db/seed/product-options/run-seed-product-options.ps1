param(
    [ValidateSet("all", "uniform", "moderate-skew", "high-skew")]
    [string] $Profile = "moderate-skew",

    [long] $ChunkSize = 500000
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..\..\..")
$schemaSqlPath = Join-Path $scriptDir "product_options_schema.sql"
$seedSqlPath = Join-Path $scriptDir "seed_product_options.sql"
$verifySqlPath = Join-Path $scriptDir "verify_product_options_distribution.sql"
$resultDir = Join-Path $repoRoot "db\seed\results"

if ($Profile -eq "all") {
    $profiles = @("uniform", "moderate-skew", "high-skew")
} else {
    $profiles = @($Profile)
}

function Convert-ProfileToArtifactPrefix {
    param([string] $SeedProfile)

    switch ($SeedProfile) {
        "uniform" { "uniform" }
        "moderate-skew" { "moderate_skew" }
        "high-skew" { "high_skew" }
        default { throw "Unsupported seed profile: $SeedProfile" }
    }
}

New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

Push-Location $repoRoot
try {
    Write-Host "Creating product_options schema"
    Get-Content -Raw $schemaSqlPath |
        docker compose exec -T postgres psql -U readpath -d readpath_lab |
        Tee-Object -FilePath (Join-Path $resultDir "product_options_schema_setup.log")

    if ($LASTEXITCODE -ne 0) {
        throw "product_options schema setup failed with exit code $LASTEXITCODE"
    }

    foreach ($seedProfile in $profiles) {
        $artifactPrefix = Convert-ProfileToArtifactPrefix -SeedProfile $seedProfile
        $seedOutputFile = Join-Path $resultDir "$($artifactPrefix)_10m_product_options_seed.log"
        $verifyOutputFile = Join-Path $resultDir "$($artifactPrefix)_10m_product_options_distribution.txt"

        Write-Host "Seeding product_options for profile=$seedProfile chunk_size=$ChunkSize"
        Get-Content -Raw $seedSqlPath |
            docker compose exec -T postgres psql -U readpath -d readpath_lab -v seed_profile=$seedProfile -v chunk_size=$ChunkSize |
            Tee-Object -FilePath $seedOutputFile

        if ($LASTEXITCODE -ne 0) {
            throw "product_options seed failed for profile=$seedProfile with exit code $LASTEXITCODE"
        }

        Write-Host "Verifying product_options distribution for profile=$seedProfile"
        Get-Content -Raw $verifySqlPath |
            docker compose exec -T postgres psql -U readpath -d readpath_lab -v seed_profile=$seedProfile |
            Tee-Object -FilePath $verifyOutputFile

        if ($LASTEXITCODE -ne 0) {
            throw "product_options verification failed for profile=$seedProfile with exit code $LASTEXITCODE"
        }

        Write-Host "Saved $seedOutputFile"
        Write-Host "Saved $verifyOutputFile"
    }
} finally {
    Pop-Location
}
