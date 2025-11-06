#!/usr/bin/env bash

set -euo pipefail

# CodMate macOS App Store (MAS) builder
# - Archives via xcodebuild
# - Exports signed Mac App Store app
# - Builds PKG for App Store submission
# - Uploads to App Store Connect (optional)
#
# Loads .env from repo root if present (APPLE_SIGNING_IDENTITY, APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID)
# Usage:
#   APPLE_ID="appleid@example.com" \
#   APPLE_PASSWORD="abcd-efgh-ijkl-mnop" \
#   ./scripts/macos-build-mas.sh
#
# Optional overrides:
#   SCHEME (default: CodMate)
#   PROJECT (default: CodMate.xcodeproj)
#   CONFIG (default: Release)
#   ARCH_MATRIX (default: "arm64 x86_64"), set to "arm64" to build universal or single arch
#   SIGNING_CERT (default: 3rd Party Mac Developer Application)
#   INSTALLER_CERT (default: 3rd Party Mac Developer Installer)
#   VERSION (if set, will override Marketing Version)
#   UPLOAD (default: 0). Set to 1 to automatically upload to App Store Connect
#   MIN_MACOS (default: 15.0) sets MACOSX_DEPLOYMENT_TARGET
#   VERBOSE (default: 0). Set to 1 to see full xcodebuild output

SCHEME="${SCHEME:-CodMate}"
# Default to the lowercase project filename used in this repo
PROJECT="${PROJECT:-codmate.xcodeproj}"
CONFIG="${CONFIG:-Release}"
# For MAS, typically build universal binary (both architectures)
ARCH_MATRIX=( ${ARCH_MATRIX:-arm64 x86_64} )
SIGNING_CERT="${SIGNING_CERT:-}"
INSTALLER_CERT="${INSTALLER_CERT:-}"
VERBOSE="${VERBOSE:-0}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Now that ROOT_DIR is known, set entitlements path default if not provided
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/CodMate/CodMate.entitlements}"
BUILD_DIR="$ROOT_DIR/build-mas"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Downloads}"
DERIVED_DATA="$BUILD_DIR/DerivedData"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions-MAS.plist"
BUILD_LOG="$BUILD_DIR/build.log"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# Logging functions
log_info() {
  if [[ "$VERBOSE" == "1" ]]; then
    echo "[info] $*"
  fi
}

log_step() {
  echo "▸ $*"
}

log_warn() {
  echo "[WARN] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

log_success() {
  echo "✓ $*"
}

# Load .env without overriding explicitly exported vars
ENV_FILE="$ROOT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  while IFS='=' read -r k v; do
    [[ -z "${k// /}" ]] && continue
    [[ "$k" =~ ^# ]] && continue
    case "$k" in
      APPLE_SIGNING_IDENTITY|APPLE_ID|APPLE_PASSWORD|APPLE_TEAM_ID)
        if [[ -z "${!k:-}" ]]; then
          v="${v%\r}"; v="${v%\n}"; v="${v%\"}"; v="${v#\"}"
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
    # MAS requires specific certificate
    SIGNING_CERT="3rd Party Mac Developer Application"
  fi
fi

if [[ -z "$INSTALLER_CERT" ]]; then
  INSTALLER_CERT="3rd Party Mac Developer Installer"
fi

# ------------------------------
# Versioning strategy (same as notarized-dmg script)
BASE_VERSION="${BASE_VERSION:-${VERSION:-0.0.0}}"
BUILD_NUMBER_STRATEGY="${BUILD_NUMBER_STRATEGY:-date}"

compute_build_number() {
  case "$BUILD_NUMBER_STRATEGY" in
    date)
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

echo "=========================================="
echo "  CodMate - Mac App Store Build"
echo "=========================================="
echo "Version: $DISPLAY_VERSION"
echo "Scheme: $SCHEME"
echo "Config: $CONFIG"
echo "Architectures: ${ARCH_MATRIX[*]}"
log_info "Build log: $BUILD_LOG"
echo "=========================================="

# Compose extra xcodebuild args
EXTRA_XC_ARGS=()

# MAS builds MUST enable App Sandbox - no override allowed
EXTRA_XC_ARGS+=("CODE_SIGN_ENTITLEMENTS=CodMate/CodMate.entitlements")
log_info "MAS build → App Sandbox entitlements REQUIRED"

# Force modern macOS deployment target
MIN_MACOS="${MIN_MACOS:-15.0}"
EXTRA_XC_ARGS+=("MACOSX_DEPLOYMENT_TARGET=${MIN_MACOS}")
log_info "MIN_MACOS=${MIN_MACOS}"

# Ensure Swift flags for macOS packages and enable experimental features
# Also force APPSTORE compile condition so UI/terminal gates follow MAS rules
# LifetimeDependence is required by swift-subprocess main branch
EXTRA_XC_ARGS+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=APPSTORE")
EXTRA_XC_ARGS+=("OTHER_SWIFT_FLAGS=-DAPPSTORE -DSYSTEM_PACKAGE_DARWIN -DSUBPROCESS_ASYNCIO_DISPATCH -enable-experimental-feature LifetimeDependence -enable-experimental-feature NonescapableTypes")
log_info "Adding Swift flags: -DAPPSTORE -DSYSTEM_PACKAGE_DARWIN -DSUBPROCESS_ASYNCIO_DISPATCH -enable-experimental-feature LifetimeDependence"

# Pre-resolve packages for build-time patches
log_step "Resolving Swift packages..."
if [[ "$VERBOSE" == "1" ]]; then
  xcrun xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED_DATA" \
    -resolvePackageDependencies 2>&1 | tee -a "$BUILD_LOG" || true
else
  xcrun xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED_DATA" \
    -resolvePackageDependencies >> "$BUILD_LOG" 2>&1 || true
fi

# Apply swift-system patch if needed
SWIFT_SYSTEM_INTERNALS_DIR="$DERIVED_DATA/SourcePackages/checkouts/swift-system/Sources/System/Internals"
PATCHED_COUNT=0
if [[ -d "$SWIFT_SYSTEM_INTERNALS_DIR" ]]; then
  for f in CInterop.swift Constants.swift Exports.swift Syscalls.swift; do
    p="$SWIFT_SYSTEM_INTERNALS_DIR/$f"
    if [[ -f "$p" ]] && grep -q "^#if SYSTEM_PACKAGE_DARWIN" "$p" 2>/dev/null; then
      log_info "Patching swift-system: $f"
      perl -0777 -pe 's/^#if SYSTEM_PACKAGE_DARWIN/#if canImport(Darwin) || SYSTEM_PACKAGE_DARWIN/m' -i "$p"
      PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi
  done
  if [[ $PATCHED_COUNT -gt 0 ]]; then
    log_success "Applied swift-system patches ($PATCHED_COUNT files)"
  fi
fi

# Build for specified architectures
# For MAS, typically we want a universal binary, but support single arch for testing
ARCH_FLAGS=()
if [[ ${#ARCH_MATRIX[@]} -eq 1 ]]; then
  ARCH_FLAGS=("ARCHS=${ARCH_MATRIX[0]}" "ONLY_ACTIVE_ARCH=YES")
  ARCH_SUFFIX="${ARCH_MATRIX[0]}"
else
  # Universal binary
  ARCH_FLAGS=("ARCHS=${ARCH_MATRIX[*]}" "ONLY_ACTIVE_ARCH=NO")
  ARCH_SUFFIX="universal"
fi

ARCHIVE_PATH="$BUILD_DIR/$SCHEME-MAS-$ARCH_SUFFIX.xcarchive"
EXPORT_DIR="$BUILD_DIR/export-mas-$ARCH_SUFFIX"
mkdir -p "$EXPORT_DIR"

log_step "[1/6] Archiving $SCHEME for Mac App Store..."

XCODEBUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIG"
  -destination 'generic/platform=macOS'
  -derivedDataPath "$DERIVED_DATA"
  -archivePath "$ARCHIVE_PATH"
  MARKETING_VERSION="$BASE_VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  archive
  CODE_SIGN_STYLE=Automatic
  DEVELOPMENT_TEAM="${TEAM_ID:-}"
  CODE_SIGN_IDENTITY="${SIGNING_CERT}"
  "${ARCH_FLAGS[@]}"
  "${EXTRA_XC_ARGS[@]}"
  -allowProvisioningUpdates
)

# Allow specifying a provisioning profile explicitly when automatic management isn't available
if [[ -n "${PROVISIONING_PROFILE_SPECIFIER:-}" ]]; then
  XCODEBUILD_ARGS+=("PROVISIONING_PROFILE_SPECIFIER=${PROVISIONING_PROFILE_SPECIFIER}")
fi

if [[ "$VERBOSE" == "1" ]]; then
  if command -v xcpretty >/dev/null 2>&1; then
    xcrun xcodebuild "${XCODEBUILD_ARGS[@]}" 2>&1 | tee -a "$BUILD_LOG" | xcpretty
  else
    xcrun xcodebuild "${XCODEBUILD_ARGS[@]}" 2>&1 | tee -a "$BUILD_LOG"
  fi
else
  xcrun xcodebuild "${XCODEBUILD_ARGS[@]}" >> "$BUILD_LOG" 2>&1 || {
    log_error "Archive failed. Check $BUILD_LOG for details."
    tail -n 50 "$BUILD_LOG" >&2
    exit 1
  }
fi
log_success "Archive created"

log_step "[2/6] Preparing ExportOptions.plist..."
cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>app-store</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>${TEAM_ID:-}</string>
  <key>signingCertificate</key>
  <string>${SIGNING_CERT}</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  <true/>
  <key>compileBitcode</key>
  <false/>
  <key>generateAppStoreInformation</key>
  <false/>
</dict>
</plist>
PLIST

log_step "[3/6] Exporting signed app for Mac App Store..."
if [[ "$VERBOSE" == "1" ]]; then
  if command -v xcpretty >/dev/null 2>&1; then
    xcrun xcodebuild -exportArchive \
      -archivePath "$ARCHIVE_PATH" \
      -exportPath "$EXPORT_DIR" \
      -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
      -allowProvisioningUpdates \
      2>&1 | tee -a "$BUILD_LOG" | xcpretty
  else
    xcrun xcodebuild -exportArchive \
      -archivePath "$ARCHIVE_PATH" \
      -exportPath "$EXPORT_DIR" \
      -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
      -allowProvisioningUpdates \
      2>&1 | tee -a "$BUILD_LOG"
  fi
else
  xcrun xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -allowProvisioningUpdates \
    >> "$BUILD_LOG" 2>&1 || {
    log_error "Export failed. Check $BUILD_LOG for details."
    tail -n 50 "$BUILD_LOG" >&2
    exit 1
  }
fi
log_success "Export completed"

log_step "[4/6] Extracting and re-signing with correct entitlements..."
# Find what was exported (.app or .pkg)
TEMP_APP=$(find "$EXPORT_DIR" -maxdepth 3 -type d -name "*.app" -print -quit)
TEMP_PKG=$(find "$EXPORT_DIR" -maxdepth 3 -type f -name "*.pkg" -print -quit)

# If PKG was exported, extract the .app first
if [[ -z "$TEMP_APP" && -n "$TEMP_PKG" ]]; then
  log_info "Extracting .app from exported PKG"
  EXTRACT_DIR="$BUILD_DIR/extract-for-resign"
  rm -rf "$EXTRACT_DIR" && mkdir -p "$EXTRACT_DIR"

  # Expand PKG
  if pkgutil --expand-full "$TEMP_PKG" "$EXTRACT_DIR/expanded" >> "$BUILD_LOG" 2>&1; then
    log_info "PKG expanded successfully"
  else
    log_warn "Full expand failed, trying simple expand"
    pkgutil --expand "$TEMP_PKG" "$EXTRACT_DIR/expanded" >> "$BUILD_LOG" 2>&1
  fi

  # Find .app: check if Payload is already a directory (expand-full) or a file (expand)
  PAYLOAD_DIR=$(find "$EXTRACT_DIR/expanded" -type d -name "Payload" -print -quit)
  if [[ -n "$PAYLOAD_DIR" ]]; then
    # expand-full succeeded: Payload is a directory containing .app
    log_info "Payload already expanded, locating .app"
    TEMP_APP=$(find "$PAYLOAD_DIR" -type d -name "CodMate.app" -print -quit)
  else
    # expand-full failed, try extracting Payload file with cpio
    PAYLOAD_FILE=$(find "$EXTRACT_DIR/expanded" -type f -name "Payload" -print -quit)
    if [[ -n "$PAYLOAD_FILE" ]]; then
      log_info "Extracting Payload with cpio"
      mkdir -p "$EXTRACT_DIR/payload"
      (cd "$EXTRACT_DIR/payload" && (cat "$PAYLOAD_FILE" | gunzip -dc 2>/dev/null || cat "$PAYLOAD_FILE") | cpio -id 2>>"$BUILD_LOG")
      TEMP_APP=$(find "$EXTRACT_DIR/payload" -type d -name "CodMate.app" -print -quit)
    fi
  fi
fi

# Re-sign the app with correct entitlements
if [[ -n "$TEMP_APP" ]]; then
  log_info "Re-signing $TEMP_APP with CodMate.entitlements"
  # Remove old signature
  codesign --remove-signature "$TEMP_APP" >> "$BUILD_LOG" 2>&1 || true
  # Sign with correct entitlements and MAS certificate
  codesign --sign "3rd Party Mac Developer Application: Chengdu Wake.Link Technology Co., Ltd. (AN5X2K46ER)" \
    --entitlements "CodMate/CodMate.entitlements" \
    --options runtime \
    --force \
    --deep \
    "$TEMP_APP" >> "$BUILD_LOG" 2>&1 || {
    log_error "Re-signing failed"
    exit 1
  }
  log_success "Re-signed with App Sandbox entitlements"

  # Verify entitlements were applied
  if [[ "$VERBOSE" == "1" ]]; then
    echo "[verify] Applied entitlements:"
    codesign -d --entitlements - "$TEMP_APP" 2>&1 | head -20
  fi

  # Use the re-signed app for final PKG creation
  APP_PATH="$TEMP_APP"
else
  log_error "Failed to locate .app for re-signing"
  exit 1
fi

log_step "Locating exported app bundle..."
# If APP_PATH was set by re-signing step, use it; otherwise find from export
if [[ -z "$APP_PATH" ]]; then
  APP_PATH=$(find "$EXPORT_DIR" -maxdepth 3 -type d -name "*.app" -print -quit)
fi
EXPORTED_PKG=$(find "$EXPORT_DIR" -maxdepth 3 -type f -name "*.pkg" -print -quit)
STAGE_DIR="$BUILD_DIR/stage-app"
rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"

if [[ -z "${APP_PATH}" && -n "${EXPORTED_PKG}" ]]; then
  # Expand exported PKG to extract the app for validation/re-signing if necessary
  log_info "Expanding exported PKG to stage app for validation"
  mkdir -p "$STAGE_DIR/expanded"
  if ! pkgutil --expand-full "$EXPORTED_PKG" "$STAGE_DIR/expanded" >> "$BUILD_LOG" 2>&1; then
    log_warn "pkgutil --expand-full failed, attempting simple expand"
    pkgutil --expand "$EXPORTED_PKG" "$STAGE_DIR/expanded" >> "$BUILD_LOG" 2>&1 || true
  fi
  # Try common payload patterns
  PAYLOADS=$(find "$STAGE_DIR/expanded" -type f -name Payload)
  if [[ -n "$PAYLOADS" ]]; then
    mkdir -p "$STAGE_DIR/payload"
    for P in $PAYLOADS; do
      (cd "$STAGE_DIR/payload" && (cat "$P" | gunzip -dc 2>/dev/null || cat "$P") | cpio -id 2>>"$BUILD_LOG") || true
    done
    APP_PATH=$(find "$STAGE_DIR/payload" -type d -path "*/Applications/*.app" -name "CodMate.app" -print -quit)
  fi
  # Fallback search
  if [[ -z "$APP_PATH" ]]; then
    APP_PATH=$(find "$STAGE_DIR/expanded" -type d -name "CodMate.app" -print -quit)
  fi
fi

if [[ -z "${APP_PATH}" && -z "${EXPORTED_PKG}" ]]; then
  log_error "No exported .app or .pkg found under $EXPORT_DIR"
  log_info "Export dir contents:"
  find "$EXPORT_DIR" -maxdepth 3 -print
  exit 1
fi

log_step "Verifying app bundle..."

PRODUCT_NAME="CodMate"
PKG_NAME="$PRODUCT_NAME-$BASE_VERSION+${BUILD_NUMBER}-MAS.pkg"
PKG_PATH="$OUTPUT_DIR/$PKG_NAME"

if [[ -n "$APP_PATH" ]]; then
  # Verify .app codesign and entitlements
  if codesign --verify --deep --strict --verbose=2 "$APP_PATH" >> "$BUILD_LOG" 2>&1; then
    log_success "App code signature valid"
  else
    log_error "App code signature verification failed"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -n 20
    exit 1
  fi

  if [[ "$VERBOSE" == "1" ]]; then
    echo "[verify] Entitlements:"
    codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true
  fi

  # Enforce App Sandbox entitlement; re-sign if missing
  if ! codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
    log_warn "App Sandbox entitlement missing on exported app. Re-signing with $ENTITLEMENTS_PATH"
    if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
      log_error "Entitlements file not found at $ENTITLEMENTS_PATH"
      exit 1
    fi
    # Re-sign top-level app with proper entitlements
    if codesign --force --options runtime \
      --entitlements "$ENTITLEMENTS_PATH" \
      --sign "${SIGNING_CERT}" \
      "$APP_PATH" >> "$BUILD_LOG" 2>&1; then
      log_success "Re-sign completed"
    else
      log_error "Re-sign failed"
      tail -n 30 "$BUILD_LOG" >&2
      exit 1
    fi
    # Show entitlements after re-sign in verbose mode
    if [[ "$VERBOSE" == "1" ]]; then
      echo "[verify] Entitlements after re-sign:"
      codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true
    fi
  fi

  # Verify architecture
  MAIN_EXEC=$(defaults read "$APP_PATH/Contents/Info" CFBundleExecutable 2>/dev/null || true)
  if [[ -n "$MAIN_EXEC" && -f "$APP_PATH/Contents/MacOS/$MAIN_EXEC" ]]; then
    LIPO_INFO=$(lipo -info "$APP_PATH/Contents/MacOS/$MAIN_EXEC" 2>/dev/null || true)
    log_info "Architecture: $LIPO_INFO"
  fi

  # Extract version info and confirm privacy manifest
  APP_BUNDLE_ID=$(defaults read "$APP_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
  APP_VERSION=$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
  APP_VERSION=${APP_VERSION:-$BASE_VERSION}
  PKG_NAME="$PRODUCT_NAME-$APP_VERSION+${BUILD_NUMBER}-MAS.pkg"
  PKG_PATH="$OUTPUT_DIR/$PKG_NAME"

  if [[ ! -f "$APP_PATH/Contents/Resources/PrivacyInfo.xcprivacy" ]]; then
    log_error "PrivacyInfo.xcprivacy not found! This is REQUIRED for Mac App Store submission."
    log_error "Ensure PrivacyInfo.xcprivacy is added to 'Copy Bundle Resources' in Xcode."
    exit 1
  else
    log_success "PrivacyInfo.xcprivacy present"
  fi

  log_step "[5/7] Building PKG for App Store submission..."
  rm -f "$PKG_PATH"
  if xcrun productbuild \
    --component "$APP_PATH" /Applications \
    --sign "$INSTALLER_CERT" \
    "$PKG_PATH" >> "$BUILD_LOG" 2>&1; then
    log_success "PKG created"
  else
    log_error "PKG creation failed"
    tail -n 30 "$BUILD_LOG" >&2
    exit 1
  fi
else
  # No app path found even after expansion (should not happen). Use exported pkg but warn.
  log_warn "App bundle not located; using exported PKG as-is (entitlements not verified)."
  rm -f "$PKG_PATH"
  cp -f "$EXPORTED_PKG" "$PKG_PATH"
fi

log_step "[6/7] Verifying PKG signature..."
if [[ "$VERBOSE" == "1" ]]; then
  pkgutil --check-signature "$PKG_PATH"
else
  if pkgutil --check-signature "$PKG_PATH" >> "$BUILD_LOG" 2>&1; then
    log_success "PKG signature valid"
  else
    log_error "PKG signature verification failed"
    pkgutil --check-signature "$PKG_PATH" 2>&1
    exit 1
  fi
fi

log_step "[7/7] Upload to App Store Connect"
if [[ "${UPLOAD:-0}" == "1" ]]; then
  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" ]]; then
    log_info "Uploading to App Store Connect..."
    if xcrun altool --upload-app \
      --type osx \
      --file "$PKG_PATH" \
      --username "$APPLE_ID" \
      --password "$APPLE_PASSWORD" \
      >> "$BUILD_LOG" 2>&1; then
      log_success "Upload complete!"
    else
      log_error "Upload failed. Check $BUILD_LOG for details."
      tail -n 30 "$BUILD_LOG" >&2
      exit 1
    fi
  else
    log_warn "UPLOAD=1 but APPLE_ID/APPLE_PASSWORD not set. Skipping upload."
    log_info "To upload, provide APPLE_ID and APPLE_PASSWORD (app-specific password)"
  fi
else
  log_info "Auto-upload disabled (UPLOAD=0). To upload, set UPLOAD=1"
  log_info "Or manually upload via Transporter app or:"
  log_info "  xcrun altool --upload-app --type osx --file \"$PKG_PATH\" \\"
  log_info "    --username \"YOUR_APPLE_ID\" --password \"APP_SPECIFIC_PASSWORD\""
fi

echo ""
echo "=========================================="
echo "  ✓ Build Complete!"
echo "=========================================="
echo "PKG:        $PKG_PATH"
# Ensure summary variables are defined even when only a PKG was exported
if [[ -z "${APP_BUNDLE_ID:-}" || "${APP_BUNDLE_ID:-}" == "" || "${APP_BUNDLE_ID:-}" == "unknown" ]]; then
  if [[ -f "$PROJECT/project.pbxproj" ]]; then
    DEFAULT_BUNDLE_ID=$(awk -F'[ =;]+' '/PRODUCT_BUNDLE_IDENTIFIER/{print $4; exit}' "$PROJECT/project.pbxproj" || true)
    if [[ -n "$DEFAULT_BUNDLE_ID" ]]; then APP_BUNDLE_ID="$DEFAULT_BUNDLE_ID"; fi
  fi
fi
APP_VERSION="${APP_VERSION:-$BASE_VERSION}"
echo "Bundle ID:  ${APP_BUNDLE_ID:-unknown}"
echo "Version:    ${APP_VERSION} (build $BUILD_NUMBER)"
if [[ "$VERBOSE" != "1" ]]; then
  echo "Build log:  $BUILD_LOG"
fi
echo "=========================================="
