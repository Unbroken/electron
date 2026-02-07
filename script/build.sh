#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ──

WORKSPACE="/c/CompiledFiles/electron_build"
DEPOT_TOOLS_DIR="/c/CompiledFiles/depot_tools"

# Windows-format paths for tools that need them (gclient, gn, ninja)
WIN_WORKSPACE="C:/CompiledFiles/electron_build"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_URL="$(git -C "$REPO_ROOT" remote get-url origin)"
COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

RELEASE_TAG="$(git -C "$REPO_ROOT" tag --points-at HEAD | head -n1)"
if [ -z "$RELEASE_TAG" ]; then
  echo "ERROR: No tag found at HEAD ($COMMIT_SHA)."
  echo "Tag the current commit first, e.g.: git tag v33.0.0-custom.1"
  exit 1
fi

# Strip leading 'v' for the version string (v33.0.0-custom.1 -> 33.0.0-custom.1)
ELECTRON_VERSION="${RELEASE_TAG#v}"

echo "=== Electron Build Script ==="
echo "  Tag:       $RELEASE_TAG"
echo "  Workspace: $WORKSPACE"
echo "  Repo:      $REPO_URL"
echo "  Commit:    $COMMIT_SHA"
echo ""

export DEPOT_TOOLS_WIN_TOOLCHAIN=0

# ── Prerequisites ──

echo ">>> Configuring git..."
git config --global core.longpaths true
git config --global core.autocrlf false

if [ ! -f "$DEPOT_TOOLS_DIR/gclient.bat" ]; then
  echo ">>> Installing depot_tools..."
  git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_DIR"
else
  echo ">>> Updating depot_tools..."
  git -C "$DEPOT_TOOLS_DIR" pull --ff-only || true
fi

export PATH="$DEPOT_TOOLS_DIR:$PATH"

echo ">>> Checking disk space..."
df -h

# ── Sync ──

echo ""
echo ">>> Configuring gclient..."
mkdir -p "$WORKSPACE"

cat > "$WORKSPACE/.gclient" <<GCLIENT
solutions = [
  {
    "name": "src/electron",
    "url": "${REPO_URL}@${COMMIT_SHA}",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {
      "src/third_party/squirrel.mac": None,
      "src/third_party/squirrel.mac/vendor/ReactiveObjC": None,
      "src/third_party/squirrel.mac/vendor/Mantle": None,
    },
    "custom_vars": {
      "checkout_pgo_profiles": True,
      "checkout_clang_tidy": False,
      "install_sysroot": False,
      "checkout_nacl": False,
      "checkout_openxr": False,
    },
  },
]
target_os = ["win"]
target_os_only = True
GCLIENT

echo ">>> Syncing dependencies (this may take a while)..."
cd "$WORKSPACE"
gclient sync --force --reset -j 16

# ── Build function ──

SRC_DIR="$WORKSPACE/src"
export CHROMIUM_BUILDTOOLS_PATH="$WIN_WORKSPACE/src/buildtools"

build_arch() {
  local arch="$1"
  local out_dir="out/Release_${arch}"

  echo ""
  echo "========================================="
  echo ">>> Building for $arch"
  echo "========================================="

  cd "$SRC_DIR"

  local gn_args="import(\"//electron/build/args/all.gn\")"
  gn_args+=" is_debug=false"
  gn_args+=" is_component_build=false"
  gn_args+=" is_component_ffmpeg=true"
  gn_args+=" is_official_build=true"
  gn_args+=" symbol_level=0"
  gn_args+=" blink_symbol_level=0"
  gn_args+=" enable_nacl=false"
  gn_args+=" target_cpu=\"$arch\""
  gn_args+=" override_electron_version=\"$ELECTRON_VERSION\""

  echo ">>> Generating build config (target_cpu=$arch)..."
  gn gen "$out_dir" --args="$gn_args"

  echo ">>> Building electron dist.zip..."
  ninja -C "$out_dir" electron:electron_dist_zip

  local dist_zip="$SRC_DIR/$out_dir/dist.zip"
  if [ ! -f "$dist_zip" ]; then
    echo "ERROR: dist.zip not found at $dist_zip"
    exit 1
  fi

  local output="$WORKSPACE/electron-win32-${arch}.zip"
  cp "$dist_zip" "$output"

  local size
  size=$(du -h "$dist_zip" | cut -f1)
  echo ">>> $arch build complete: $output ($size)"
}

# ── Build both architectures ──

build_arch x64
build_arch arm64

echo ""
echo ">>> Post-build disk space:"
df -h

# ── Release ──

echo ""
echo ">>> Creating GitHub release: $RELEASE_TAG"

cd "$REPO_ROOT"

X64_ZIP="$WORKSPACE/electron-win32-x64.zip"
ARM64_ZIP="$WORKSPACE/electron-win32-arm64.zip"

if gh release view "$RELEASE_TAG" &> /dev/null; then
  echo "    Release $RELEASE_TAG already exists, uploading artifacts..."
  gh release upload "$RELEASE_TAG" "$X64_ZIP" "$ARM64_ZIP" --clobber
else
  echo "    Creating new release..."
  gh release create "$RELEASE_TAG" \
    --title "Electron $RELEASE_TAG" \
    --generate-notes \
    "$X64_ZIP" \
    "$ARM64_ZIP"
fi

echo ""
echo "=== All done! Release: $RELEASE_TAG ==="
