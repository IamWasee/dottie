#!/bin/bash
# =============================================================================
# embed-needle.sh — puts Cactus Needle inside Dottie.app
#
# Runs as an Xcode build phase of the app target. Downloads a pinned engine
# and weights of Needle 3 and Whistle (Apache-2.0, Cactus Compute,
# https://github.com/cactus-compute/needle) from Hugging Face, checks each
# file's SHA-256, and puts:
#
#   Contents/Frameworks/libneedle3.dylib      the engine, arm64 + x86_64
#   Contents/Resources/Needle/needle3.cact    tool calls, extraction, vectors
#   Contents/Resources/Needle/whistle.cact    speech to text
#
# DottieNeedleEngine opens them with dlopen when first needed.
#
# The downloads are cached in ~/Library/Caches/Dottie-build, so only the
# first build after a version bump touches the network. If a download fails
# (offline, Hugging Face down) the build still succeeds with a warning and
# the app works as before, just without Needle.
#
# To update: change the commits, the engine version and the checksums
# below together (the Needle lab workflow prints all of them).
# =============================================================================
set -euo pipefail

NEEDLE_ENGINE_VERSION="3.3.3"
NEEDLE_REPOSITORY_COMMIT="d6c7d6a2e9655505e0f8e23339356dd1705900eb"
WHISTLE_REPOSITORY_COMMIT="741118687e1f008f06d1351a402a731274789790"

ARM64_WHEEL_SHA256="c5538e045fb26f0b6f911102516582d4434fbfa38aa28e5c2f3eb990b92aaf8d"
X86_64_WHEEL_SHA256="504b4e14dccff1d9a0591fcd78cc18063b99be396f6935a1c2b8189f0f8de89d"
NEEDLE_WEIGHTS_SHA256="c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38"
WHISTLE_WEIGHTS_SHA256="b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb"

NEEDLE_BASE_URL="https://huggingface.co/Cactus-Compute/needle3/resolve/${NEEDLE_REPOSITORY_COMMIT}"
WHISTLE_BASE_URL="https://huggingface.co/Cactus-Compute/whistle/resolve/${WHISTLE_REPOSITORY_COMMIT}"

CACHE_DIR="${HOME}/Library/Caches/Dottie-build/needle/${NEEDLE_ENGINE_VERSION}-${NEEDLE_REPOSITORY_COMMIT:0:8}-${WHISTLE_REPOSITORY_COMMIT:0:8}"
CACHED_LIBRARY="${CACHE_DIR}/libneedle3.dylib"

# Xcode sets these; fall back to the build products dir for manual runs.
APP_CONTENTS="${TARGET_BUILD_DIR:?run from Xcode or set TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH:?}"
FRAMEWORKS_DIR="${APP_CONTENTS}/Frameworks"
NEEDLE_RESOURCES_DIR="${APP_CONTENTS}/Resources/Needle"

warn() {
    # Xcode shows lines starting with "warning:" in the issue navigator.
    echo "warning: Needle not bundled: $*"
    echo "warning: Dottie works as before without it (no on-Mac tool calls, meaning matches or Whistle)."
    exit 0
}

# download_checked <url> <destination> <expected sha256>
download_checked() {
    local source_url="$1" destination_path="$2" expected_sha="$3" actual_sha
    curl -fsSL --retry 2 -o "$destination_path" "$source_url" || warn "couldn't download ${source_url}"
    actual_sha="$(shasum -a 256 "$destination_path" | awk '{print $1}')"
    [[ "$actual_sha" == "$expected_sha" ]] \
        || warn "$(basename "$destination_path") doesn't match its checksum (expected ${expected_sha}, got ${actual_sha})"
}

download_needle() {
    local download_dir
    download_dir="$(mktemp -d)"
    trap 'rm -rf "$download_dir"' RETURN

    echo "Downloading Needle ${NEEDLE_ENGINE_VERSION} and Whistle"
    local wheel_prefix="${NEEDLE_BASE_URL}/python/cactus_needle-${NEEDLE_ENGINE_VERSION}-py3-none-macosx_11_0"
    download_checked "${wheel_prefix}_arm64.whl" "${download_dir}/arm64.whl" "$ARM64_WHEEL_SHA256"
    download_checked "${wheel_prefix}_x86_64.whl" "${download_dir}/x86_64.whl" "$X86_64_WHEEL_SHA256"
    download_checked "${NEEDLE_BASE_URL}/needle3.cact" "${download_dir}/needle3.cact" "$NEEDLE_WEIGHTS_SHA256"
    download_checked "${WHISTLE_BASE_URL}/whistle.cact" "${download_dir}/whistle.cact" "$WHISTLE_WEIGHTS_SHA256"
    # The Apache-2.0 license travels with the files; it's text, so no pin.
    curl -fsSL --retry 2 -o "${download_dir}/LICENSE" "${NEEDLE_BASE_URL}/LICENSE" || rm -f "${download_dir}/LICENSE"

    # A wheel is a zip; the engine is needle/libneedle3.dylib inside it.
    mkdir -p "${download_dir}/arm64" "${download_dir}/x86_64"
    unzip -q -o -j "${download_dir}/arm64.whl" "needle/libneedle3.dylib" -d "${download_dir}/arm64" \
        || warn "the arm64 wheel has no needle/libneedle3.dylib"
    unzip -q -o -j "${download_dir}/x86_64.whl" "needle/libneedle3.dylib" -d "${download_dir}/x86_64" \
        || warn "the x86_64 wheel has no needle/libneedle3.dylib"

    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR"
    lipo -create "${download_dir}/arm64/libneedle3.dylib" "${download_dir}/x86_64/libneedle3.dylib" -output "$CACHED_LIBRARY" \
        || warn "couldn't join the arm64 and x86_64 engines"
    mv "${download_dir}/needle3.cact" "${download_dir}/whistle.cact" "$CACHE_DIR/"
    [[ -f "${download_dir}/LICENSE" ]] && mv "${download_dir}/LICENSE" "$CACHE_DIR/LICENSE"
    return 0
}

if [[ ! -f "$CACHED_LIBRARY" || ! -f "${CACHE_DIR}/needle3.cact" || ! -f "${CACHE_DIR}/whistle.cact" ]]; then
    download_needle
fi

mkdir -p "$FRAMEWORKS_DIR" "$NEEDLE_RESOURCES_DIR"
ditto "$CACHED_LIBRARY" "${FRAMEWORKS_DIR}/libneedle3.dylib"
# Executable, so the release workflow's re-signing loop finds it.
chmod 755 "${FRAMEWORKS_DIR}/libneedle3.dylib"
ditto "${CACHE_DIR}/needle3.cact" "${NEEDLE_RESOURCES_DIR}/needle3.cact"
ditto "${CACHE_DIR}/whistle.cact" "${NEEDLE_RESOURCES_DIR}/whistle.cact"
if [[ -f "${CACHE_DIR}/LICENSE" ]]; then
    cp "${CACHE_DIR}/LICENSE" "${NEEDLE_RESOURCES_DIR}/LICENSE"
fi

# Nested code has to be signed before Xcode signs the app around it. Unsigned
# builds (like CI's) skip this; "-" is an ad-hoc "Sign to Run Locally" build.
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    if [[ "$EXPANDED_CODE_SIGN_IDENTITY" == "-" ]]; then
        codesign --force --sign - "${FRAMEWORKS_DIR}/libneedle3.dylib"
    else
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp "${FRAMEWORKS_DIR}/libneedle3.dylib"
    fi
fi

echo "Bundled Needle ${NEEDLE_ENGINE_VERSION} at Contents/Frameworks/libneedle3.dylib with needle3.cact and whistle.cact"
