# Offline checks; run with pwsh -NoProfile -File test-windows-installer.ps1.
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'install-pixie-dust.ps1'
$tokens = $null
$parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
Write-Host 'ok: PowerShell parser'

$testDir = Join-Path ([IO.Path]::GetTempPath()) ('pixie-windows-check-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
try {
    $runner = (Get-Process -Id $PID).Path
    $source = Join-Path $testDir 'missing source with spaces'
    & $runner -NoProfile -File $installer -SourceDir $source -DryRun
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $source)) { throw 'DryRun changed files or failed.' }
    Write-Host 'ok: Windows dry-run is read-only'

    # Load helpers without invoking installation, then simulate downloads locally.
    foreach ($name in @('Invoke-Tool', 'Get-Archive')) {
        $definition = $tree.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        Invoke-Expression $definition.Extent.Text
    }
    $failed = $false
    try { Invoke-Tool $runner @('-NoProfile', '-Command', 'exit 7') }
    catch { $failed = $true }
    if (-not $failed) { throw 'Native failure was ignored.' }

    $script:failTransfer = $true
    function Invoke-WebRequest {
        param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile)
        [IO.File]::WriteAllText($OutFile, 'archive bytes')
        if ($script:failTransfer) { throw 'simulated interrupted transfer' }
    }
    $archive = Join-Path $testDir 'archive.zip'
    $failed = $false
    try { Get-Archive 'https://example.invalid/archive.zip' $archive }
    catch { $failed = $true }
    if (-not $failed -or (Test-Path -LiteralPath $archive) -or
        @(Get-ChildItem -LiteralPath $testDir -Filter '*.part').Count) {
        throw 'Failed transfer left reusable or partial files.'
    }
    $script:failTransfer = $false
    Get-Archive 'https://example.invalid/archive.zip' $archive
    if ([IO.File]::ReadAllText($archive) -ne 'archive bytes') { throw 'Successful download did not persist.' }
    $script:failTransfer = $true
    Get-Archive 'https://example.invalid/archive.zip' $archive
    Write-Host 'ok: native failure propagation, interrupted download cleanup, cached download reuse'
}
finally {
    Remove-Item -LiteralPath $testDir -Recurse -Force
}
Write-Host 'All offline Windows installer checks passed. Native Windows build remains untested.'
