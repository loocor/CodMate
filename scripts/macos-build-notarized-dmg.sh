#!/usr/bin/env bash

set -euo pipefail

# CodMate macOS notarized DMG builder
# - Archives via xcodebuild
# - Exports signed Developer ID app
# - Builds DMG (create-dmg if available, otherwise hdiutil)
# - Notarizes with notarytool and staples
#
# Loads .env from repo root if present (APPLE_SIGNING_IDENTITY, APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID)
# Usage (with Keychain profile):
#   APPLE_NOTARY_PROFILE="AC_PROFILE_NAME" \
#   ./scripts/macos-build-notarized-dmg.sh
#
# Usage (with Apple ID + app-specific password):
#   APPLE_ID="appleid@example.com" \
#   APPLE_PASSWORD="abcd-efgh-ijkl-mnop" \
#   TEAM_ID="YOURTEAMID" \
#   ./scripts/macos-build-notarized-dmg.sh
#
# Default behavior: builds two notarized DMGs, one for arm64 and one for x86_64.
# Optional overrides:
#   SCHEME (default: CodMate)
#   PROJECT (default: codmate.xcodeproj)
#   CONFIG (default: Release)
#   ARCH_MATRIX (default: "arm64 x86_64"), e.g. set to "arm64" to build only arm64
#   SIGNING_CERT (default: Developer ID Application; maps from APPLE_SIGNING_IDENTITY if present)
#   VERSION (if set, will override Marketing Version at export time when possible)
#

SCHEME="${SCHEME:-CodMate}"
PROJECT="${PROJECT:-codmate.xcodeproj}"
CONFIG="${CONFIG:-Release}"
# Default: build two independent DMGs, one for each arch
ARCH_MATRIX=( ${ARCH_MATRIX:-arm64 x86_64} )
SIGNING_CERT="${SIGNING_CERT:-}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Downloads}"
DERIVED_DATA="$BUILD_DIR/DerivedData"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# Load .env without overriding explicitly exported vars
ENV_FILE="$ROOT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  while IFS='=' read -r k v; do
    [[ -z "${k// /}" ]] && continue
    [[ "$k" =~ ^# ]] && continue
    case "$k" in
      APPLE_SIGNING_IDENTITY|APPLE_ID|APPLE_PASSWORD|APPLE_TEAM_ID)
        if [[ -z "${!k:-}" ]]; then
          # Trim possible quotes
          v="${v%\r}"; v="${v%\n}"; v="${v%"\""}"; v="${v#"\""}"
          export "$k=$v"
        fi
        ;;
      *) ;;
    esac
  done < "$ENV_FILE"
fi

# Map env into script variables
TEAM_ID="${TEAM_ID:-${APPLE_TEAM_ID:-}}"
if [[ -z "$SIGNING_CERT" ]]; then
  if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    SIGNING_CERT="$APPLE_SIGNING_IDENTITY"
  else
    SIGNING_CERT="Developer ID Application"
  fi
fi

for ARCH in "${ARCH_MATRIX[@]}"; do
  ARCHIVE_PATH="$BUILD_DIR/$SCHEME-$ARCH.xcarchive"
  EXPORT_DIR="$BUILD_DIR/export-$ARCH"
  mkdir -p "$EXPORT_DIR"

  echo "[1/7][$ARCH] Archiving $SCHEME (project: $PROJECT, config: $CONFIG)"
  if command -v xcpretty >/dev/null 2>&1; then
    xcrun xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIG" \
      -destination 'generic/platform=macOS' \
      -derivedDataPath "$DERIVED_DATA" \
      -archivePath "$ARCHIVE_PATH" \
      archive \
      CODE_SIGN_STYLE=Automatic \
      DEVELOPMENT_TEAM="${TEAM_ID:-}" \
      CODE_SIGN_IDENTITY="${SIGNING_CERT}" \
      ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES \
      | xcpretty
  else
    xcrun xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIG" \
      -destination 'generic/platform=macOS' \
      -derivedDataPath "$DERIVED_DATA" \
      -archivePath "$ARCHIVE_PATH" \
      archive \
      CODE_SIGN_STYLE=Automatic \
      DEVELOPMENT_TEAM="${TEAM_ID:-}" \
      CODE_SIGN_IDENTITY="${SIGNING_CERT}" \
      ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES
  fi

  echo "[2/7][$ARCH] Preparing ExportOptions.plist"
  cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>${TEAM_ID:-}</string>
  <key>signingCertificate</key>
  <string>${SIGNING_CERT}</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>compileBitcode</key>
  <false/>
</dict>
</plist>
PLIST

  echo "[3/7][$ARCH] Exporting signed app"
  if command -v xcpretty >/dev/null 2>&1; then
    xcrun xcodebuild -exportArchive \
      -archivePath "$ARCHIVE_PATH" \
      -exportPath "$EXPORT_DIR" \
      -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
      | xcpretty
  else
    xcrun xcodebuild -exportArchive \
      -archivePath "$ARCHIVE_PATH" \
      -exportPath "$EXPORT_DIR" \
      -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
  fi

  APP_PATH=$(find "$EXPORT_DIR" -maxdepth 1 -name "*.app" -print -quit)
  if [[ -z "${APP_PATH}" ]]; then
    echo "[ERROR][$ARCH] Exported app not found in $EXPORT_DIR" >&2
    exit 1
  fi

  echo "[verify][$ARCH] codesign (deep, strict)"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"

  # Verify requested architecture exists in main executable
  MAIN_EXEC=$(defaults read "$APP_PATH/Contents/Info" CFBundleExecutable 2>/dev/null || true)
  if [[ -n "$MAIN_EXEC" && -f "$APP_PATH/Contents/MacOS/$MAIN_EXEC" ]]; then
    LIPO_INFO=$(lipo -info "$APP_PATH/Contents/MacOS/$MAIN_EXEC" 2>/dev/null || true)
    echo "[verify][$ARCH] lipo: $LIPO_INFO"
    if [[ "$LIPO_INFO" != *"$ARCH"* ]]; then
      echo "[ERROR][$ARCH] Expected $ARCH slice in main executable, got: $LIPO_INFO" >&2
      exit 1
    fi
  fi

  echo "[info][$ARCH] Extracting version from Info.plist"
  APP_BUNDLE_ID=$(defaults read "$APP_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
  APP_VERSION=$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
  if [[ -n "${VERSION:-}" ]]; then
    APP_VERSION="$VERSION"
  fi
  APP_VERSION=${APP_VERSION:-0.0.0}

  PRODUCT_NAME=$(basename "$APP_PATH" .app)
  DMG_NAME="$PRODUCT_NAME-$APP_VERSION-$ARCH.dmg"
  DMG_PATH="$OUTPUT_DIR/$DMG_NAME"

make_dmg_with_hdiutil() {
  local src_app="$1"; local dmg_path="$2"; local vol_name="$3"
  local tmp_dmg="$BUILD_DIR/tmp.dmg"
  local mnt_dir="$BUILD_DIR/mnt"

  echo "[4/7] Creating DMG via hdiutil"
  rm -f "$tmp_dmg" "$dmg_path"
  hdiutil create -size 300m -fs HFS+ -volname "$vol_name" "$tmp_dmg"
  mkdir -p "$mnt_dir"
  hdiutil attach "$tmp_dmg" -mountpoint "$mnt_dir" -nobrowse -quiet
  mkdir -p "$mnt_dir/.background" || true
  cp -R "$src_app" "$mnt_dir/"
  ln -s /Applications "$mnt_dir/Applications"
  sync
  hdiutil detach "$mnt_dir" -quiet
  hdiutil convert "$tmp_dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg_path" >/dev/null
  rm -f "$tmp_dmg"
}

if command -v create-dmg >/dev/null 2>&1; then
  echo "[4/7][$ARCH] Creating DMG via create-dmg"
  rm -f "$DMG_PATH"
  create-dmg \
    --volname "$PRODUCT_NAME" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 96 \
    --hide-extension "$PRODUCT_NAME.app" \
    --app-drop-link 425 200 \
    "$DMG_PATH" \
    "$APP_PATH"
else
  make_dmg_with_hdiutil "$APP_PATH" "$DMG_PATH" "$PRODUCT_NAME"
fi

echo "[5/7][$ARCH] Notarizing DMG"
if [[ -n "${APPLE_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$APPLE_NOTARY_PROFILE" \
    --wait
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${TEAM_ID:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait
else
  echo "[WARN][$ARCH] Notarization credentials not provided. Skipping notarization."
  echo "       Provide APPLE_NOTARY_PROFILE or APPLE_ID/APPLE_PASSWORD/TEAM_ID to notarize."
fi

echo "[6/7][$ARCH] Stapling tickets (DMG and app)"
if xcrun stapler staple -v "$DMG_PATH"; then
  echo "[staple][$ARCH] DMG stapled"
else
  echo "[WARN][$ARCH] DMG staple skipped or failed"
fi
if xcrun stapler staple -v "$APP_PATH"; then
  echo "[staple][$ARCH] App stapled"
else
  echo "[WARN][$ARCH] App staple skipped or failed"
fi

echo "[7/7][$ARCH] Verifying Gatekeeper assessment"
spctl -a -t open --context context:primary-signature -vv "$APP_PATH" || true
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" || true

echo ""
echo "Done [$ARCH]. DMG: $DMG_PATH"
echo "Bundle ID: ${APP_BUNDLE_ID:-unknown}, Version: $APP_VERSION"
done
