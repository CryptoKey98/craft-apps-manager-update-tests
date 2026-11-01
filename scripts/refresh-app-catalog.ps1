$ErrorActionPreference = 'Stop'
function Run-Catalog {
    & ./tools/app-release-catalog-tool.exe @args
    if ($LASTEXITCODE -ne 0) { throw "Catalog command failed: $($args[0])" }
}
function Invoke-CatalogBackfill {
    param([scriptblock]$GetPending, [scriptblock]$Inspect, [scriptblock]$Publish, [datetime]$Deadline)
    while ([datetime]::UtcNow -lt $Deadline) {
        $remaining = & $GetPending
        if ($remaining -eq 0) { Write-Host 'No unattempted installers remain in this refresh.'; return }
        if ($remaining -lt 0) { throw 'Invalid pending installer count' }
        $budget = [Math]::Min(8, $remaining)
        Write-Host "Inspecting $budget of $remaining unverified installers."
        & $Inspect $budget
        & $Publish
        $after = & $GetPending
        if ($after -ge $remaining) { throw 'Inspection checkpoint did not advance; stopping safely' }
    }
    Write-Host 'Runtime budget reached; completed results are saved for the next refresh.'
}
$expected = $env:CATALOG_TOOL_SHA256
$actual = (Get-FileHash ./tools/app-release-catalog-tool.exe -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -cne $expected) { throw 'Publisher tool checksum mismatch' }
$runStarted = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$deadline = [datetime]::UtcNow.AddMinutes(40)
$checkpoint = @()
if (Test-Path publisher/discovery.json) { $checkpoint = @('--checkpoint','publisher/discovery.json') }
Run-Catalog enroll --repositories app-catalog/repositories.json --out app-catalog/repositories.json
Run-Catalog discover --repositories app-catalog/repositories.json @checkpoint --out publisher/discovery.json
if ([string]::IsNullOrWhiteSpace($env:APP_CATALOG_TEST_SIGNING_KEY)) { throw 'Missing dedicated test signing secret' }
$keyFile = Join-Path $env:RUNNER_TEMP "catalog-test-key-$([guid]::NewGuid()).hex"
function Publish-Catalog {
    $previous = @()
    $evidence = @()
    if (Test-Path publisher/bundle.json) { $previous = @('--previous','publisher/bundle.json') }
    if (Test-Path publisher/inspection.json) { $evidence = @('--evidence','publisher/inspection.json') }
    Run-Catalog aggregate --discovery publisher/discovery.json @previous @evidence --out publisher/bundle.json
    Run-Catalog sign --input publisher/bundle.json --key-file $keyFile --key-id internal-test-20261101 --out v1
    Run-Catalog verify --source source.json --index v1/index.json --objects v1/apps
    git add -- v1 publisher app-catalog
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage catalog checkpoint' }
    git diff --cached --quiet
    if ($LASTEXITCODE -eq 1) {
        git commit -m 'Refresh internal app release catalog'
        if ($LASTEXITCODE -ne 0) { throw 'Catalog commit failed' }
        git push origin HEAD:app-catalog-internal
        if ($LASTEXITCODE -ne 0) { throw 'Catalog push failed' }
    } elseif ($LASTEXITCODE -ne 0) { throw 'Could not inspect catalog changes' }
}
function Get-PendingCount {
    $extra = @()
    if (Test-Path publisher/inspection.json) { $extra = @('--checkpoint','publisher/inspection.json') }
    $output = Run-Catalog pending-count --discovery publisher/discovery.json --previous publisher/bundle.json @extra --since $runStarted
    $count = 0
    if (-not [int]::TryParse([string]$output,[ref]$count) -or $count -lt 0) { throw 'Invalid pending installer count' }
    return $count
}
try {
    [IO.File]::WriteAllText($keyFile, $env:APP_CATALOG_TEST_SIGNING_KEY.Trim(), [Text.Encoding]::ASCII)
    Remove-Item Env:APP_CATALOG_TEST_SIGNING_KEY
    git config user.name 'github-actions[bot]'
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure catalog commit author' }
    git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure catalog commit author' }
    # Publish release metadata first, then preserve each verified inspection batch.
    Publish-Catalog
    Invoke-CatalogBackfill -Deadline $deadline -GetPending { Get-PendingCount } -Inspect {
        param($budget)
        $extra = @()
        if (Test-Path publisher/inspection.json) { $extra = @('--checkpoint','publisher/inspection.json') }
        Run-Catalog inspect-pending --discovery publisher/discovery.json --previous publisher/bundle.json @extra --max-packages $budget --staging "$env:RUNNER_TEMP/catalog-inspection" --out publisher/inspection.json
    } -Publish { Publish-Catalog }
} finally {
    if (Test-Path -LiteralPath $keyFile) { Remove-Item -LiteralPath $keyFile -Force }
}
