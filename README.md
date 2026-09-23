# Pixie Dust installer

[![Windows script checks](https://github.com/ghiankyledomingo2007-beep/pixie-dust-installer/actions/workflows/checks.yml/badge.svg)](https://github.com/ghiankyledomingo2007-beep/pixie-dust-installer/actions/workflows/checks.yml)

Build and install the Pixie Dust pixel-art editor on your own Windows computer.

**[Download the Windows installer ZIP](https://github.com/ghiankyledomingo2007-beep/pixie-dust-installer/releases/download/v0.1.0-preview.1/Pixie-Dust-Windows-Installer.zip)** · [Release notes](https://github.com/ghiankyledomingo2007-beep/pixie-dust-installer/releases/tag/v0.1.0-preview.1) · [Full AI setup prompt](AI-SETUP-PROMPT.txt)

> **Preview:** native Windows installation has not yet been tested. Script checks and 14 simulated setup scenarios pass; the app's save/export/reopen check has passed on Linux. Windows 10 compatibility, WinGet/UAC, MSVC compilation and shortcuts still need a Windows run.

## Easiest setup: download and double-click

1. Download the **installer ZIP** above.
2. Right-click the ZIP and choose **Extract All**.
3. Open the extracted `Pixie-Dust-Installer` folder.
4. Double-click **Install Pixie Dust.cmd**.
5. Allow the prerequisite installers when Windows asks. Keep the setup window open.
6. After setup reports success, open **Pixie Dust** from your Desktop or Start Menu.

Use the installer ZIP linked above. GitHub's **Code → Download ZIP** source archive is for development and does not contain the generated `transform.py` needed by Windows setup.

### What to expect

- An **x64 Windows 10/11** computer and an internet connection are required. The upstream build guide lists Windows 11 + Visual Studio 2022. ARM64 and 32-bit Windows are not supported by this installer.
- Setup downloads source and graphics libraries, then builds the editor locally. It may install **several gigabytes** of build tools. Time depends on your computer and connection.
- Existing Git, Python and Visual Studio 2022 C++ tools are reused. Missing tools are installed through WinGet; Windows may request administrator approval.
- Six numbered stages show progress. Before reporting success, setup saves a small sprite, exports PNG, and reopens both files using temporary app settings.
- Source and application files live in `%LOCALAPPDATA%\PixieDust\source`. **Keep that folder**: your shortcuts point to the executable inside it.
- The installer never deletes an existing Windows source folder. An interrupted build can be retried.

## Copy and paste into Windows PowerShell

This downloads the preview ZIP into a new temporary folder and runs setup. Open **Windows PowerShell** on Windows, then copy the entire block. Run it as your normal user; handle administrator prompts only when prerequisite installers request them.

```powershell
$setup = Join-Path $env:TEMP ("PixieDust-Setup-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $setup | Out-Null
$zip = Join-Path $setup "installer.zip"
Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/ghiankyledomingo2007-beep/pixie-dust-installer/releases/download/v0.1.0-preview.1/Pixie-Dust-Windows-Installer.zip" -OutFile $zip
Expand-Archive -LiteralPath $zip -DestinationPath $setup
$installer = Join-Path $setup "Pixie-Dust-Installer\install-pixie-dust.ps1"
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $installer
```

The execution-policy setting applies only to that PowerShell process; the installer does not change your permanent policy.

### Already extracted the ZIP?

Open PowerShell inside the extracted `Pixie-Dust-Installer` folder:

```powershell
# Preview the steps without downloads or file changes:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-pixie-dust.ps1 -DryRun

# Install:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-pixie-dust.ps1
```

Optional arguments:

| Argument | Use it to |
| --- | --- |
| `-SourceDir "D:\PixieDust\source"` | Choose a new source/build folder. |
| `-SkipPrerequisites` | Require existing tools instead of installing missing prerequisites. |
| `-NoBuild` | Fetch and prepare source only; Git and Python may still be installed. |
| `-Jobs 4` | Use four parallel build jobs. Default is two to limit memory use. |

## Let an AI assistant help

Extract the installer ZIP and open its folder in an AI coding assistant with local terminal access. Paste this prompt:

```text
Help me install Pixie Dust on this Windows computer from the extracted installer in this workspace.

Read README-WINDOWS.txt and AI-SETUP-PROMPT.txt first. I authorize local setup and installation of its missing build prerequisites. Let me handle Windows administrator prompts and follow your tool approval rules.

Confirm x64 Windows, inspect the installer, run its -DryRun, then install using install-pixie-dust.ps1. Preserve my existing files and settings. If anything fails, read the printed setup log and fix the actual cause; do not delete my source folder or hide errors.

Verify the executable version, the save/export/reopen check, and the Desktop/Start Menu shortcuts. Open the editor; if you cannot inspect its window, ask me to confirm that it loads. This is a preview without a completed native Windows test, so report only what you actually verify.

If this workspace is not the extracted installer folder, ask me for that folder's location.
```

The longer [AI-SETUP-PROMPT.txt](AI-SETUP-PROMPT.txt) is also included in the installer ZIP. An assistant without access to your computer can guide you through commands, but cannot run setup for you.

## If setup stops

1. Read the error and **Stopped while** stage at the bottom of the window.
2. Find the setup log at the printed path, under `%LOCALAPPDATA%\PixieDust\logs`.
3. Fix the reported problem and run **Install Pixie Dust.cmd** again. Completed source/dependency work is reused.

Common cases:

| Message or situation | Next step |
| --- | --- |
| `transform.py` is missing | Download the installer release ZIP and **Extract All**. Keep its files together. |
| WinGet is missing | Install [Microsoft App Installer](https://apps.microsoft.com/detail/9nblggh4nns1), or install prerequisites manually as described in [README-WINDOWS.txt](README-WINDOWS.txt). |
| Windows requests a reboot | Restart Windows, then run setup again. |
| Source folder conflicts or has unrelated edits | Keep your work. Use `-SourceDir` with a new folder. |
| Graphics download is damaged | Rerun setup; the damaged archive is removed for a fresh download. |
| Compilation fails | Give the setup log and [AI setup prompt](AI-SETUP-PROMPT.txt) to your assistant, or [open an issue](https://github.com/ghiankyledomingo2007-beep/pixie-dust-installer/issues). Remove private information before posting logs publicly. |

## Development and verification

This repository contains installer scripts, documentation and tests. The Windows release ZIP adds `transform.py`, generated from the same transformation used by the Linux installer.

Build the ZIP with Python 3.9+:

```shell
python package-windows.py
```

Run the offline PowerShell checks:

```powershell
pwsh -NoProfile -File .\test-windows-installer.ps1
pwsh -NoProfile -File .\test-windows-flow.ps1
```

Run Linux installer checks on Linux with Python 3, Git, Bash and `desktop-file-validate` available:

```shell
python3 test_installer.py
```

The simulated flow checks successful setup, cache reuse, paths containing spaces, source-only setup, folder conflicts, missing package files, wrong revisions, local edits, transformation failure, damaged archives, build failure, wrong executable versions/feature flags, app-check failure and missing prerequisites. These checks do **not** replace a native Windows installation test.

GitHub Actions runs the script checks with Windows PowerShell 5.1 on a Windows runner and verifies ZIP packaging. It does not install prerequisites or compile the editor.

Linux users can run `bash install-pixie-dust.sh --help` for the Linux self-builder.

## Source and notices

Pixie Dust is a local rebrand built from [Aseprite source](https://github.com/aseprite/aseprite/tree/717ab76b2ed9b814fda4b65eb388f6ad480ca4ee), pinned to commit `717ab76b2ed9b814fda4b65eb388f6ad480ca4ee`, with the matching Skia release specified by that source tree.

Original EULA, author credits, component notices and upstream submodule URLs are preserved by the current transformer. Upstream software retains its own licenses. This repository and release contain installer scripts, **not a precompiled editor**.
