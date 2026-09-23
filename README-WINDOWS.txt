PIXIE DUST - WINDOWS INSTALLER

1. Extract the entire ZIP into a folder.
2. Double-click "Install Pixie Dust.cmd".
3. Allow the Git, Python and Microsoft C++ tool installers when prompted.
4. When installation finishes, open Pixie Dust from your Desktop or Start Menu.

What you will see:
Setup shows six numbered stages. Downloading compiler tools and building the
editor can take a while; keep the window open while progress is appearing.
Before showing success, setup saves a test sprite, exports PNG, and reopens
both files. The test uses temporary settings and removes its own test files.

If setup stops:
- Read the error and the "Stopped while" stage at the bottom of the window.
- Your source and build files are kept. Fix the reported problem, then
  double-click "Install Pixie Dust.cmd" again; completed downloads are reused.
- A setup log is saved under %LOCALAPPDATA%\PixieDust\logs. Its exact path is
  printed in the window. Give that log to whoever helps you.
- If the message says to extract the ZIP, right-click the ZIP, choose
  "Extract All", then run the .cmd from the extracted folder.

AI-assisted setup or troubleshooting:
Open the extracted folder in an AI coding assistant with local terminal access
(such as Codex), then paste the contents of AI-SETUP-PROMPT.txt into its chat.
The prompt guides installation and checks the result on your Windows computer.
A chat assistant without local terminal access can only guide you manually.

This builds Pixie Dust on your computer. It downloads source and Skia, and may
install several gigabytes of compiler tools. Keep your internet connected.
Build time depends on your computer. Existing source folders are never deleted.

Target: x64 Windows 10/11 with Windows PowerShell 5.1 or newer.
The upstream build guide lists Windows 11 + Visual Studio 2022; Windows 10
compatibility and native Windows installation still need verification.
ARM64 and 32-bit Windows are not supported by this installer.

Install location: %LOCALAPPDATA%\PixieDust\source
Executable: build-pixiedust\bin\pixie-dust.exe inside that folder.
Keep this folder after installation: your shortcuts point into it.
The installer does not change your permanent PowerShell execution policy.

Prerequisites are reused if available, otherwise installed through WinGet:
- Git for Windows
- Python 3.9 or newer (Python 3.12 is installed when needed)
- Visual Studio 2022 Build Tools, Desktop development with C++, a Windows SDK,
  and C++ CMake tools for Windows (includes Ninja)

An existing Visual Studio 2022 C++ installation is reused. If its bundled
CMake/Ninja tools are missing, setup uses installed tools or installs those
two tools separately instead of reinstalling Visual Studio.

If WinGet is missing, install Microsoft App Installer or install those tools
yourself. If Windows requests a reboot, reboot and run this installer again.
If source uses a different revision or has unrelated edits, select a new
source folder instead of deleting your work.

Optional PowerShell commands (run from the extracted folder):
  .\install-pixie-dust.ps1 -DryRun
  .\install-pixie-dust.ps1 -SourceDir "D:\PixieDust\source"
  .\install-pixie-dust.ps1 -SkipPrerequisites
  .\install-pixie-dust.ps1 -NoBuild
  .\install-pixie-dust.ps1 -Jobs 4

-DryRun prints the plan without downloads, installs, or file changes.
-NoBuild fetches and transforms source only; Git and Python may be installed.
-SkipPrerequisites fails if a required tool is missing instead of installing it.
-Jobs defaults to 2 to limit memory pressure during compilation.

Original license, contributor and component notices remain in the source tree.
This ZIP contains installer scripts, not a precompiled application.

Validation so far: parser and offline helper checks, 14 simulated Windows
setup scenarios, and the actual sprite save/export/reopen check on Linux.
Native Windows installation, UAC dialogs and shortcuts remain untested.

Build references:
https://github.com/aseprite/aseprite/blob/717ab76b2ed9b814fda4b65eb388f6ad480ca4ee/INSTALL.md
https://learn.microsoft.com/en-us/visualstudio/ide/reference/command-prompt-powershell?view=vs-2022
https://learn.microsoft.com/en-us/windows/package-manager/winget/install
