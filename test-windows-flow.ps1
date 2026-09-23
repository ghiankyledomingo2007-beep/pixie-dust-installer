# Exercise the real setup flow with simulated Windows tools; no installs/network.
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'install-pixie-dust.ps1'
$tokens = $null
$errors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($definition in $tree.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true)) { Invoke-Expression $definition.Extent.Text }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('pixie-flow-' + [Guid]::NewGuid().ToString('N'))
$originalPath = $env:Path
$originalAppConfig = [Environment]::GetEnvironmentVariable('PIXIEDUST_USER_FOLDER', 'Process')
New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:PackageRoot = Join-Path $testRoot 'extracted package'
New-Item -ItemType Directory -Path $script:PackageRoot | Out-Null
Set-Content -LiteralPath (Join-Path $script:PackageRoot 'transform.py') -Value '# simulated transform invocation'
$vs = Join-Path $testRoot 'Visual Studio'
$devShell = Join-Path $vs 'Common7/Tools/Launch-VsDevShell.ps1'
New-Item -ItemType Directory -Path (Split-Path $devShell) -Force | Out-Null
Set-Content -LiteralPath $devShell -Value 'param($Arch, $HostArch, [switch]$SkipAutomaticLocation); Write-Output "dev-shell status"'
$library = Join-Path $testRoot 'skia fixture/out/Release-x64'
New-Item -ItemType Directory -Path $library -Force | Out-Null
Set-Content -LiteralPath (Join-Path $library 'skia.lib') -Value 'fixture'
$fixtureArchive = Join-Path $testRoot 'skia.zip'
Compress-Archive -Path (Join-Path $testRoot 'skia fixture/*') -DestinationPath $fixtureArchive
$DryRun = $false
$NoBuild = $false
$SkipPrerequisites = $false
$Jobs = 2
$UpstreamCommit = '717ab76b2ed9b814fda4b65eb388f6ad480ca4ee'
$UpstreamUrl = 'https://example.invalid/source'

# Replace only external/platform boundaries. Setup ordering, paths, extraction,
# verification, and error propagation use the production functions above.
function Assert-Windows {}
function Start-SetupLog { $script:LogFile = Join-Path $testRoot 'simulated-setup.txt' }
function Find-Git { return (Join-Path $testRoot 'git.exe') }
function Find-Python { return (Join-Path $testRoot 'python.exe') }
function Find-VisualStudio { return $vs }
function Get-Command {
    param($Name, $ErrorAction)
    if ($Name -eq 'cl.exe' -or $script:installedTools) {
        return [pscustomobject]@{ Source = (Join-Path $testRoot $Name) }
    }
}
function Install-Prerequisite {
    param($Id, $Override)
    if ($SkipPrerequisites) { throw "Missing $Id. Install it, then run this installer again." }
    $script:packages.Add($Id)
    $script:installedTools = $true
    Write-Output 'package-manager status must not enter a tool path'
}
function Get-Archive {
    param($Url, $Destination)
    $script:downloads++
    if ($script:scenario -eq 'corrupt-archive') { Set-Content -LiteralPath $Destination -Value 'broken'; return }
    Copy-Item -LiteralPath $fixtureArchive -Destination $Destination
}
function New-AppShortcuts {
    param($binary)
    if (-not (Test-Path -LiteralPath $binary)) { throw 'Shortcut target does not exist.' }
    $script:shortcutTarget = $binary
}
function Invoke-Tool {
    param([string]$Program, [string[]]$Arguments)
    $script:commands.Add(@{ Program = $Program; Arguments = $Arguments })
    if ($Program.EndsWith('git.exe')) {
        if ($Arguments -contains 'clone') {
            $destination = $Arguments[-1]
            foreach ($relative in @('.git', 'src/ver', 'laf/misc')) {
                New-Item -ItemType Directory -Path (Join-Path $destination $relative) -Force | Out-Null
            }
            Set-Content -LiteralPath (Join-Path $destination 'src/ver/info.c') -Value 'source'
            Set-Content -LiteralPath (Join-Path $destination 'README.md') -Value '# Aseprite'
            Set-Content -LiteralPath (Join-Path $destination 'laf/misc/skia-tag.txt') -Value 'm124-08a5439a6b'
        }
        elseif ($Arguments -contains 'rev-parse') {
            if ($script:scenario -eq 'wrong-revision') { return 'other-revision' }
            return $UpstreamCommit
        }
        elseif ($Arguments -contains 'status' -and $script:scenario -eq 'dirty-source') { return ' M source.cpp' }
    }
    elseif ($Program.EndsWith('python.exe')) {
        if ($script:scenario -eq 'transform-failure') { throw 'transform failed' }
        Set-Content -LiteralPath (Join-Path $Arguments[-1] 'README.md') -Value '# Pixie Dust'
    }
    elseif ($Program.EndsWith('cmake.exe') -and $Arguments -contains '--build') {
        if ($script:scenario -eq 'build-failure') { throw 'compiler failed: simulated error' }
        $build = $Arguments[1]
        New-Item -ItemType Directory -Path (Join-Path $build 'bin') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $build 'bin/pixie-dust.exe') -Value 'fixture'
        $flags = "ENABLE_NEWS:BOOL=OFF`nENABLE_UPDATER:BOOL=OFF`nENABLE_WEBSOCKET:BOOL=OFF"
        if ($script:scenario -eq 'wrong-flags') { $flags = $flags.Replace('ENABLE_NEWS:BOOL=OFF', 'ENABLE_NEWS:BOOL=ON') }
        Set-Content -LiteralPath (Join-Path $build 'CMakeCache.txt') -Value $flags
    }
    elseif ($Program.EndsWith('pixie-dust.exe')) {
        if ($Arguments -contains '-b') {
            if ($script:scenario -eq 'app-check-failure') { return }
            $folder = ($Arguments | Where-Object { $_.StartsWith('folder=') }).Substring(7)
            foreach ($name in @('passed.txt', 'check.pixie-dust', 'check.png')) {
                [IO.File]::WriteAllText((Join-Path $folder $name), 'ok')
            }
            return
        }
        if ($script:scenario -eq 'wrong-version') { return 'Wrong app' }
        return 'Pixie Dust test-build'
    }
}

function Reset-Scenario {
    param($Name)
    $script:scenario = $Name
    $script:shortcutTarget = $null
    $script:commands = [Collections.Generic.List[object]]::new()
    $script:packages = [Collections.Generic.List[string]]::new()
    $script:installedTools = $false
    $script:downloads = 0
    $script:SourceDir = Join-Path $testRoot ($Name + ' source with spaces')
    $script:CurrentStep = 'Starting setup'
}

$passed = 0
try {
    Reset-Scenario 'success'
    Invoke-Setup
    if (-not $script:shortcutTarget -or $script:downloads -ne 1) { throw 'Success flow did not finish.' }
    if ([Environment]::GetEnvironmentVariable('PIXIEDUST_USER_FOLDER', 'Process') -ne $originalAppConfig) { throw 'Temporary app config override was not restored.' }
    if ($script:packages -contains 'Microsoft.VisualStudio.2022.BuildTools') { throw 'Existing Visual Studio was reinstalled.' }
    if ($script:packages -notcontains 'Kitware.CMake') { throw 'Missing CMake was not installed separately.' }
    $cmakeCommand = $script:commands | Where-Object { $_.Program.EndsWith('cmake.exe') -and $_.Arguments -contains '-S' }
    if ($cmakeCommand.Arguments -notcontains $SourceDir) { throw 'Source path with spaces was split.' }
    if ($cmakeCommand.Program -match 'status') { throw 'Prerequisite output corrupted the compiler path.' }
    $passed++
    Write-Host 'PASS: complete flow, paths with spaces, existing VS reuse, compiler path isolation'

    $script:commands.Clear()
    $script:shortcutTarget = $null
    Invoke-Setup
    if (($script:commands | Where-Object { $_.Arguments -contains 'clone' }) -or $script:downloads -ne 1) { throw 'Rerun unnecessarily recloned/redownloaded.' }
    $passed++
    Write-Host 'PASS: rerun reuses source and extracted Skia'

    Reset-Scenario 'source-only'
    $NoBuild = $true
    Invoke-Setup
    if ($script:downloads -or $script:shortcutTarget -or $script:packages.Count) { throw 'NoBuild installed build dependencies.' }
    $NoBuild = $false
    $passed++
    Write-Host 'PASS: source-only setup stops before build dependencies'

    foreach ($case in @(
        @('unrelated-folder', 'supported checkout'),
        @('missing-package-file', 'Extract the entire installer ZIP'),
        @('wrong-revision', 'different revision'),
        @('dirty-source', 'local changes'),
        @('transform-failure', 'transform failed'),
        @('corrupt-archive', 'incomplete or damaged'),
        @('build-failure', 'compiler failed'),
        @('wrong-version', 'expected Pixie Dust version'),
        @('wrong-flags', 'ENABLE_NEWS must be OFF'),
        @('app-check-failure', 'save/export/reopen check'),
        @('skip-prerequisites', 'Missing Kitware.CMake')
    )) {
        Reset-Scenario $case[0]
        if ($case[0] -eq 'unrelated-folder') {
            New-Item -ItemType Directory -Path $SourceDir | Out-Null
            Set-Content -LiteralPath (Join-Path $SourceDir 'keep.txt') -Value 'keep me'
        }
        if ($case[0] -in @('wrong-revision', 'dirty-source')) {
            Invoke-Tool (Find-Git) @('clone', $UpstreamUrl, $SourceDir)
        }
        if ($case[0] -eq 'missing-package-file') { Remove-Item -LiteralPath (Join-Path $script:PackageRoot 'transform.py') }
        $SkipPrerequisites = $case[0] -eq 'skip-prerequisites'
        $failure = $null
        try { Invoke-Setup } catch { $failure = $_.Exception.Message }
        if (-not $failure -or ($case[1] -and $failure -notlike ('*' + $case[1] + '*'))) { throw "Incorrect failure for $($case[0]): $failure" }
        if ($script:shortcutTarget) { throw "Created shortcuts after $($case[0]) failure." }
        if ([Environment]::GetEnvironmentVariable('PIXIEDUST_USER_FOLDER', 'Process') -ne $originalAppConfig) { throw 'App config override leaked after failure.' }
        if ($case[0] -eq 'unrelated-folder' -and (Get-Content -LiteralPath (Join-Path $SourceDir 'keep.txt')) -ne 'keep me') { throw 'Existing files changed.' }
        if ($case[0] -eq 'corrupt-archive' -and @(Get-ChildItem -LiteralPath $SourceDir -Recurse -Filter '*.zip' -Force).Count) { throw 'Corrupt archive was retained.' }
        if ($case[0] -eq 'missing-package-file') { Set-Content -LiteralPath (Join-Path $script:PackageRoot 'transform.py') -Value '# fixture' }
        $passed++
        Write-Host "PASS: $($case[0]) stops safely during '$script:CurrentStep'"
    }
    Write-Host "Passed $passed simulated setup scenarios. This is not a native Windows installation test."
}
finally {
    $env:Path = $originalPath
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
