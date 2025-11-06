#!/usr/bin/env bash

set -euo pipefail

# CodMate unified build script
# Builds both Developer ID (notarized DMG) and Mac App Store (PKG) distributions
#
# Usage:
#   ./scripts/macos-build-all.sh
#
# Optional overrides (passed to both subscripts):
#   VERSION=1.0.0 ./scripts/macos-build-all.sh
#   UPLOAD=1 ./scripts/macos-build-all.sh  # Upload MAS to App Store Connect
#   BUILD_MAS_ONLY=1 ./scripts/macos-build-all.sh  # Skip Developer ID
#   BUILD_DEVID_ONLY=1 ./scripts/macos-build-all.sh  # Skip MAS

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_MAS_ONLY="${BUILD_MAS_ONLY:-0}"
BUILD_DEVID_ONLY="${BUILD_DEVID_ONLY:-0}"

echo "========================================"
echo "  CodMate - Unified Build Script"
echo "========================================"
echo "Root: $ROOT_DIR"
echo ""

# Validate that both scripts exist
DEVID_SCRIPT="$SCRIPT_DIR/macos-build-notarized-dmg.sh"
MAS_SCRIPT="$SCRIPT_DIR/macos-build-mas.sh"

if [[ ! -f "$DEVID_SCRIPT" ]]; then
  echo "[ERROR] Developer ID script not found: $DEVID_SCRIPT" >&2
  exit 1
fi

if [[ ! -f "$MAS_SCRIPT" ]]; then
  echo "[ERROR] MAS script not found: $MAS_SCRIPT" >&2
  exit 1
fi

# Build Developer ID distribution (notarized DMG)
if [[ "$BUILD_MAS_ONLY" != "1" ]]; then
  echo "[1/2] Building Developer ID distribution..."
  echo "=========================================="
  if ! "$DEVID_SCRIPT"; then
    echo "[ERROR] Developer ID build failed" >&2
    exit 1
  fi
  echo ""
  echo "[✓] Developer ID build complete"
  echo ""
else
  echo "[SKIP] Developer ID build (BUILD_MAS_ONLY=1)"
  echo ""
fi

# Build Mac App Store distribution (PKG)
if [[ "$BUILD_DEVID_ONLY" != "1" ]]; then
  echo "[2/2] Building Mac App Store distribution..."
  echo "=========================================="
  if ! "$MAS_SCRIPT"; then
    echo "[ERROR] MAS build failed" >&2
    exit 1
  fi
  echo ""
  echo "[✓] MAS build complete"
  echo ""
else
  echo "[SKIP] MAS build (BUILD_DEVID_ONLY=1)"
  echo ""
fi

echo "========================================"
echo "  All Builds Complete!"
echo "========================================"
echo "Output directory: ${OUTPUT_DIR:-$HOME/Downloads}"
echo ""
echo "Next steps:"
if [[ "$BUILD_DEVID_ONLY" != "1" ]]; then
  echo "  - MAS: Upload PKG to App Store Connect via Transporter"
  echo "         or set UPLOAD=1 to auto-upload"
fi
if [[ "$BUILD_MAS_ONLY" != "1" ]]; then
  echo "  - Developer ID: DMG files are ready for distribution"
fi
echo "========================================"
