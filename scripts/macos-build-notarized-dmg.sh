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
#   SCHEME (default: CodMate (Direct) when SANDBOX=off, CodMate (MAS) when SANDBOX=on)
#   PROJECT (default: CodMate.xcodeproj)
#   CONFIG (default: Release-Direct when SANDBOX=off, Release-MAS when SANDBOX=on)
#   ARCH_MATRIX (default: "arm64 x86_64"), e.g. set to "arm64" to build only arm64
#   SIGNING_CERT (default: Developer ID Application; maps from APPLE_SIGNING_IDENTITY if present)
#   VERSION (if set, will override Marketing Version at export time when possible)
#   SANDBOX=on|off (default: off). When on, force App Sandbox entitlements (Mac App Store-style)
#   APPSTORE_SIM=1 to compile with APPSTORE condition (mimic Mac App Store build-time gating)
#   MIN_MACOS (default: 15.0) sets MACOSX_DEPLOYMENT_TARGET for all targets including packages
#

SCHEME="${SCHEME:-}"
PROJECT="${PROJECT:-CodMate.xcodeproj}"
CONFIG="${CONFIG:-}"
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

# ------------------------------
# Versioning strategy
# - BASE_VERSION: semantic version you set (e.g., 1.4.0). Defaults to 0.0.0
# - BUILD_NUMBER_STRATEGY: date | git | counter (default: date)
# - BUILD_COUNTER_FILE: when strategy=counter, stores/increments the counter (default: $BUILD_DIR/build-number)
# These values are applied to Xcode as MARKETING_VERSION (CFBundleShortVersionString)
# and CURRENT_PROJECT_VERSION (CFBundleVersion). The DMG name uses "BASE_VERSION+BUILD_NUMBER".
BASE_VERSION="${BASE_VERSION:-${VERSION:-0.0.0}}"
BUILD_NUMBER_STRATEGY="${BUILD_NUMBER_STRATEGY:-date}"

compute_build_number() {
  case "$BUILD_NUMBER_STRATEGY" in
    date)
      # yyyymmddHHMM as a single numeric component satisfies CFBundleVersion format
      date +%Y%m%d%H%M ;;
    git)
      (cd "$ROOT_DIR" && git rev-list --count HEAD 2>/dev/null) || echo 1 ;;
    counter)
      local f="${BUILD_COUNTER_FILE:-$BUILD_DIR/build-number}"
      mkdir -p "$(dirname "$f")"
      local n=0
      if [[ -f "$f" ]]; then n=$(cat "$f" 2>/dev/null || echo 0); fi
      n=$((n+1))
      echo "$n" > "$f"
      echo "$n" ;;
    *)
      date +%Y%m%d%H%M ;;
  esac
}

BUILD_NUMBER="$(compute_build_number)"
DISPLAY_VERSION="${BASE_VERSION}+${BUILD_NUMBER}"

# Compose extra xcodebuild args BEFORE starting the archive loop
EXTRA_XC_ARGS=()
if [[ "${APPSTORE_SIM:-0}" == "1" ]]; then
  # Prefer Swift 5+ macro; still pass OTHER_SWIFT_FLAGS for older setups
  # Also define SYSTEM_PACKAGE_DARWIN to satisfy swift-system 1.6+ platform gating
  EXTRA_XC_ARGS+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=APPSTORE")
  # Also define SUBPROCESS_ASYNCIO_DISPATCH so Subprocess picks the DispatchIO AsyncIO on macOS
  # Enable experimental features required by swift-subprocess main branch
  EXTRA_XC_ARGS+=("OTHER_SWIFT_FLAGS=-DAPPSTORE -DSYSTEM_PACKAGE_DARWIN -DSUBPROCESS_ASYNCIO_DISPATCH -enable-experimental-feature LifetimeDependence -enable-experimental-feature NonescapableTypes")
  echo "[info] APPSTORE_SIM=1 → compiling with -DAPPSTORE, -DSYSTEM_PACKAGE_DARWIN, -DSUBPROCESS_ASYNCIO_DISPATCH, experimental features"
fi

# Entitlements: sandbox on/off
SANDBOX="${SANDBOX:-off}"
if [[ "$SANDBOX" == "off" ]]; then
  EXTRA_XC_ARGS+=("CODE_SIGN_ENTITLEMENTS=")
  echo "[info] SANDBOX=off → building without App Sandbox entitlements"
else
  EXTRA_XC_ARGS+=("CODE_SIGN_ENTITLEMENTS=CodMate/CodMate.entitlements")
  echo "[info] SANDBOX=on  → App Sandbox entitlements enabled"
fi

if [[ -z "$SCHEME" ]]; then
  if [[ "$SANDBOX" == "off" ]]; then
    SCHEME="CodMate (Direct)"
  else
    SCHEME="CodMate (MAS)"
  fi
fi

if [[ -z "$CONFIG" ]]; then
  if [[ "$SANDBOX" == "off" ]]; then
    CONFIG="Release-Direct"
  else
    CONFIG="Release-MAS"
  fi
fi

echo "[info] Using scheme '$SCHEME' with configuration '$CONFIG'"

# Force a modern macOS deployment target to avoid arm64 + 10.13 mismatches in Swift packages
MIN_MACOS="${MIN_MACOS:-15.0}"
EXTRA_XC_ARGS+=("MACOSX_DEPLOYMENT_TARGET=${MIN_MACOS}")
echo "[info] MIN_MACOS=${MIN_MACOS} → MACOSX_DEPLOYMENT_TARGET=${MIN_MACOS}"

# Ensure Swift flags needed by some packages are always present for macOS builds
if [[ "${APPSTORE_SIM:-0}" != "1" ]]; then
  # Pass macOS-friendly defines so swift-system and swift-subprocess select the right code paths
  # Also enable experimental features required by swift-subprocess main branch
  EXTRA_XC_ARGS+=("OTHER_SWIFT_FLAGS=-DSYSTEM_PACKAGE_DARWIN -DSUBPROCESS_ASYNCIO_DISPATCH -enable-experimental-feature LifetimeDependence -enable-experimental-feature NonescapableTypes")
  echo "[info] Adding default Swift flags: -DSYSTEM_PACKAGE_DARWIN -DSUBPROCESS_ASYNCIO_DISPATCH -enable-experimental-feature LifetimeDependence"
fi

# Pre-resolve packages so we can apply any necessary build-time patches
echo "[prep] Resolving Swift packages (to enable pre-build patches)"
xcrun xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED_DATA" \
  -resolvePackageDependencies >/dev/null || true

# Workaround: some Xcode toolchains fail to propagate swift-system's
# SYSTEM_PACKAGE_DARWIN compile definition into the build. When that happens,
# swift-system emits "#error(\"Unsupported Platform\")" on Apple platforms.
# Patch the local checkout to also accept canImport(Darwin) as a Darwin signal.
SWIFT_SYSTEM_INTERNALS_DIR="$DERIVED_DATA/SourcePackages/checkouts/swift-system/Sources/System/Internals"
if [[ -d "$SWIFT_SYSTEM_INTERNALS_DIR" ]]; then
  for f in CInterop.swift Constants.swift Exports.swift Syscalls.swift; do
    p="$SWIFT_SYSTEM_INTERNALS_DIR/$f"
    if [[ -f "$p" ]] && grep -q "^#if SYSTEM_PACKAGE_DARWIN" "$p" 2>/dev/null; then
      echo "[patch] swift-system: relaxing Darwin guard in $f"
      # Replace the first line "#if SYSTEM_PACKAGE_DARWIN" with
      # "#if canImport(Darwin) || SYSTEM_PACKAGE_DARWIN"
      # Use ed-style safe, portable replacement
      perl -0777 -pe 's/^#if SYSTEM_PACKAGE_DARWIN/#if canImport(Darwin) || SYSTEM_PACKAGE_DARWIN/m' -i "$p"
    fi
  done
fi

CODE_SIGN_IDENTITY_ARGS=()
if [[ -n "$SIGNING_CERT" ]]; then
  CODE_SIGN_IDENTITY_ARGS+=("CODE_SIGN_IDENTITY=${SIGNING_CERT}")
fi

if [[ -n "$SIGNING_CERT" ]] && [[ "$SIGNING_CERT" != "Apple Development" ]] && [[ "$SIGNING_CERT" != "Apple Distribution" ]]; then
  CODE_SIGN_STYLE_OVERRIDE="Manual"
else
  CODE_SIGN_STYLE_OVERRIDE="Automatic"
fi

if [[ "$CODE_SIGN_STYLE_OVERRIDE" == "Manual" ]]; then
  CODE_SIGN_IDENTITY_ARGS+=("PROVISIONING_PROFILE_SPECIFIER=")
  CODE_SIGN_IDENTITY_ARGS+=("PROVISIONING_PROFILE=")
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
      MARKETING_VERSION="$BASE_VERSION" \
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      archive \
      CODE_SIGN_STYLE="$CODE_SIGN_STYLE_OVERRIDE" \
      DEVELOPMENT_TEAM="${TEAM_ID:-}" \
      ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES \
      "${CODE_SIGN_IDENTITY_ARGS[@]}" \
      "${EXTRA_XC_ARGS[@]}" \
      | xcpretty
  else
    xcrun xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIG" \
      -destination 'generic/platform=macOS' \
      -derivedDataPath "$DERIVED_DATA" \
      -archivePath "$ARCHIVE_PATH" \
      MARKETING_VERSION="$BASE_VERSION" \
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      archive \
      CODE_SIGN_STYLE="$CODE_SIGN_STYLE_OVERRIDE" \
      DEVELOPMENT_TEAM="${TEAM_ID:-}" \
      ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES \
      "${CODE_SIGN_IDENTITY_ARGS[@]}" \
      "${EXTRA_XC_ARGS[@]}"
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

  echo "[verify][$ARCH] entitlements (pre post-sign)"
  codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true

  # Ensure hardened runtime is always applied and sandbox entitlements are present when needed.
  # Some export paths may not properly apply hardened runtime or strip entitlements.
  if [[ "$SANDBOX" == "on" ]]; then
    ENT_FILE="$ROOT_DIR/CodMate/CodMate.entitlements"
    if [[ -f "$ENT_FILE" ]]; then
      echo "[post][$ARCH] Re-signing app with entitlements and hardened runtime"
      codesign --force --options runtime \
        --entitlements "$ENT_FILE" \
        --sign "${SIGNING_CERT}" \
        "$APP_PATH"
    else
      echo "[WARN][$ARCH] Entitlements file missing at $ENT_FILE; skipping post re-sign"
    fi
  else
    # For Direct builds (SANDBOX=off), ensure hardened runtime is applied
    echo "[post][$ARCH] Re-signing app with hardened runtime (no entitlements)"
    codesign --force --options runtime \
      --sign "${SIGNING_CERT}" \
      "$APP_PATH"
  fi

  echo "[verify][$ARCH] entitlements (after post-sign)"
  codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true

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
  APP_VERSION=${APP_VERSION:-$BASE_VERSION}

  # Sanity: ensure PrivacyInfo.xcprivacy is embedded for MAS readiness
  if [[ ! -f "$APP_PATH/Contents/Resources/PrivacyInfo.xcprivacy" ]]; then
    echo "[WARN][$ARCH] PrivacyInfo.xcprivacy not found in app Resources. Ensure it's added to Copy Bundle Resources."
  fi

  PRODUCT_NAME=$(basename "$APP_PATH" .app)
  # Output naming for GitHub Releases "latest/download" links
  # We intentionally use fixed filenames so the website can link to stable paths:
  #   - codmate-arm64.dmg
  #   - codmate-x86_64.dmg
  # If you need the old versioned naming, set RELEASE_NAMING=versioned when invoking this script.
  if [[ "${RELEASE_NAMING:-fixed}" == "versioned" ]]; then
    DMG_NAME="$PRODUCT_NAME-$APP_VERSION+${BUILD_NUMBER}-$ARCH.dmg"
  else
    case "$ARCH" in
      arm64)   DMG_NAME="codmate-arm64.dmg" ;;
      x86_64)  DMG_NAME="codmate-x86_64.dmg" ;;
      *)       DMG_NAME="$PRODUCT_NAME-$ARCH.dmg" ;;
    esac
  fi
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
echo "Bundle ID: ${APP_BUNDLE_ID:-unknown}, Version: $APP_VERSION (build $BUILD_NUMBER)"
done
