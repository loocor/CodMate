# CodMate Build Scripts

This directory contains scripts for building CodMate for different distribution channels.

## Quick Start

### Build Both Distributions (Recommended)
```bash
./scripts/macos-build-all.sh
```

### Build Only Developer ID (DMG for direct distribution)
```bash
./scripts/macos-build-notarized-dmg.sh
# or
BUILD_DEVID_ONLY=1 ./scripts/macos-build-all.sh
```

### Build Only Mac App Store (PKG)
```bash
./scripts/macos-build-mas.sh
# or
BUILD_MAS_ONLY=1 ./scripts/macos-build-all.sh
```

## Script Overview

### 1. `macos-build-all.sh` (New - Unified Build)
**Purpose**: Build both Developer ID and Mac App Store distributions in one command.

**Key Features**:
- Orchestrates both build types
- Validates both subscripts exist
- Provides unified output
- Supports selective builds

**Usage Examples**:
```bash
# Build everything
./scripts/macos-build-all.sh

# Build and upload MAS, skip Developer ID
BUILD_DEVID_ONLY=1 UPLOAD=1 ./scripts/macos-build-all.sh

# Custom version
VERSION=1.2.3 ./scripts/macos-build-all.sh
```

---

### 2. `macos-build-mas.sh` (New - Mac App Store)
**Purpose**: Build and optionally upload to Mac App Store.

**Output**: `.pkg` file ready for App Store Connect submission

**Key Differences from Developer ID**:
- Uses `app-store` export method
- Requires MAS certificates (3rd Party Mac Developer Application/Installer)
- **Enforces App Sandbox** (no override)
- Generates PKG instead of DMG
- No notarization needed (handled by App Store review)

**Required Environment Variables**:
```bash
export TEAM_ID="YOUR_TEAM_ID"
export APPLE_ID="your@apple.id"
export APPLE_PASSWORD="xxxx-xxxx-xxxx-xxxx"  # App-specific password
```

**Usage Examples**:
```bash
# Build only (manual upload later)
./scripts/macos-build-mas.sh

# Build and auto-upload
UPLOAD=1 ./scripts/macos-build-mas.sh

# Custom version
VERSION=1.2.3 ./scripts/macos-build-mas.sh

# Single architecture (testing)
ARCH_MATRIX="arm64" ./scripts/macos-build-mas.sh
```

---

### 3. `macos-build-notarized-dmg.sh` (Existing - Developer ID)
**Purpose**: Build notarized DMG for distribution outside App Store (e.g., website downloads).

**Output**: Notarized `.dmg` files (one per architecture by default)

**Key Features**:
- Developer ID Application signing
- Notarization with Apple
- Ticket stapling
- Optional sandbox control (`SANDBOX=on|off`)
- Builds for multiple architectures independently

**Usage Examples**:
```bash
# Build and notarize (requires notarization credentials)
APPLE_NOTARY_PROFILE="AC_PROFILE" ./scripts/macos-build-notarized-dmg.sh

# Or with Apple ID
APPLE_ID="your@apple.id" \
APPLE_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
TEAM_ID="YOURTEAMID" \
./scripts/macos-build-notarized-dmg.sh

# Build without sandbox (for testing)
SANDBOX=off ./scripts/macos-build-notarized-dmg.sh
```

---

## Environment Variables

### Common to All Scripts
| Variable | Default | Description |
|----------|---------|-------------|
| `VERSION` or `BASE_VERSION` | `0.0.0` | Marketing version |
| `BUILD_NUMBER_STRATEGY` | `date` | `date`, `git`, or `counter` |
| `SCHEME` | `CodMate` | Xcode scheme name |
| `PROJECT` | `CodMate.xcodeproj` | Xcode project file |
| `CONFIG` | `Release` | Build configuration |
| `ARCH_MATRIX` | `arm64 x86_64` | Architectures to build |
| `MIN_MACOS` | `15.0` | Minimum macOS version |
| `OUTPUT_DIR` | `~/Downloads` | Output directory |

### MAS-Specific
| Variable | Default | Description |
|----------|---------|-------------|
| `UPLOAD` | `0` | Set to `1` to auto-upload to App Store Connect |
| `SIGNING_CERT` | `3rd Party Mac Developer Application` | Signing certificate |
| `INSTALLER_CERT` | `3rd Party Mac Developer Installer` | PKG signing certificate |

### Developer ID-Specific
| Variable | Default | Description |
|----------|---------|-------------|
| `SANDBOX` | `on` | Set to `off` to disable sandbox (not for MAS!) |
| `APPLE_NOTARY_PROFILE` | - | Keychain profile for notarization |
| `RELEASE_NAMING` | `fixed` | Set to `versioned` for versioned DMG names |

---

## Prerequisites

### For MAS Builds
1. ✅ **Mac App Store certificates** installed in Keychain:
   - 3rd Party Mac Developer Application
   - 3rd Party Mac Developer Installer
2. ✅ **App-specific password** from appleid.apple.com
3. ✅ **PrivacyInfo.xcprivacy** in app bundle (required by Apple)
4. ✅ **App Sandbox entitlements** properly configured

### For Developer ID Builds
1. ✅ **Developer ID certificates** installed in Keychain:
   - Developer ID Application
2. ✅ **Notarization credentials** (Keychain profile or Apple ID + password)

### Shared Requirements
1. ✅ Xcode command-line tools
2. ✅ Valid provisioning profiles
3. ✅ (Optional) `xcpretty` for cleaner output: `gem install xcpretty`
4. ✅ (Optional) `create-dmg` for better DMG layout: `brew install create-dmg`

---

## Configuration File (.env)

Create `.env` in repo root to avoid passing credentials via command line:

```bash
# Team and signing
APPLE_TEAM_ID="YOUR_TEAM_ID"
APPLE_SIGNING_IDENTITY="3rd Party Mac Developer Application: Your Name (TEAMID)"

# For notarization (Developer ID)
APPLE_NOTARY_PROFILE="AC_PROFILE_NAME"

# Or for upload (MAS) and notarization
APPLE_ID="your@apple.id"
APPLE_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

**Security Note**: Add `.env` to `.gitignore` to avoid committing credentials.

---

## Troubleshooting

### MAS Build Issues

**Problem**: "PrivacyInfo.xcprivacy not found"
- **Solution**: Ensure `PrivacyInfo.xcprivacy` is added to target's "Copy Bundle Resources"

**Problem**: "Code signing entitlements error"
- **Solution**: Verify `CodMate/CodMate.entitlements` contains required MAS keys

**Problem**: Upload fails with authentication error
- **Solution**: Generate new app-specific password at appleid.apple.com

### Developer ID Build Issues

**Problem**: Notarization fails
- **Solution**: Check `spctl` assessment and review notarization logs via `notarytool log`

**Problem**: "Unsupported Platform" error from swift-system
- **Solution**: Script includes automatic patch; ensure package resolution succeeds

---

## Architecture Notes

### Why Separate Scripts?

1. **Clear separation of concerns**: MAS and Developer ID have different requirements
2. **Easier maintenance**: Changes to one don't affect the other
3. **Safer iteration**: Test MAS builds without risking existing workflow
4. **Flexibility**: Run only what you need

### Universal vs. Multi-Arch

- **Developer ID** (default): Builds **two separate DMGs** (arm64 + x86_64)
  - Smaller download size for users
  - Faster build times

- **MAS** (default): Builds **one universal binary** (arm64 + x86_64)
  - App Store convention
  - Users download appropriate slice automatically

---

## Next Steps After Build

### Mac App Store
1. Build with `UPLOAD=1` or manually upload via Transporter app
2. Visit App Store Connect → My Apps
3. Create new version (if needed)
4. Submit for review
5. Monitor review status

### Developer ID
1. DMG files are in `~/Downloads` (or `$OUTPUT_DIR`)
2. Test on different Macs (Intel + Apple Silicon)
3. Upload to your distribution server/CDN
4. Update website download links

---

## Questions?

- Check the inline comments in each script for detailed explanations
- Review `AGENTS.md` for project-specific agent configurations
- Consult Apple's documentation for certificate/notarization issues
