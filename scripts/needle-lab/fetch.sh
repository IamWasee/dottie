#!/bin/bash
# Downloads the Needle engine and weights and prints what to pin.
#
# By default it fetches the same commits and engine version that
# scripts/embed-needle.sh pins, so the lab tests what Dottie ships.
# Pass "latest" as the second argument to try Hugging Face's newest files
# before bumping the pins.
set -euo pipefail
out="$1"; mkdir -p "$out/wheels"
which_files="${2:-pinned}"
hf=https://huggingface.co
pins="$(dirname "$0")/../embed-needle.sh"
pinned_value() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$pins"; }
if [ "$which_files" = "latest" ]; then
  needle_ref=main; whistle_ref=main; engine_version=3.3.3
else
  needle_ref="$(pinned_value NEEDLE_REPOSITORY_COMMIT)"
  whistle_ref="$(pinned_value WHISTLE_REPOSITORY_COMMIT)"
  engine_version="$(pinned_value NEEDLE_ENGINE_VERSION)"
fi
echo "== testing $which_files files: needle3@$needle_ref whistle@$whistle_ref engine $engine_version"
for repo in needle3 whistle; do
  echo "== $repo commit: $(curl -fsSL "$hf/api/models/Cactus-Compute/$repo" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("sha"), d.get("lastModified"))')"
done
curl -fsSL "$hf/api/models/Cactus-Compute/needle3/tree/main?recursive=1" | python3 -c '
import sys, json
for f in json.load(sys.stdin):
    p = f["path"]
    if f["type"] == "file" and ("mac" in p or p.endswith(".cact") or p.endswith(".h") or "ios" in p):
        print(p, f.get("size"), (f.get("lfs") or {}).get("oid", ""))'
curl -fsSL "$hf/api/models/Cactus-Compute/whistle/tree/main?recursive=1" | python3 -c '
import sys, json
for f in json.load(sys.stdin):
    if f["type"] == "file": print(f["path"], f.get("size"), (f.get("lfs") or {}).get("oid", ""))'
for arch in arm64 x86_64; do
  curl -fsSL -o "$out/wheels/$arch.whl" "$hf/Cactus-Compute/needle3/resolve/$needle_ref/python/cactus_needle-$engine_version-py3-none-macosx_11_0_$arch.whl"
  unzip -l "$out/wheels/$arch.whl"
  unzip -o -j "$out/wheels/$arch.whl" "needle/libneedle3.dylib" -d "$out/wheels/$arch"
done
lipo -create "$out/wheels/arm64/libneedle3.dylib" "$out/wheels/x86_64/libneedle3.dylib" -output "$out/libneedle3.dylib"
curl -fsSL -o "$out/needle3.cact" "$hf/Cactus-Compute/needle3/resolve/$needle_ref/needle3.cact"
curl -fsSL -o "$out/whistle.cact" "$hf/Cactus-Compute/whistle/resolve/$whistle_ref/whistle.cact"
curl -fsSL -o "$out/needle.h" "$hf/Cactus-Compute/needle3/resolve/$needle_ref/macos-arm64/needle.h" || echo "no header at macos-arm64/needle.h"
shasum -a 256 "$out"/wheels/*.whl "$out"/wheels/*/libneedle3.dylib "$out"/*.cact "$out/libneedle3.dylib"
ls -la "$out"
lipo -info "$out/libneedle3.dylib"
otool -L "$out/wheels/arm64/libneedle3.dylib"
otool -l "$out/wheels/arm64/libneedle3.dylib" | grep -A4 -E "LC_BUILD_VERSION|LC_VERSION_MIN" | head -12
nm -gU "$out/wheels/arm64/libneedle3.dylib" | grep -i needle
codesign -dv "$out/wheels/arm64/libneedle3.dylib" 2>&1 | head -5 || true
[ -f "$out/needle.h" ] && cat "$out/needle.h"
codesign --force --sign - "$out/libneedle3.dylib"
