#!/bin/bash
# Builds a universal (arm64 + x86_64) librashader.dylib from the pinned release tag in LIBRASHADER_VERSION.
#   scripts/build-librashader.sh [output-dir]
# The C headers in Sources/LibraBridge/vendor must come from the same tag (checked below).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAG=$(tr -d '[:space:]' < "$ROOT/LIBRASHADER_VERSION")
OUT=${1:-$ROOT/build/librashader}
mkdir -p "$OUT" && OUT=$(cd "$OUT" && pwd)
SRC=${LIBRASHADER_SRC:-$ROOT/build/librashader-src}

if [ ! -d "$SRC/.git" ]; then
  git clone --quiet --depth 1 --branch "$TAG" https://github.com/SnowflakePowered/librashader "$SRC"
fi
for h in librashader.h librashader_ld.h; do
  if ! cmp -s "$SRC/include/$h" "$ROOT/Sources/LibraBridge/vendor/$h"; then
    echo "error: Sources/LibraBridge/vendor/$h is not the header of $TAG" >&2
    exit 1
  fi
done

export MACOSX_DEPLOYMENT_TARGET=13.0
cd "$SRC"
for t in aarch64-apple-darwin x86_64-apple-darwin; do
  rustup target add "$t"
  # "stable" lets the C API build on stable Rust; the headers come from the release itself.
  cargo build --locked -p librashader-capi --profile optimized --features stable --target "$t"
done
mkdir -p "$OUT"
lipo -create \
  target/aarch64-apple-darwin/optimized/liblibrashader_capi.dylib \
  target/x86_64-apple-darwin/optimized/liblibrashader_capi.dylib \
  -output "$OUT/librashader.dylib"
install_name_tool -id @rpath/librashader.dylib "$OUT/librashader.dylib"
cp LICENSE.md "$OUT/LICENSE-librashader.md"
cp LICENSE-GPL.md "$OUT/LICENSE-librashader-GPL.md"
echo "$TAG" > "$OUT/VERSION"
lipo -info "$OUT/librashader.dylib"
