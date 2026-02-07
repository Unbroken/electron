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

# src/electron is an unmanaged solution, so gclient never moves it to a new
# commit on its own. Update it here so an existing workspace can be reused
# after a rebase instead of being deleted and re-synced from scratch.
ELECTRON_SRC="$WORKSPACE/src/electron"
if [ -d "$ELECTRON_SRC/.git" ]; then
  echo ">>> Updating existing src/electron checkout to $COMMIT_SHA..."
  git -C "$ELECTRON_SRC" am --abort 2>/dev/null || true
  git -C "$ELECTRON_SRC" rebase --abort 2>/dev/null || true
  git -C "$ELECTRON_SRC" fetch --no-tags "$REPO_ROOT" "$COMMIT_SHA"
  git -C "$ELECTRON_SRC" checkout --force --detach "$COMMIT_SHA"
  git -C "$ELECTRON_SRC" clean -fd
else
  echo ">>> Cloning src/electron from local repo..."
  mkdir -p "$WORKSPACE/src"
  git clone --no-checkout "$REPO_ROOT" "$ELECTRON_SRC"
  git -C "$ELECTRON_SRC" checkout --force --detach "$COMMIT_SHA"
fi
# gclient compares the checkout's origin URL against the solution URL and moves
# mismatches aside into _bad_scm, so keep origin pointing at the real remote.
git -C "$ELECTRON_SRC" remote set-url origin "$REPO_URL"

# A previously failed patch application leaves .git/rebase-apply behind, which
# makes the next `git am` (run by the patch_chromium hook) refuse to start.
# gclient --reset does not clear this, so abort any in-progress `am` first.
echo ">>> Clearing stale patch state in dependency repos..."
grep -o '"repo": *"[^"]*"' "$ELECTRON_SRC/patches/config.json" | sed 's/.*: *"\(.*\)"/\1/' | while read -r repo; do
  if [ -d "$WORKSPACE/$repo/.git" ] || [ -f "$WORKSPACE/$repo/.git" ]; then
    git -C "$WORKSPACE/$repo" am --abort 2>/dev/null || true
  fi
done

# --force --reset: reset every dependency to the revision pinned in DEPS (this
#   drops previously applied patches; the DEPS hooks re-apply them afterwards).
# Dependencies whose pinned revision is unchanged are left as-is, so only
# what actually changed between the old and new Electron commit is fetched.
# Do NOT add -D (--delete_unversioned_trees): combined with --reset it deletes
# every untracked directory inside each checkout, which includes src/electron
# and the Node.js/nan checkouts nested inside the Chromium tree.
echo ">>> Syncing dependencies (incremental; first run may take a while)..."
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
