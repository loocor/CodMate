#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Generate macOS AppIcon set (AppIcon.appiconset) from a source image (PNG/PDF/ICNS) or a directory.

Usage:
  scripts/gen-icons.sh [-c|--copy-only] <source-file-or-dir> [output-appiconset-dir]

Defaults:
  output-appiconset-dir: CodMate/Assets.xcassets/AppIcon.appiconset

Notes:
  - Requires macOS 'sips' utility (only when resizing).
  - If <source> is a directory and --copy-only is used, files are picked by name/dimensions and copied without resizing.
  - If --copy-only is not used, the largest image becomes master and is resized to required slots.
USAGE
}

COPY_ONLY=0
if [[ ${1:-} == "-h" || ${1:-} == "--help" || $# -lt 1 ]]; then
  usage; exit 0
fi

if [[ ${1:-} == "-c" || ${1:-} == "--copy-only" ]]; then
  COPY_ONLY=1; shift
fi

SRC="$1"; shift || true
DST="${1:-CodMate/Assets.xcassets/AppIcon.appiconset}"

mkdir -p "$DST"

pick_master() {
  local path="$1"
  if [[ -d "$path" ]]; then
    # pick largest png/pdf/icns
    local cand
    cand=$(find "$path" -type f \( -iname "*.png" -o -iname "*.pdf" -o -iname "*.icns" \) -print0 \
      | xargs -0 stat -f "%z %N" 2>/dev/null \
      | sort -nr | head -n1 | cut -d' ' -f2-)
    echo "$cand"
  else
    echo "$path"
  fi
}

slots=(
  "16 1 icon_16x16.png"
  "16 2 icon_16x16@2x.png"
  "32 1 icon_32x32.png"
  "32 2 icon_32x32@2x.png"
  "128 1 icon_128x128.png"
  "128 2 icon_128x128@2x.png"
  "256 1 icon_256x256.png"
  "256 2 icon_256x256@2x.png"
  "512 1 icon_512x512.png"
  "512 2 icon_512x512@2x.png"
)

copy_slot() {
  local size="$1" scale="$2" name="$3"
  local want=$((size*scale))
  local dir="$SRC"

  # 1) exact file name match
  if [[ -f "$dir/$name" ]]; then
    cp -f "$dir/$name" "$DST/$name"; return 0
  fi
  # 2) pattern match by name (e.g. foo-16x16.png or foo-16x16@2x.png)
  local pat
  if [[ "$scale" == 2 ]]; then pat="*${size}x${size}@2x*.png"; else pat="*${size}x${size}*.png"; fi
  local cand=$(ls -1 "$dir"/$pat 2>/dev/null | head -n1 || true)
  if [[ -n "$cand" && -f "$cand" ]]; then cp -f "$cand" "$DST/$name"; return 0; fi
  # 3) pick by dimensions (no resize) if sips is available
  if command -v sips >/dev/null 2>&1; then
    local best=""
    while IFS= read -r -d '' f; do
      local w=$(sips -g pixelWidth "$f" 2>/dev/null | awk '/pixelWidth/ {print $2}')
      local h=$(sips -g pixelHeight "$f" 2>/dev/null | awk '/pixelHeight/ {print $2}')
      if [[ "$w" == "$want" && "$h" == "$want" ]]; then best="$f"; break; fi
    done < <(find "$dir" -type f -iname "*.png" -print0)
    if [[ -n "$best" ]]; then cp -f "$best" "$DST/$name"; return 0; fi
  fi
  echo "[WARN] Missing $name ($want x $want) in $SRC" >&2
  return 1
}

if [[ "$COPY_ONLY" == 1 ]]; then
  for slot in "${slots[@]}"; do
    set -- $slot; copy_slot "$1" "$2" "$3" || true
  done
else
  if ! command -v sips >/dev/null 2>&1; then
    echo "[ERROR] 'sips' not found; run with --copy-only or install Xcode CLT." >&2
    exit 1
  fi
  MASTER=$(pick_master "$SRC")
  if [[ -z "${MASTER}" || ! -f "$MASTER" ]]; then
    echo "[ERROR] No source image found at: $SRC" >&2
    exit 1
  fi
  WORKPNG="$DST/_master_1024.png"
  sips -s format png -Z 1024 "$MASTER" --out "$WORKPNG" >/dev/null
  gen() { local h="$1" w="$2" name="$3"; sips -z "$h" "$w" "$WORKPNG" --out "$DST/$name" >/dev/null; }
  gen 16 16   icon_16x16.png
  gen 32 32   icon_16x16@2x.png
  gen 32 32   icon_32x32.png
  gen 64 64   icon_32x32@2x.png
  gen 128 128 icon_128x128.png
  gen 256 256 icon_128x128@2x.png
  gen 256 256 icon_256x256.png
  gen 512 512 icon_256x256@2x.png
  gen 512 512 icon_512x512.png
  gen 1024 1024 icon_512x512@2x.png
  rm -f "$WORKPNG" || true
fi

# Ensure Contents.json exists (created earlier in repo, but keep idempotent)
if [[ ! -f "$DST/Contents.json" ]]; then
  cat > "$DST/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16",   "scale" : "1x", "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "size" : "16x16",   "scale" : "2x", "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "1x", "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "2x", "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON
fi

echo "[OK] AppIcon images generated in: $DST"
