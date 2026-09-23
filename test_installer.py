"""Offline installer regression checks. Run: python3 test_installer.py"""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

INSTALLER = Path(__file__).with_name("install-pixie-dust.sh")


def run(args, *, env=None):
    return subprocess.run(args, env=env, capture_output=True, text=True, timeout=60)


def shell(root, code, env=None):
    return run(["bash", "-c", 'source "$1"; SOURCE_DIR="$2"; ' + code,
                "test", str(INSTALLER), str(root)], env=env)


def write(path, content, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if executable:
        path.chmod(0o755)


def snapshot(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file() and ".git" not in p.parts}


with tempfile.TemporaryDirectory(prefix="pixie-installer-test.") as directory:
    root = Path(directory)
    source = root / "source with spaces"
    write(source / "README.md", "# Pixie Dust\nDo not modify me\n")
    before = snapshot(root)
    for path in (source, root / "missing"):
        result = run(["bash", str(INSTALLER), "--source-dir", str(path),
                      "--force", "--dry-run"])
        assert result.returncode == 0, result.stderr
    assert snapshot(root) == before and not (root / "missing").exists()
    assert run(["bash", str(INSTALLER), "--source-dir"]).returncode != 0
    for path in (Path("/"), Path.home(), source):
        result = shell(path, "FORCE=1; validate_source_dir")
        assert result.returncode != 0, str(path)
    linked = root / "symlink"
    linked.symlink_to(source, target_is_directory=True)
    assert shell(linked, "FORCE=1; validate_source_dir").returncode != 0
    print("ok: dry-run, argument validation, unsafe replacement guards")

    # Exercise the real transformer with notices, dependencies and renamed assets.
    run(["git", "init", "-q", str(source)])
    write(source / "README.md", "# Aseprite\n")
    preserved = {
        ".gitmodules": '[submodule "laf"]\npath = laf\nurl = https://github.com/aseprite/laf\n',
        "EULA.txt": "Original Aseprite license\n",
        "AUTHORS.md": "Original Aseprite authors\n",
        "data/extensions/aseprite-theme/LICENSE.txt": "Aseprite asset notice\n",
    }
    for name, content in preserved.items():
        write(source / name, content)
    write(source / "src/ver/info.c", "// Aseprite\n")
    write(source / "src/CMakeLists.txt", "add_executable(aseprite main.cpp)\n")
    write(source / "CMakeLists.txt", "project(aseprite)\n")
    write(source / "src/app/sample.cpp", 'prefs.asepriteFormat();\n"aseprite/";\n"aseprite.ini";\n')
    write(source / "tests/sprites/a.aseprite", "fixture\n")
    write(source / "tests/cli/sheet.sh", '''local dotAseIndex = string.find(sample.filename, ".ase")
      local frame = (string.sub(sample.filename, dotAseIndex - 2, dotAseIndex - 1)) + 1
''')
    run(["git", "-C", str(source), "add", "."])
    (source / "laf/empty-dependency-dir").mkdir(parents=True)
    result = shell(source, "apply_pixie_dust_transform")
    assert result.returncode == 0, result.stderr
    for name, content in preserved.items():
        assert (source / name.replace("aseprite-theme", "pixie-dust-theme")).read_text() == content
    assert (source / "tests/sprites/a.pixie-dust").exists()
    assert 'prefs.pixiedustFormat()' in (source / "src/app/sample.cpp").read_text()
    assert '"pixie-dust/"' in (source / "src/app/sample.cpp").read_text()
    assert '"pixie-dust.ini"' in (source / "src/app/sample.cpp").read_text()
    assert 'dotAseIndex' not in (source / "tests/cli/sheet.sh").read_text()
    assert (source / "laf/empty-dependency-dir").exists()
    before = snapshot(source)
    result = shell(source, "apply_pixie_dust_transform")
    assert result.returncode == 0 and snapshot(source) == before, result.stderr
    print("ok: source transform, filenames, notices, submodules, rerun stability")

    # A failed transfer must never become a reusable archive.
    commands = root / "commands"
    write(commands / "curl", '#!/bin/bash\nprintf broken > "$4"\nexit 22\n', True)
    environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"])
    result = shell(root, 'download_file https://example.invalid/archive "$SOURCE_DIR/archive.zip"', environment)
    assert result.returncode != 0 and not (root / "archive.zip").exists()
    assert not list(root.glob("archive.zip.part.*"))
    write(commands / "curl", '#!/bin/bash\nprintf complete > "$4"\n', True)
    result = shell(root, 'download_file https://example.invalid/archive "$SOURCE_DIR/archive.zip"', environment)
    assert result.returncode == 0 and (root / "archive.zip").read_text() == "complete", result.stderr
    print("ok: failed downloads cannot poison the archive cache")

    # apt output must never leak into the captured CMake prefix path.
    write(commands / "c++", '#!/bin/bash\nexit 1\n', True)
    write(commands / "sudo", '#!/bin/bash\n[ "$1" != -n ] || exit 0\necho apt-progress\n', True)
    result = shell(root, 'sysroot="$(ensure_dev_headers)"; printf "<%s>" "$sysroot"', environment)
    assert result.returncode == 0 and result.stdout == "<>", result.stdout + result.stderr
    write(commands / "sudo", '#!/bin/bash\n[ "$1" != -n ] || exit 0\nexit 42\n', True)
    result = shell(root, 'sysroot="$(ensure_dev_headers)"; echo SHOULD_NOT_CONTINUE', environment)
    assert result.returncode != 0 and 'SHOULD_NOT_CONTINUE' not in result.stdout
    print("ok: dependency output and failures stay out of CMake paths")

    build = root / "build-pixiedust"
    write(build / "bin/pixie-dust", '#!/bin/bash\necho "Pixie Dust test"\n', True)
    flags = "ENABLE_NEWS:BOOL=OFF\nENABLE_UPDATER:BOOL=OFF\nENABLE_WEBSOCKET:BOOL=OFF\n"
    write(build / "CMakeCache.txt", flags)
    write(commands / "ldd", '#!/bin/bash\necho "libc.so.6 => /lib/libc.so.6"\n', True)
    write(commands / "strings", '#!/bin/bash\necho clean\n', True)
    assert shell(root, "verify_binary", environment).returncode == 0
    for flag in ("ENABLE_NEWS", "ENABLE_UPDATER", "ENABLE_WEBSOCKET"):
        write(build / "CMakeCache.txt", flags.replace(f"{flag}:BOOL=OFF", f"{flag}:BOOL=ON"))
        assert shell(root, "verify_binary", environment).returncode != 0
    write(build / "CMakeCache.txt", flags)
    write(commands / "ldd", '#!/bin/bash\necho "libX.so => not found"\n', True)
    assert shell(root, "verify_binary", environment).returncode != 0
    write(commands / "ldd", '#!/bin/bash\necho libc.so\n', True)
    write(commands / "strings", '#!/bin/bash\necho https://aseprite.org\nhead -c 1000000 /dev/zero\n', True)
    assert shell(root, "verify_binary", environment).returncode != 0
    print("ok: all flags, missing libraries, and early forbidden-string matches checked")

    # Run the exact desktop generator against a path containing reserved characters.
    script = INSTALLER.read_text().split('  python3 - "$HOME" <<\'PY\'\n', 1)[1].split('\nPY\n', 1)[0]
    desktop_home = root / 'user spaces $percent% "quote"'
    (desktop_home / ".local/share/applications").mkdir(parents=True)
    result = run(["python3", "-c", script, str(desktop_home)])
    assert result.returncode == 0, result.stderr
    desktop = desktop_home / ".local/share/applications/pixie-dust.desktop"
    result = run(["desktop-file-validate", str(desktop)])
    assert result.returncode == 0, result.stdout + result.stderr
    print("ok: desktop command quoting")

print("All installer regression checks passed.")
