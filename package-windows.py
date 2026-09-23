"""Package Windows installer with the same transformer used by Linux."""
from pathlib import Path
import sys
import zipfile

root = Path(__file__).resolve().parent
shell = (root / "install-pixie-dust.sh").read_text(encoding="utf-8")
transform = shell.split('  python3 - "$SOURCE_DIR" <<\'PY\'\n', 1)[1].split('\nPY\n', 1)[0]
compile(transform, "transform.py", "exec")
destination = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "Pixie-Dust-Windows-Installer.zip"
with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("Pixie-Dust-Installer/transform.py", transform + "\n")
    for name in ("install-pixie-dust.ps1", "Install Pixie Dust.cmd", "README-WINDOWS.txt", "AI-SETUP-PROMPT.txt"):
        data = (root / name).read_text(encoding="utf-8").replace("\n", "\r\n")
        archive.writestr("Pixie-Dust-Installer/" + name, data)
print(destination)
