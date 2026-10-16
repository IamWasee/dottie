#!/bin/bash
# =============================================================================
# embed-cua-driver.sh — puts cua-driver inside Dottie.app
#
# Runs as an Xcode build phase of the app target. Downloads a pinned release
# of cua-driver (MIT, https://github.com/trycua/cua), checks it against the
# release's SHA256SUMS, and copies the universal binary to
# Dottie.app/Contents/Helpers/cua-driver, where ClickyComputerUse looks
# first. Shipped Clicky bundles the driver the same way, so Dots can click
# and type without the user installing anything.
#
# The download is cached in ~/Library/Caches/Dottie-build, so only the first
# build after a version bump touches the network. If the download fails
# (offline, GitHub down) the build still succeeds with a warning, and the app
# falls back to a driver installed in ~/.local/bin.
#
# To update the driver, change CUA_DRIVER_VERSION below. Versions listed in
# trycua/cua's .github/release-state/cua-driver-rs-withdrawn-versions must
# never be used.
# =============================================================================
set -euo pipefail

CUA_DRIVER_VERSION="0.36.0"
RELEASE_TAG="cua-driver-rs-v${CUA_DRIVER_VERSION}"
TARBALL_NAME="cua-driver-rs-${CUA_DRIVER_VERSION}-darwin-universal.tar.gz"
STAGE_NAME="cua-driver-rs-${CUA_DRIVER_VERSION}-darwin-universal"
RELEASE_URL="https://github.com/trycua/cua/releases/download/${RELEASE_TAG}"

CACHE_DIR="${HOME}/Library/Caches/Dottie-build/cua-driver/${CUA_DRIVER_VERSION}"
CACHED_BINARY="${CACHE_DIR}/${STAGE_NAME}/cua-driver"

# Xcode sets these; fall back to the build products dir for manual runs.
APP_CONTENTS="${TARGET_BUILD_DIR:?run from Xcode or set TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH:?}"
HELPERS_DIR="${APP_CONTENTS}/Helpers"
RESOURCES_DIR="${APP_CONTENTS}/Resources"

warn() {
    # Xcode shows lines starting with "warning:" in the issue navigator.
    echo "warning: cua-driver not bundled: $*"
    echo "warning: Dots can still use a cua-driver installed with the official installer."
    exit 0
}

download_driver() {
    local download_dir
    download_dir="$(mktemp -d)"
    trap 'rm -rf "$download_dir"' RETURN

    echo "Downloading cua-driver ${CUA_DRIVER_VERSION}"
    curl -fsSL --retry 2 -o "${download_dir}/${TARBALL_NAME}" "${RELEASE_URL}/${TARBALL_NAME}" \
        || warn "couldn't download ${RELEASE_URL}/${TARBALL_NAME}"
    curl -fsSL --retry 2 -o "${download_dir}/SHA256SUMS" "${RELEASE_URL}/SHA256SUMS" \
        || warn "couldn't download the release's SHA256SUMS"

    local expected_sha actual_sha
    expected_sha="$(awk -v f="${TARBALL_NAME}" '$2 == f || $2 == "*" f { print $1; exit }' "${download_dir}/SHA256SUMS")"
    [[ -n "$expected_sha" ]] || warn "${TARBALL_NAME} isn't listed in SHA256SUMS"
    actual_sha="$(shasum -a 256 "${download_dir}/${TARBALL_NAME}" | awk '{print $1}')"
    [[ "$actual_sha" == "$expected_sha" ]] \
        || warn "${TARBALL_NAME} doesn't match its checksum (expected ${expected_sha}, got ${actual_sha})"

    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR"
    tar -xzf "${download_dir}/${TARBALL_NAME}" -C "$CACHE_DIR"
    [[ -f "$CACHED_BINARY" ]] || warn "the release archive has no ${STAGE_NAME}/cua-driver"
}

if [[ ! -x "$CACHED_BINARY" ]]; then
    download_driver
fi

mkdir -p "$HELPERS_DIR" "$RESOURCES_DIR"
ditto "$CACHED_BINARY" "${HELPERS_DIR}/cua-driver"
chmod 755 "${HELPERS_DIR}/cua-driver"

# The MIT license and third-party notices travel with the binary.
for notice_name in LICENSE THIRD_PARTY_NOTICES.md; do
    if [[ -f "${CACHE_DIR}/${STAGE_NAME}/${notice_name}" ]]; then
        cp "${CACHE_DIR}/${STAGE_NAME}/${notice_name}" "${RESOURCES_DIR}/cua-driver-${notice_name}"
    fi
done

# Nested code has to be signed before Xcode signs the app around it. Unsigned
# builds (like CI's) skip this; "-" is an ad-hoc "Sign to Run Locally" build.
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    if [[ "$EXPANDED_CODE_SIGN_IDENTITY" == "-" ]]; then
        codesign --force --sign - "${HELPERS_DIR}/cua-driver"
    else
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp "${HELPERS_DIR}/cua-driver"
    fi
fi

echo "Bundled cua-driver ${CUA_DRIVER_VERSION} at Contents/Helpers/cua-driver"
