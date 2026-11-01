$ErrorActionPreference = 'Stop'
function Run-Catalog {
    & ./tools/app-release-catalog-tool.exe @args
    if ($LASTEXITCODE -ne 0) { throw "Catalog command failed: $($args[0])" }
}
$expected = $env:CATALOG_TOOL_SHA256
$actual = (Get-FileHash ./tools/app-release-catalog-tool.exe -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -cne $expected) { throw 'Publisher tool checksum mismatch' }
$previous = @()
$checkpoint = @()
$inspection = @()
if (Test-Path publisher/bundle.json) { $previous = @('--previous','publisher/bundle.json') }
if (Test-Path publisher/discovery.json) { $checkpoint = @('--checkpoint','publisher/discovery.json') }
if (Test-Path publisher/inspection.json) { $inspection = @('--checkpoint','publisher/inspection.json') }
Run-Catalog discover --repositories app-catalog/repositories.json @checkpoint --out publisher/discovery.json
Run-Catalog inspect-pending --discovery publisher/discovery.json @previous @inspection --max-packages 2 --staging "$env:RUNNER_TEMP/catalog-inspection" --out publisher/inspection.json
Run-Catalog aggregate --discovery publisher/discovery.json @previous --evidence publisher/inspection.json --out publisher/bundle.json
if ([string]::IsNullOrWhiteSpace($env:APP_CATALOG_TEST_SIGNING_KEY)) { throw 'Missing dedicated test signing secret' }
$keyFile = Join-Path $env:RUNNER_TEMP "catalog-test-key-$([guid]::NewGuid()).hex"
try {
    [IO.File]::WriteAllText($keyFile, $env:APP_CATALOG_TEST_SIGNING_KEY.Trim(), [Text.Encoding]::ASCII)
    Remove-Item Env:APP_CATALOG_TEST_SIGNING_KEY
    Run-Catalog sign --input publisher/bundle.json --key-file $keyFile --key-id internal-test-20261101 --out v1
} finally {
    if (Test-Path -LiteralPath $keyFile) { Remove-Item -LiteralPath $keyFile -Force }
}
Run-Catalog verify --source source.json --index v1/index.json --objects v1/apps
# Commit the complete object set and root together; no app release is created.
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add -- v1 publisher
git diff --cached --quiet
if ($LASTEXITCODE -eq 1) {
    git commit -m 'Refresh internal app release catalog'
    if ($LASTEXITCODE -ne 0) { throw 'Catalog commit failed' }
    git push origin HEAD:app-catalog-internal
    if ($LASTEXITCODE -ne 0) { throw 'Catalog push failed' }
} elseif ($LASTEXITCODE -ne 0) { throw 'Could not inspect catalog changes' }
