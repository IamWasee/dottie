#!/bin/bash
# Downloads the Needle engine and weights and prints what to pin.
set -euo pipefail
out="$1"; mkdir -p "$out/wheels"
hf=https://huggingface.co
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
  curl -fsSL -o "$out/wheels/$arch.whl" "$hf/Cactus-Compute/needle3/resolve/main/python/cactus_needle-3.3.3-py3-none-macosx_11_0_$arch.whl"
  unzip -l "$out/wheels/$arch.whl"
  unzip -o -j "$out/wheels/$arch.whl" "needle/libneedle3.dylib" -d "$out/wheels/$arch"
done
lipo -create "$out/wheels/arm64/libneedle3.dylib" "$out/wheels/x86_64/libneedle3.dylib" -output "$out/libneedle3.dylib"
curl -fsSL -o "$out/needle3.cact" "$hf/Cactus-Compute/needle3/resolve/main/needle3.cact"
curl -fsSL -o "$out/whistle.cact" "$hf/Cactus-Compute/whistle/resolve/main/whistle.cact"
curl -fsSL -o "$out/needle.h" "$hf/Cactus-Compute/needle3/resolve/main/macos-arm64/needle.h" || echo "no header at macos-arm64/needle.h"
shasum -a 256 "$out"/wheels/*.whl "$out"/wheels/*/libneedle3.dylib "$out"/*.cact "$out/libneedle3.dylib"
ls -la "$out"
lipo -info "$out/libneedle3.dylib"
otool -L "$out/wheels/arm64/libneedle3.dylib"
otool -l "$out/wheels/arm64/libneedle3.dylib" | grep -A4 -E "LC_BUILD_VERSION|LC_VERSION_MIN" | head -12
nm -gU "$out/wheels/arm64/libneedle3.dylib" | grep -i needle
codesign -dv "$out/wheels/arm64/libneedle3.dylib" 2>&1 | head -5 || true
[ -f "$out/needle.h" ] && cat "$out/needle.h"
codesign --force --sign - "$out/libneedle3.dylib"
