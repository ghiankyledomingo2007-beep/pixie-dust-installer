#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceDir = (Join-Path $env:LOCALAPPDATA 'PixieDust\source'),
    [switch]$DryRun,
    [switch]$NoBuild,
    [switch]$SkipPrerequisites,
    [ValidateRange(1, 64)][int]$Jobs = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$UpstreamCommit = '717ab76b2ed9b814fda4b65eb388f6ad480ca4ee'
$UpstreamUrl = 'https://github.com/aseprite/aseprite.git'
$script:PackageRoot = $PSScriptRoot

function Invoke-Tool {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed (exit $LASTEXITCODE). See the output above."
    }
}

function Install-Prerequisite {
    param([string]$Id, [string]$Override = '')
    if ($SkipPrerequisites) { throw "Missing $Id. Install it, then run this installer again." }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'WinGet is missing. Install Microsoft App Installer, or install the prerequisites listed in README-WINDOWS.txt.'
    }
    Write-Host "Installing prerequisite: $Id. Windows may ask for administrator approval."
    $arguments = @('install', '--id', $Id, '--exact', '--source', 'winget',
                   '--accept-package-agreements', '--accept-source-agreements')
    if ($Override) { $arguments += @('--override', $Override) }
    Invoke-Tool 'winget.exe' $arguments
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:Path
}

function Find-Git {
    $command = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
}

function Find-Python {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:ProgramFiles 'Python312\python.exe')
    )
    $command = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source -notlike '*\WindowsApps\*') { $candidates += $command.Source }
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($launcher) {
        try {
            $found = & $launcher.Source -3 -c 'import sys; print(sys.executable)' 2>$null
            if ($LASTEXITCODE -eq 0) { $candidates += $found }
        }
        catch { Write-Verbose 'Python launcher has no usable Python 3 installation.' }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            & $candidate -c 'import sys; sys.exit(sys.version_info < (3, 9))'
            if ($LASTEXITCODE -eq 0) { return $candidate }
        }
    }
}

function Find-VisualStudio {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $found = & $vswhere -latest -products '*' -version '[17.0,18.0)' -requires `
            Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Visual Studio installations.' }
        if ($found) { return ($found | Select-Object -First 1).Trim() }
    }
}

function Get-Archive {
    param([string]$Url, [string]$Destination)
    if ((Test-Path -LiteralPath $Destination) -and (Get-Item -LiteralPath $Destination).Length -gt 0) { return }
    $partial = $Destination + '.' + [Guid]::NewGuid().ToString('N') + '.part'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $partial
        if ((Get-Item -LiteralPath $partial).Length -eq 0) { throw "Empty download: $Url" }
        Move-Item -LiteralPath $partial -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}

function Assert-Windows {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess -or
        ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64')) {
        throw 'Run this installer in 64-bit PowerShell on x64 Windows 10 or 11.'
    }
}

function Write-Step {
    param([int]$Number, [string]$Message)
    $script:CurrentStep = $Message
    Write-Host "`n[$Number/6] $Message" -ForegroundColor Cyan
}

function Start-SetupLog {
    $folder = Join-Path $env:LOCALAPPDATA 'PixieDust\logs'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $script:LogFile = Join-Path $folder ('setup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    Start-Transcript -LiteralPath $script:LogFile | Out-Null
    $script:TranscriptStarted = $true
}

function Resolve-BuildTool {
    param([string]$BundledPath, [string]$Name, [string]$Package)
    if (Test-Path -LiteralPath $BundledPath -PathType Leaf) { return $BundledPath }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        Install-Prerequisite $Package | Out-Host
        $command = Get-Command $Name -ErrorAction SilentlyContinue
    }
    if (-not $command) { throw "$Name was not found. Close this window and run setup again to refresh installed tools." }
    return $command.Source
}

function Initialize-BuildTools {
    $visualStudio = Find-VisualStudio
    if (-not $visualStudio) {
        Install-Prerequisite 'Microsoft.VisualStudio.2022.BuildTools' `
            '--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.CMake.Project --includeRecommended' | Out-Host
        $visualStudio = Find-VisualStudio
    }
    if (-not $visualStudio) { throw 'VS 2022 C++ and CMake tools are missing. Install them, reboot if requested, and rerun.' }
    & (Join-Path $visualStudio 'Common7\Tools\Launch-VsDevShell.ps1') -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Host
    $cmake = Join-Path $visualStudio 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    $ninja = Join-Path $visualStudio 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
    $cmake = Resolve-BuildTool $cmake 'cmake.exe' 'Kitware.CMake'
    $ninja = Resolve-BuildTool $ninja 'ninja.exe' 'Ninja-build.Ninja'
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw 'MSVC x64 environment did not initialize.' }

    return @{ CMake = $cmake; Ninja = $ninja }
}

function New-AppShortcuts {
    param([string]$binary)
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        if (-not $folder) { throw 'Could not locate the user shortcut folder.' }
        $shortcut = $shell.CreateShortcut((Join-Path $folder 'Pixie Dust.lnk'))
        $shortcut.TargetPath = $binary
        $shortcut.WorkingDirectory = Split-Path $binary
        $shortcut.IconLocation = "$binary,0"
        $shortcut.Description = 'Pixie Dust pixel-art editor'
        $shortcut.Save()
    }
}

function Test-BuiltApp {
    param([string]$Binary)
    $folder = Join-Path ([IO.Path]::GetTempPath()) ('pixie-dust-check-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder | Out-Null
    $previousConfig = [Environment]::GetEnvironmentVariable('PIXIEDUST_USER_FOLDER', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('PIXIEDUST_USER_FOLDER', (Join-Path $folder 'config'), 'Process')
        $scriptFile = Join-Path $folder 'check.lua'
        $lua = @'
local folder = app.params.folder
local sprite = Sprite(16, 16, ColorMode.RGB)
local pixel = app.pixelColor.rgba(255, 80, 40, 255)
sprite.cels[1].image:drawPixel(1, 1, pixel)
local native = app.fs.joinPath(folder, "check.pixie-dust")
local png = app.fs.joinPath(folder, "check.png")
sprite:saveAs(native)
sprite:saveAs(png)
sprite:close()
for _, path in ipairs({ native, png }) do
  local loaded = assert(app.open(path), "Cannot reopen " .. path)
  assert(loaded.width == 16 and loaded.height == 16, "Wrong sprite size")
  assert(loaded.cels[1].image:getPixel(1, 1) == pixel, "Pixel did not survive save/reopen")
  loaded:close()
end
local result = assert(io.open(app.fs.joinPath(folder, "passed.txt"), "w"))
result:write("ok")
result:close()
'@
        [IO.File]::WriteAllText($scriptFile, $lua)
        Invoke-Tool $Binary @('-b', '--script-param', "folder=$folder", '--script', $scriptFile) | Out-Host
        $marker = Join-Path $folder 'passed.txt'
        if (-not (Test-Path -LiteralPath $marker) -or [IO.File]::ReadAllText($marker) -ne 'ok') {
            throw 'The app could not complete its save/export/reopen check. See the setup log; shortcuts were not created.'
        }
        foreach ($name in @('check.pixie-dust', 'check.png')) {
            $file = Join-Path $folder $name
            if (-not (Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).Length -eq 0) {
                throw "The app did not create a valid $name test file. See the setup log."
            }
        }
        Write-Host 'App check passed: sprite saved, PNG exported, and both reopened.'
    }
    finally {
        if ($null -eq $previousConfig) {
            Remove-Item Env:PIXIEDUST_USER_FOLDER -ErrorAction SilentlyContinue
        }
        else { [Environment]::SetEnvironmentVariable('PIXIEDUST_USER_FOLDER', $previousConfig, 'Process') }
        Remove-Item -LiteralPath $folder -Recurse -Force
    }
}

function Invoke-Setup {
    if ($DryRun) {
        Write-Host "Source/build directory: $SourceDir"
        Write-Host "Pinned source revision: $UpstreamCommit"
        Write-Host 'Would check Git/Python, fetch source/submodules, and apply the Pixie Dust transform.'
        if (-not $NoBuild) {
            Write-Host 'Would prepare VS 2022 C++ tools, download Skia, build and verify Pixie Dust.'
            Write-Host 'Would create Start Menu and Desktop shortcuts. Existing source is never deleted.'
        }
        return
    }
    Assert-Windows
    Start-SetupLog
    Write-Host 'Pixie Dust setup' -ForegroundColor Cyan
    Write-Host 'Keep this window open. First-time compiler setup can download several GB.'
    Write-Host 'You can rerun this installer if a download or build is interrupted.'
    Write-Host "Setup log: $script:LogFile"
    Write-Step 1 'Checking the installer files and destination'
    $SourceDir = [IO.Path]::GetFullPath($SourceDir)
    $transform = Join-Path $script:PackageRoot 'transform.py'
    if (-not (Test-Path -LiteralPath $transform -PathType Leaf)) {
        throw 'Extract the entire installer ZIP first. transform.py must be beside this script.'
    }
    if (Test-Path -LiteralPath $SourceDir) {
        if (((Get-Item -LiteralPath $SourceDir).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not (Test-Path -LiteralPath (Join-Path $SourceDir '.git') -PathType Container) -or
            -not (Test-Path -LiteralPath (Join-Path $SourceDir 'src\ver\info.c') -PathType Leaf)) {
            throw 'SourceDir already exists and is not a supported checkout. Choose an empty, new directory.'
        }
    }

    Write-Step 2 'Preparing Git and Python'
    $git = Find-Git
    if (-not $git) { Install-Prerequisite 'Git.Git'; $git = Find-Git }
    if (-not $git) { throw 'Git was not found after installation. Restart this installer.' }
    $python = Find-Python
    if (-not $python) { Install-Prerequisite 'Python.Python.3.12'; $python = Find-Python }
    if (-not $python) { throw 'Python 3.9+ was not found after installation. Restart this installer.' }

    Write-Step 3 'Downloading and preparing Pixie Dust source'
    if (Test-Path -LiteralPath $SourceDir) {
        $head = Invoke-Tool $git @('-C', $SourceDir, 'rev-parse', 'HEAD')
        if ($head -ne $UpstreamCommit) { throw 'Existing source uses a different revision. Choose a new -SourceDir.' }
        $readme = Get-Content -LiteralPath (Join-Path $SourceDir 'README.md') -Raw
        $changes = Invoke-Tool $git @('-C', $SourceDir, 'status', '--porcelain', '--untracked-files=no')
        if ($changes -and $readme -notmatch '^# Pixie Dust') {
            throw 'Existing upstream checkout has local changes. Choose a new -SourceDir.'
        }
    }
    else {
        Invoke-Tool $git @('-c', 'core.longpaths=true', 'clone', '--', $UpstreamUrl, $SourceDir)
        Invoke-Tool $git @('-C', $SourceDir, 'checkout', '--detach', $UpstreamCommit)
    }
    Invoke-Tool $git @('-C', $SourceDir, '-c', 'core.longpaths=true', 'submodule', 'update', '--init', '--recursive')
    # Python's transform uses Git too, including when Git was found outside PATH.
    $env:Path = (Split-Path $git) + ';' + $env:Path
    Invoke-Tool $python @($transform, $SourceDir)
    if ($NoBuild) { Write-Host "Source ready: $SourceDir"; return }

    Write-Step 4 'Preparing the C++ compiler and graphics library'
    $buildTools = Initialize-BuildTools
    $cmake = $buildTools.CMake
    $ninja = $buildTools.Ninja

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $skiaTag = (Get-Content -LiteralPath (Join-Path $SourceDir 'laf\misc\skia-tag.txt') -Raw).Trim()
    if ($skiaTag -notmatch '^m[0-9]+-[a-f0-9]+$') { throw 'Unexpected Skia release tag.' }
    $skia = Join-Path $SourceDir ('.deps\skia-' + $skiaTag)
    $skiaLib = Join-Path $skia 'out\Release-x64\skia.lib'
    $complete = Join-Path $skia '.complete'
    if (-not ((Test-Path -LiteralPath $skiaLib) -and (Test-Path -LiteralPath $complete))) {
        New-Item -ItemType Directory -Path $skia -Force | Out-Null
        $archive = Join-Path $skia 'Skia-Windows-Release-x64.zip'
        Get-Archive "https://github.com/aseprite/skia/releases/download/$skiaTag/Skia-Windows-Release-x64.zip" $archive
        try { Expand-Archive -LiteralPath $archive -DestinationPath $skia -Force }
        catch {
            Remove-Item -LiteralPath $archive -Force
            throw 'The graphics download is incomplete or damaged. Run setup again to download a fresh copy.'
        }
        if (-not (Test-Path -LiteralPath $skiaLib -PathType Leaf)) { throw 'Skia archive did not contain the required x64 library.' }
        Set-Content -LiteralPath $complete -Value $skiaTag
    }
    Write-Step 5 'Building Pixie Dust - this may take a while'
    $build = Join-Path $SourceDir 'build-pixiedust'
    Invoke-Tool $cmake @('-S', $SourceDir, '-B', $build, '-G', 'Ninja',
        "-DCMAKE_MAKE_PROGRAM=$ninja", '-DCMAKE_C_COMPILER=cl.exe', '-DCMAKE_CXX_COMPILER=cl.exe',
        '-DCMAKE_BUILD_TYPE=RelWithDebInfo', '-DLAF_BACKEND=skia', "-DSKIA_DIR=$skia",
        "-DSKIA_LIBRARY_DIR=$(Split-Path $skiaLib)", "-DSKIA_LIBRARY=$skiaLib",
        '-DENABLE_NEWS=OFF', '-DENABLE_UPDATER=OFF', '-DENABLE_WEBSOCKET=OFF')
    Invoke-Tool $cmake @('--build', $build, '--target', 'pixie-dust', '--parallel', "$Jobs")
    Write-Step 6 'Checking the app and creating shortcuts'
    $binary = Join-Path $build 'bin\pixie-dust.exe'
    $version = Invoke-Tool $binary @('--version')
    if (($version -join "`n") -notmatch '^Pixie Dust ') { throw 'Built executable did not return the expected Pixie Dust version.' }
    $cache = Get-Content -LiteralPath (Join-Path $build 'CMakeCache.txt') -Raw
    foreach ($flag in @('ENABLE_NEWS', 'ENABLE_UPDATER', 'ENABLE_WEBSOCKET')) {
        if ($cache -notmatch "(?m)^${flag}:BOOL=OFF\r?$") { throw "$flag must be OFF." }
    }

    Test-BuiltApp $binary
    New-AppShortcuts $binary
    Write-Host "Installed: $($version -join ' ')"
    Write-Host "Open Pixie Dust from your Desktop or Start Menu. Keep this folder: $SourceDir"
}

$script:LogFile = $null
$script:TranscriptStarted = $false
$script:CurrentStep = 'Starting setup'
try {
    Invoke-Setup
    exit 0
}
catch {
    Write-Host "INSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stopped while: $script:CurrentStep"
    Write-Host 'Your source and build files were kept. Correct the error above, then double-click Install Pixie Dust.cmd again.'
    if ($script:LogFile) { Write-Host "Setup log: $script:LogFile" }
    Write-Host 'For help, paste AI-SETUP-PROMPT.txt into your AI assistant and give it this setup log.'
    exit 1
}
finally {
    if ($script:TranscriptStarted) { Stop-Transcript | Out-Null }
}
