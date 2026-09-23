#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

PRODUCT_NAME="Pixie Dust"
UPSTREAM_COMMIT="717ab76b2ed9b814fda4b65eb388f6ad480ca4ee"
UPSTREAM_URL="${PIXIE_DUST_UPSTREAM_URL:-https://github.com/aseprite/aseprite.git}"
SOURCE_DIR="${PIXIE_DUST_SOURCE_DIR:-$HOME/src/pixie-dust}"
BUILD_DIR_NAME="build-pixiedust"
FORCE=0
NO_BUILD=0
DRY_RUN=0

log() { printf '\033[1;36m[pixie-dust]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[pixie-dust warning]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[pixie-dust error]\033[0m %s\n' "$*" >&2; exit 1; }
run() { if [ "$DRY_RUN" = 1 ]; then printf '[dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }

usage() {
  cat <<'USAGE'
Pixie Dust single-file self-builder.

This does not install a precompiled binary. It fetches source, applies the
Pixie Dust local rebrand/cleanup, builds on this machine, and wires a launcher.

Usage:
  bash install-pixie-dust.sh [options]

Options:
  --source-dir DIR       Source/build directory (default: ~/src/pixie-dust)
  --force                Recreate an existing supported Pixie Dust source checkout
  --no-build             Apply the Pixie Dust source transform but skip configure/build
  --dry-run              Print the install plan without changing files or downloading
  --codex-prompt         Print a fallback prompt to paste into Codex if install fails
  -h, --help             Show this help

Useful env:
  PIXIE_DUST_UPSTREAM_URL=<git-url>      Override upstream clone URL for tests/mirrors
  PIXIE_DUST_SOURCE_DIR=<path>           Same as --source-dir
USAGE
}

codex_prompt() {
  cat <<'PROMPT'
You are helping install Pixie Dust from a local self-builder script.
Run from the folder containing install-pixie-dust.sh.
Do not ask me to paste passwords or secrets into chat.
I ran: bash install-pixie-dust.sh
It failed with this terminal output:

<PASTE EXACT ERROR HERE>

Fix the local build/install. Preserve upstream license and third-party notice files.
Do not distribute a compiled binary. Make the script fetch source, apply the Pixie Dust changes, build locally, wire ~/.local/bin/pixie-dust, then verify `pixie-dust --version`.
PROMPT
}

parse_args() {
while [ $# -gt 0 ]; do
  case "$1" in
    --source-dir) [ $# -ge 2 ] && [[ "$2" != --* ]] && [ -n "$2" ] || fail "--source-dir requires a directory"; shift; SOURCE_DIR="$1" ;;
    --force) FORCE=1 ;;
    --no-build) NO_BUILD=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --codex-prompt) codex_prompt; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || return 1; }

ensure_basic_tools() {
  log "checking tools"
  need_cmd git || fail "git is required. Install it first: sudo apt install git"
  need_cmd python3 || fail "python3 is required. Install it first: sudo apt install python3"
  [ "$NO_BUILD" = 0 ] || return 0
  [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || fail "This installer currently supports Linux x86_64 only"
  need_cmd c++ || fail "a C++ compiler is required. Install it first: sudo apt install build-essential"
  need_cmd unzip || fail "unzip is required. Install it first: sudo apt install unzip"
  if ! need_cmd curl && ! need_cmd wget; then
    fail "curl or wget is required. Install one first: sudo apt install curl"
  fi

  if ! need_cmd cmake || ! need_cmd ninja; then
    warn "cmake/ninja missing; trying user-level Python install"
    python3 -m pip install --user --break-system-packages cmake ninja 2>/dev/null || \
      python3 -m pip install --user cmake ninja || \
      fail "Could not install cmake/ninja. Try: python3 -m pip install --user cmake ninja"
    export PATH="$HOME/.local/bin:$PATH"
  fi
  need_cmd cmake || fail "cmake still not on PATH after install attempt"
  need_cmd ninja || fail "ninja still not on PATH after install attempt"
  need_cmd ldd && need_cmd strings || fail "ldd and strings are required to verify the build"
}

download_file() {
  local url="$1" out="$2"
  if [ -s "$out" ]; then return 0; fi
  local partial
  partial="$(mktemp "${out}.part.XXXXXX")"
  log "downloading $(basename "$out")"
  if need_cmd curl; then
    if ! curl -L --fail -o "$partial" "$url"; then
      rm -f -- "$partial"
      fail "Download failed: $url"
    fi
  else
    if ! wget -O "$partial" "$url"; then
      rm -f -- "$partial"
      fail "Download failed: $url"
    fi
  fi
  [ -s "$partial" ] || { rm -f -- "$partial"; fail "Empty download: $url"; }
  mv -f -- "$partial" "$out"
}

validate_source_dir() {
  [ ! -L "$SOURCE_DIR" ] || fail "Source directory must not be a symlink"
  SOURCE_DIR="$(python3 - "$SOURCE_DIR" "$FORCE" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]).resolve()
protected_paths = [Path.home().resolve()]
if sys.argv[2] == '1':
    protected_paths.append(Path.cwd().resolve())
for protected in protected_paths:
    if p == protected or p in protected.parents:
        raise SystemExit('Refusing source directory that contains the home or current directory: ' + str(p))
if len(p.parts) < 3 or p == Path('/tmp'):
    raise SystemExit('Refusing unsafe source directory: ' + str(p))
print(p)
PY
)"
  if [ -e "$SOURCE_DIR" ]; then
    [ -d "$SOURCE_DIR/.git" ] && [ -f "$SOURCE_DIR/src/ver/info.c" ] && [ -f "$SOURCE_DIR/CMakeLists.txt" ] || fail "Source directory is not a supported checkout; choose a new --source-dir"
    [ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$UPSTREAM_COMMIT" ] || fail "Existing checkout uses a different revision; choose a new --source-dir"
    if [ "$FORCE" = 0 ] && ! grep -q '^# Pixie Dust' "$SOURCE_DIR/README.md" && [ -n "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=no)" ]; then
      fail "Existing upstream checkout has local changes; choose a new --source-dir"
    fi
  fi
}

clone_source() {
  if [ -e "$SOURCE_DIR" ] && [ "$FORCE" = 1 ]; then
    log "removing existing source dir: $SOURCE_DIR"
    run rm -rf -- "$SOURCE_DIR"
  fi
  if [ ! -d "$SOURCE_DIR/.git" ]; then
    if [ -e "$SOURCE_DIR" ]; then
      fail "$SOURCE_DIR exists but is not a git repo. Use --source-dir elsewhere or --force."
    fi
    log "cloning source into $SOURCE_DIR"
    run mkdir -p "$(dirname "$SOURCE_DIR")"
    run git clone -- "$UPSTREAM_URL" "$SOURCE_DIR"
  fi

  if [ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$UPSTREAM_COMMIT" ]; then
    log "checking out expected source revision"
    if ! git -C "$SOURCE_DIR" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2>/dev/null; then
      run git -C "$SOURCE_DIR" fetch origin "$UPSTREAM_COMMIT"
    fi
    run git -C "$SOURCE_DIR" checkout -q "$UPSTREAM_COMMIT"
  fi
  run git -C "$SOURCE_DIR" submodule update --init --recursive
}

apply_pixie_dust_transform() {
  log "applying Pixie Dust source transform"
  python3 - "$SOURCE_DIR" <<'PY'
from __future__ import annotations
import os, re, subprocess, sys, shutil
from pathlib import Path

root = Path(sys.argv[1]).resolve()
os.chdir(root)

tracked = subprocess.check_output(['git', 'ls-files', '-z']).decode('utf-8', 'surrogateescape').split('\0')
tracked = [p for p in tracked if p]
already_branded = (root/'README.md').is_file() and (root/'README.md').read_text(encoding='utf-8').startswith('# Pixie Dust')

def preserve(rel: str) -> bool:
    name = Path(rel).name.upper()
    return rel == '.gitmodules' or name.startswith(('LICENSE', 'COPYING', 'EULA', 'AUTHORS'))

def public_names(text: str) -> str:
    # Keep C++ identifiers/headers valid while matching the installed app's paths.
    text = re.sub(r'\.pixiedust(?=$|[^A-Za-z0-9_])', '.pixie-dust', text)
    text = text.replace('pixiedust-theme', 'pixie-dust-theme')
    text = text.replace('pixiedust/', 'pixie-dust/')
    text = text.replace('pixiedust.ini', 'pixie-dust.ini')
    text = text.replace('"pixiedust"', '"pixie-dust"')
    text = text.replace('Pixiedust 1', 'Pixie Dust 1')
    text = text.replace('"Pixiedust"', '"Pixie Dust"')
    return text


code_suffixes = {
    '.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.hxx', '.m', '.mm',
    '.cmake', '.lua', '.py', '.sh', '.ps1', '.plist', '.rc', '.manifest',
    '.bat', '.cmd'
}
code_names = {'CMakeLists.txt'}

def is_binary(path: Path) -> bool:
    try:
        data = path.read_bytes()
    except Exception:
        return True
    return b'\0' in data[:4096]

def text_replace(rel: str, text: str) -> str:
    p = Path(rel)
    code_like = (p.name in code_names or p.suffix in code_suffixes)
    if code_like:
        text = text.replace('Aseprite', 'Pixiedust')
        text = text.replace('ASEPRITE', 'PIXIEDUST')
        text = text.replace('aseprite', 'pixiedust')
    else:
        text = text.replace('Aseprite', 'Pixie Dust')
        text = text.replace('ASEPRITE', 'PIXIEDUST')
        text = text.replace('aseprite', 'pixiedust')
    return public_names(text)

# Rewrite tracked text files. Submodule contents are not in superproject git ls-files.
for rel in tracked:
    path = root / rel
    if preserve(rel) or path.is_symlink() or not path.is_file() or is_binary(path):
        continue
    try:
        original = path.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        continue
    new = text_replace(rel, original)
    if new != original:
        path.write_text(new, encoding='utf-8')

# Rename tracked paths that still carry old product name. Do deepest paths first.
def map_path(rel: str) -> str:
    parts = []
    for part in Path(rel).parts:
        part = part.replace('Aseprite', 'Pixiedust')
        part = part.replace('ASEPRITE', 'PIXIEDUST')
        part = part.replace('aseprite', 'pixiedust')
        parts.append(part)
    return public_names(str(Path(*parts)))

for rel in sorted(tracked, key=lambda s: len(Path(s).parts), reverse=True):
    newrel = map_path(rel)
    if newrel == rel:
        continue
    src = root / rel
    dst = root / newrel
    if not src.exists():
        continue
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        if dst.is_file() and src.is_file() and dst.read_bytes() == src.read_bytes():
            src.unlink()
        else:
            raise SystemExit(f'target already exists while renaming {rel} -> {newrel}')
    else:
        shutil.move(str(src), str(dst))

# Preserve user documentation when rerunning the installer.
if not already_branded:
    (root/'README.md').write_text('# Pixie Dust — Domynix Build\n\nLocal Pixie Dust pixel-art editor. Original license and author notices are preserved.\n\n- Build: `ninja -C build-pixiedust bin/pixie-dust`\n- Launcher: `~/.local/bin/pixie-dust`\n- Config and extensions: `~/.config/pixie-dust/`\n- Build instructions: `INSTALL.md`\n- Credits and notices: `AUTHORS.md`, `EULA.txt`, `docs/LICENSES.md`, component LICENSE files.\n', encoding='utf-8')

# CMake defaults and executable target name.
def patch_file(rel: str, replacements: list[tuple[str, str]]) -> None:
    p = root / rel
    if not p.exists():
        return
    s = p.read_text(encoding='utf-8')
    for old, new in replacements:
        s = s.replace(old, new)
    p.write_text(s, encoding='utf-8')

patch_file('CMakeLists.txt', [
    ('option(ENABLE_NEWS         "Enable the news in Home tab" on)', 'option(ENABLE_NEWS         "Enable the news in Home tab" off)'),
    ('option(ENABLE_UPDATER      "Enable automatic check for updates" on)', 'option(ENABLE_UPDATER      "Enable legacy update checker" off)'),
    ('option(ENABLE_WEBSOCKET    "Compile with websocket support" on)', 'option(ENABLE_WEBSOCKET    "Compile with websocket support" off)'),
    ('option(ENABLE_DRM          "Compile the DRM-enabled version (e.g. for automatic updates)" off)', 'option(ENABLE_DRM          "Compile legacy DRM-enabled version" off)'),
])

patch_file('src/CMakeLists.txt', [
    ('add_executable(pixiedust ', 'add_executable(pixie-dust '),
    ('set_target_properties(pixiedust ', 'set_target_properties(pixie-dust '),
    ('set_target_properties(pixiedust\n', 'set_target_properties(pixie-dust\n'),
    ('TARGET pixiedust POST_BUILD', 'TARGET pixie-dust POST_BUILD'),
    ('target_link_libraries(pixiedust ', 'target_link_libraries(pixie-dust '),
    ('add_dependencies(pixiedust ', 'add_dependencies(pixie-dust '),
    ('install(TARGETS pixiedust', 'install(TARGETS pixie-dust'),
    ('bin/pixiedust', 'bin/pixie-dust'),
    ('share/pixiedust', 'share/pixie-dust'),
    ('Pixiedust.app', 'Pixie Dust.app'),
])

(root/'src/ver/info.c').write_text('''/* Pixie Dust local Domynix build. */

#include "ver/info.h"
#include "generated_version.h" /* It defines the VERSION macro */

#define PACKAGE   "Pixie Dust"
#define COPYRIGHT "Pixie Dust local Domynix build"

#define WEBSITE ""
#define WEBSITE_DOWNLOAD ""
#define WEBSITE_CONTRIBUTORS ""
#define WEBSITE_NEWS_RSS ""
#define WEBSITE_UPDATE ""

const char* get_app_name()
{
  return PACKAGE;
}
const char* get_app_version()
{
  return VERSION;
}
const char* get_app_copyright()
{
  return COPYRIGHT;
}

const char* get_app_url()
{
  return WEBSITE;
}
const char* get_app_download_url()
{
  return WEBSITE_DOWNLOAD;
}
const char* get_app_contributors_url()
{
  return WEBSITE_CONTRIBUTORS;
}
const char* get_app_news_rss_url()
{
  return WEBSITE_NEWS_RSS;
}
const char* get_app_update_url()
{
  return WEBSITE_UPDATE;
}
''', encoding='utf-8')

# Remove external Help menu / license entry block.
gui = root/'data/gui.xml'
if gui.exists():
    s = gui.read_text(encoding='utf-8')
    s = re.sub(r'\n\s*<separator />\n\s*<item command="Launch" text="@\.help_quick_reference">.*?<item command="EnterLicense" id="enter_license" text="@\.help_enter_license" group="help_enter_license" />', '', s, flags=re.S)
    gui.write_text(s, encoding='utf-8')

send_crash = root/'data/widgets/send_crash.xml'
if send_crash.exists():
    s = send_crash.read_text(encoding='utf-8')
    s = re.sub(r'<label text="@\.to_email" />\s*<entry readonly="true" text="[^"]*" maxsize="256" />\s*<label text="@\.explaining" />',
               '<label text="Keep the crash file for local debugging." />\n      <entry readonly="true" text="local Pixie Dust workspace" maxsize="256" />\n      <label text="No external support endpoint is configured for this build." />', s)
    send_crash.write_text(s, encoding='utf-8')

patch_file('data/strings/en.ini', [
    ('enter_license_disabled = Information\\n<<This copy of Pixie Dust does not support entering a license key.\\n<<Consider getting one from https://pixiedust.org/download.\\n<<Activating Pixie Dust will give you access to automatic updates.\\n||&OK', 'enter_license_disabled = Information\\n<<This Pixie Dust build uses local-only activation-free mode.\\n||&OK'),
    ('enter_license_disabled = Information\\n<<This copy of Pixie Dust does not support entering a license key.\\n<<Consider getting one from https://pixie-dust.org/download.\\n<<Activating Pixie Dust will give you access to automatic updates.\\n||&OK', 'enter_license_disabled = Information\\n<<This Pixie Dust build uses local-only activation-free mode.\\n||&OK'),
    ('help_enter_license = Enter &License', 'help_enter_license = Local Build &Info'),
    ('default_message = If you need a license key, go to', 'default_message = This build is local-only and activation-free.'),
    ('license_key = License Key', 'license_key = Local Build Field'),
])

patch_file('src/app/win/file_associations.cpp', [
    ('IgaraStudio.Pixie Dust', 'Domynix.PixieDust'),
    ('IgaraStudio.Pixiedust', 'Domynix.PixieDust'),
])

# The generated options XML creates showPixiedustFileDialog(), not showPixieDustFileDialog().
patch_file('src/app/commands/cmd_options.cpp', [('showPixieDustFileDialog', 'showPixiedustFileDialog')])

# File names no longer contain .ase; extract the frame before the extension.
patch_file('tests/cli/sheet.sh', [
    ('local dotAseIndex = string.find(sample.filename, ".ase")\n      local frame = (string.sub(sample.filename, dotAseIndex - 2, dotAseIndex - 1)) + 1',
     'local frame = assert(tonumber(sample.filename:match(" (%d+)%.[^.]+$"))) + 1'),
])
ignore = root/'.gitignore'
ignored = ignore.read_text(encoding='utf-8') if ignore.exists() else ''
if 'build-pixiedust/' not in ignored.splitlines():
    ignore.write_text(ignored.rstrip() + '\nbuild-pixiedust/\n', encoding='utf-8')

print('Pixie Dust transform applied')
PY
}

ensure_skia() {
  local skia_tag skia_short skia_dir skia_build_dir skia_url skia_zip
  skia_tag="$(cat "$SOURCE_DIR/laf/misc/skia-tag.txt")"
  skia_short="$(printf '%s' "$skia_tag" | cut -d '-' -f 1)"
  skia_dir="$SOURCE_DIR/.deps/skia-$skia_short"
  skia_build_dir="$skia_dir/out/Release-x64"
  if [ -f "$skia_build_dir/libskia.a" ]; then
    printf '%s\n' "$skia_dir"
    return 0
  fi
  run mkdir -p "$skia_dir"
  skia_url="$(bash "$SOURCE_DIR/laf/misc/skia-url.sh" Release)"
  skia_zip="$skia_dir/$(basename "$skia_url")"
  download_file "$skia_url" "$skia_zip"
  log "extracting Skia"
  if ! unzip -o -q -d "$skia_dir" "$skia_zip" >&2; then
    rm -f -- "$skia_zip"
    fail "Invalid Skia archive; rerun to download it again"
  fi
  [ -f "$skia_build_dir/libskia.a" ] || fail "Skia library not found after extraction: $skia_build_dir/libskia.a"
  printf '%s\n' "$skia_dir"
}

ensure_dev_headers() {
  local sysroot="$SOURCE_DIR/.deps/x11-dev"
  local arch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || printf x86_64-linux-gnu)"
  if printf '#include <X11/Xcursor/Xcursor.h>\n#include <X11/extensions/XInput2.h>\n#include <X11/extensions/Xrandr.h>\n#include <GL/gl.h>\n#include <fontconfig/fontconfig.h>\nint main() {return 0;}\n' | c++ -x c++ - -o /dev/null -lXcursor -lXfixes -lXrender -lXi -lXrandr -lXext -lGL -lfontconfig >/dev/null 2>&1; then
    printf '\n'
    return 0
  fi

  if need_cmd apt-get && need_cmd sudo && sudo -n true 2>/dev/null; then
    log "installing missing dev headers with apt"
    run sudo apt-get update >&2
    run sudo apt-get install -y libxcursor-dev libxfixes-dev libxrender-dev libxi-dev libxrandr-dev libxext-dev libgl-dev libfontconfig-dev >&2
    printf '\n'
    return 0
  fi

  if ! need_cmd apt-get || ! need_cmd dpkg-deb; then
    fail "Missing X11/OpenGL/fontconfig dev headers and cannot use apt-get/dpkg-deb fallback. Install: libxcursor-dev libxi-dev libxrandr-dev libxext-dev libgl-dev libfontconfig-dev"
  fi

  log "using project-local extracted dev headers because sudo install is unavailable"
  run mkdir -p "$SOURCE_DIR/.deps/apt-download" "$sysroot"
  (
    cd "$SOURCE_DIR/.deps/apt-download"
    apt-get download libxcursor-dev libxfixes-dev libxrender-dev libxi-dev libxrandr-dev libxext-dev libgl-dev libglvnd-dev libglvnd-core-dev libegl-dev libgles-dev libglx-dev libopengl-dev libfontconfig-dev libexpat1-dev >&2
    for deb in *.deb; do dpkg-deb -x "$deb" "$sysroot" >&2; done
  )

  local libdir="$sysroot/usr/lib/$arch"
  run mkdir -p "$libdir"
  for spec in \
    libGL.so:/lib/$arch/libGL.so.1 \
    libXcursor.so:/lib/$arch/libXcursor.so.1 \
    libXext.so:/lib/$arch/libXext.so.6 \
    libXi.so:/lib/$arch/libXi.so.6 \
    libXrandr.so:/lib/$arch/libXrandr.so.2 \
    libXfixes.so:/lib/$arch/libXfixes.so.3 \
    libXrender.so:/lib/$arch/libXrender.so.1 \
    libfontconfig.so:/lib/$arch/libfontconfig.so.1; do
    local name="${spec%%:*}" target="${spec#*:}"
    [ -e "$libdir/$name" ] || [ ! -e "$target" ] || ln -sfn "$target" "$libdir/$name"
  done
  printf '%s\n' "$sysroot"
}

configure_and_build() {
  local skia_dir sysroot arch cmake_args
  skia_dir="$(ensure_skia)"
  sysroot="$(ensure_dev_headers)"
  arch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || printf x86_64-linux-gnu)"
  cmake_args=(
    -S "$SOURCE_DIR"
    -B "$SOURCE_DIR/$BUILD_DIR_NAME"
    -G Ninja
    -DCMAKE_BUILD_TYPE=RelWithDebInfo
    -DLAF_BACKEND=skia
    -DSKIA_DIR="$skia_dir"
    -DSKIA_LIBRARY_DIR="$skia_dir/out/Release-x64"
    -DSKIA_LIBRARY="$skia_dir/out/Release-x64/libskia.a"
    -DENABLE_NEWS=OFF
    -DENABLE_UPDATER=OFF
    -DENABLE_WEBSOCKET=OFF
  )
  if [ -n "$sysroot" ]; then
    local inc="$sysroot/usr/include" lib="$sysroot/usr/lib/$arch"
    cmake_args+=(
      -DCMAKE_PREFIX_PATH="$sysroot/usr"
      -DCMAKE_INCLUDE_PATH="$inc"
      -DCMAKE_LIBRARY_PATH="$lib"
      -DX11_Xcursor_INCLUDE_PATH="$inc"
      -DX11_Xcursor_LIB="$lib/libXcursor.so"
      -DX11_Xfixes_INCLUDE_PATH="$inc"
      -DX11_Xfixes_LIB="$lib/libXfixes.so"
      -DX11_Xrender_INCLUDE_PATH="$inc"
      -DX11_Xrender_LIB="$lib/libXrender.so"
      -DX11_Xi_INCLUDE_PATH="$inc"
      -DX11_Xi_LIB="$lib/libXi.so"
      -DX11_Xrandr_INCLUDE_PATH="$inc"
      -DX11_Xrandr_LIB="$lib/libXrandr.so"
      -DX11_Xext_INCLUDE_PATH="$inc"
      -DX11_Xext_LIB="$lib/libXext.so"
      -DFONTCONFIG_INCLUDE_DIR="$inc"
      -DFONTCONFIG_LIBRARY="$lib/libfontconfig.so"
      -DOPENGL_gl_LIBRARY="$lib/libGL.so"
      -DCMAKE_C_FLAGS="-I\"$inc\""
      -DCMAKE_CXX_FLAGS="-I\"$inc\""
      -DCMAKE_EXE_LINKER_FLAGS="-L\"$lib\""
    )
  fi
  log "configuring Pixie Dust"
  run cmake "${cmake_args[@]}"
  log "building Pixie Dust"
  run ninja -C "$SOURCE_DIR/$BUILD_DIR_NAME" bin/pixie-dust
}

install_launcher() {
  local bin="$SOURCE_DIR/$BUILD_DIR_NAME/bin/pixie-dust"
  [ -x "$bin" ] || fail "Built binary not found: $bin"
  run mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons"
  run ln -sfnT "$bin" "$HOME/.local/bin/pixie-dust"
  if [ -f "$SOURCE_DIR/data/icons/ase256.png" ]; then
    run cp "$SOURCE_DIR/data/icons/ase256.png" "$HOME/.local/share/icons/pixie-dust.png"
  fi
  python3 - "$HOME" <<'PY'
import sys
from pathlib import Path
home = Path(sys.argv[1])
def desktop_string(value):
    return str(value).replace('\\', '\\\\').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')
command = str(home/'.local/bin/pixie-dust').replace('%', '%%')
for char in ('\\', '"', '`', '$'):
    command = command.replace(char, '\\' + char)
entry = '''
[Desktop Entry]
Type=Application
Name=Pixie Dust
GenericName=Pixel Art Editor
Comment=Animated sprite editor and pixel art tool
Exec="{command}" %F
Icon={icon}
Terminal=false
Categories=Graphics;2DGraphics;RasterGraphics;
StartupWMClass=Pixie Dust
MimeType=image/png;image/gif;image/bmp;image/jpeg;image/webp;image/x-tga;image/x-pixie-dust;
'''.lstrip().format(command=desktop_string(command), icon=desktop_string(home/'.local/share/icons/pixie-dust.png'))
(home/'.local/share/applications/pixie-dust.desktop').write_text(entry)
PY
  chmod +x "$HOME/.local/share/applications/pixie-dust.desktop"
}

verify_binary() {
  local bin="$SOURCE_DIR/$BUILD_DIR_NAME/bin/pixie-dust" flag version libraries
  log "verifying built Pixie Dust"
  version="$("$bin" --version)"
  [[ "$version" == 'Pixie Dust '* ]] || fail "Unexpected built version: $version"
  for flag in ENABLE_NEWS ENABLE_UPDATER ENABLE_WEBSOCKET; do
    grep -Fx "$flag:BOOL=OFF" "$SOURCE_DIR/$BUILD_DIR_NAME/CMakeCache.txt" >/dev/null || fail "$flag must be OFF"
  done
  libraries="$(ldd "$bin")" || fail "Cannot inspect shared libraries"
  if printf '%s\n' "$libraries" | grep -Ei 'not found|lib(curl|websocket|ssl|crypto)' >/dev/null; then
    fail "binary has missing libraries or still links network/crypto libraries"
  fi
  # Consume the whole stream: grep -q can hide matches behind SIGPIPE with pipefail.
  if strings "$bin" | grep -Ei 'pixie-dust\.org|aseprite\.org|support@|igarastudio' >/dev/null; then
    fail "binary still contains external app/support URLs"
  fi
  printf '%s\n' "$version"
}

verify_install() {
  "$HOME/.local/bin/pixie-dust" --version
  if need_cmd desktop-file-validate; then
    desktop-file-validate "$HOME/.local/share/applications/pixie-dust.desktop"
  fi
  log "done: run Pixie Dust with: pixie-dust"
}

main() {
  parse_args "$@"
  if [ "$DRY_RUN" = 1 ]; then
    printf 'Source: %s\nPinned revision: %s\n' "$SOURCE_DIR" "$UPSTREAM_COMMIT"
    [ "$FORCE" = 0 ] || printf 'Would validate and replace the existing supported checkout.\n'
    printf 'Would check tools, fetch source/submodules, and apply the Pixie Dust transform.\n'
    [ "$NO_BUILD" = 1 ] || printf 'Would prepare build dependencies, build, verify, and install the user launcher.\n'
    return 0
  fi
  need_cmd python3 && need_cmd git || fail "python3 and git are required"
  validate_source_dir
  ensure_basic_tools
  clone_source
  apply_pixie_dust_transform
  if [ "$NO_BUILD" = 1 ]; then
    log "--no-build requested; source transformed at $SOURCE_DIR"
    exit 0
  fi
  configure_and_build
  verify_binary
  install_launcher
  verify_install
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
