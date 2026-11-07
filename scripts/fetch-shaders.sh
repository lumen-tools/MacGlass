#!/bin/bash
# Fetches the shader libraries into <output>/ (default build/Shaders):
#   shaders_slang/    current libretro/slang-shaders (or SLANG_SHADERS_REF)
#   rc/retro crisis/  newest release of RetroCrisis/Retro-Crisis-GDV-NTSC (or RETRO_CRISIS_TAG)
# Same layout as RetroArch/DeckGlass, so Retro Crisis' "../../../shaders_slang/..." paths resolve.
# Needs the GitHub CLI (gh) for the Retro Crisis release.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/build/Shaders}
TMP=$(mktemp -d)
rm -rf "$OUT"
mkdir -p "$OUT/rc"

# libretro slang-shaders
REF=${SLANG_SHADERS_REF:-master}
git init -q "$TMP/slang"
git -C "$TMP/slang" remote add origin https://github.com/libretro/slang-shaders.git
git -C "$TMP/slang" fetch -q --depth 1 origin "$REF"
git -C "$TMP/slang" checkout -q FETCH_HEAD
SLANG_COMMIT=$(git -C "$TMP/slang" rev-parse HEAD)
rm -rf "$TMP/slang/.git" "$TMP/slang/.github"
mv "$TMP/slang" "$OUT/shaders_slang"

# Retro Crisis GDV-NTSC (newest release)
RC_REPO=RetroCrisis/Retro-Crisis-GDV-NTSC
TAG=${RETRO_CRISIS_TAG:-$(gh release view --repo "$RC_REPO" --json tagName -q .tagName)}
mkdir -p "$TMP/rc-zip" "$TMP/rc"
gh release download "$TAG" --repo "$RC_REPO" --pattern '*.zip' --dir "$TMP/rc-zip"
for z in "$TMP"/rc-zip/*.zip; do unzip -q -o "$z" -d "$TMP/rc"; done
RC_DIR=$(find "$TMP/rc" -maxdepth 3 -type d -iname 'retro crisis' | head -n 1)
if [ -z "$RC_DIR" ]; then
  echo "error: no 'retro crisis' folder in the $TAG release" >&2
  find "$TMP/rc" -maxdepth 3 | head -n 30 >&2
  exit 1
fi
mv "$RC_DIR" "$OUT/rc/retro crisis"
gh api "repos/$RC_REPO/contents/LICENSE?ref=$TAG" -H "Accept: application/vnd.github.raw" > "$OUT/rc/LICENSE" || true

find "$OUT" \( -name '__MACOSX' -o -name '._*' -o -name '.DS_Store' \) -prune -exec rm -rf {} +
cat > "$OUT/VERSIONS.txt" <<VERS
libretro/slang-shaders $SLANG_COMMIT
$RC_REPO $TAG
VERS
cat "$OUT/VERSIONS.txt"
echo "presets: RetroArch $(find "$OUT/shaders_slang" -name '*.slangp' | wc -l), Retro Crisis $(find "$OUT/rc" -name '*.slangp' | wc -l)"
rm -rf "$TMP"
