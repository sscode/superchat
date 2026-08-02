#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
node scripts/check-version.mjs

OUTPUT="$ROOT/zig-out/release"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/superchat-package.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
STAGE="$TEMP_ROOT/universal"
DMG_STAGE="$TEMP_ROOT/dmg-stage"
APP="$TEMP_ROOT/Superchat.app"
rm -rf "$OUTPUT" "$ROOT/zig-out/package"
rm -f "$ROOT"/zig-out/*.dmg
mkdir -p "$STAGE" "$OUTPUT"

SIGNING="${SUPERCHAT_SIGNING:-adhoc}"
CREDENTIAL_STORE=false
if [[ "$SIGNING" == "identity" ]]; then CREDENTIAL_STORE=true; fi
VERSION="$(node -p "require('./package.json').version")"
SOURCE_URL="https://github.com/sscode/superchat/tree/v$VERSION"

install_production_icon() {
  local source="$ROOT/assets/icon.png"
  local iconset="$TEMP_ROOT/production.iconset"
  local destination="$APP/Contents/Resources/AppIcon.icns"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    local retina=$((size * 2))
    sips -z "$retina" "$retina" "$source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$destination"
}

install_legal_resources() {
  local resources="$APP/Contents/Resources"
  local licenses="$resources/Licenses"
  mkdir -p "$licenses"
  install -m 0644 "$ROOT/LICENSE" "$licenses/AGPL-3.0.txt"
  install -m 0644 "$ROOT/LICENSES/Apache-2.0.txt" "$licenses/Apache-2.0.txt"
  install -m 0644 "$ROOT/LICENSES/OFL-1.1.txt" "$licenses/OFL-1.1.txt"
  install -m 0644 "$ROOT/THIRD_PARTY_NOTICES.md" "$resources/THIRD_PARTY_NOTICES.md"
  install -m 0644 "$ROOT/PRIVACY.md" "$resources/PRIVACY.md"
  {
    printf 'Superchat %s\n\n' "$VERSION"
    printf 'Source code for this build:\n%s\n\n' "$SOURCE_URL"
    printf 'Superchat is licensed under GNU AGPL version 3 only.\n'
    printf 'Third-party components retain their original licences.\n'
  } > "$resources/SOURCE.txt"

  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :NSHumanReadableCopyright Copyright © 2026 Stuart Sim" "$APP/Contents/Info.plist"
}

npx native build --yes -Doptimize=ReleaseFast -Dtarget=aarch64-macos -Dcredential-store="$CREDENTIAL_STORE"
cp "$ROOT/zig-out/bin/superchat" "$STAGE/superchat-arm64"
npx native build --yes -Doptimize=ReleaseFast -Dtarget=x86_64-macos -Dcredential-store="$CREDENTIAL_STORE"
cp "$ROOT/zig-out/bin/superchat" "$STAGE/superchat-x86_64"
lipo -create "$STAGE/superchat-arm64" "$STAGE/superchat-x86_64" -output "$STAGE/superchat"

ARGS=(--target macos --output "$APP" --binary "$STAGE/superchat" --signing "$SIGNING")
if [[ "$SIGNING" == "identity" ]]; then
  : "${SUPERCHAT_SIGNING_IDENTITY:?Set SUPERCHAT_SIGNING_IDENTITY for identity signing}"
  ARGS+=(--identity "$SUPERCHAT_SIGNING_IDENTITY" --entitlements "$ROOT/packaging/entitlements.plist")
  if [[ -n "${APPLE_TEAM_ID:-}" ]]; then ARGS+=(--team-id "$APPLE_TEAM_ID"); fi
fi
npx native package "${ARGS[@]}"
if [[ "$SIGNING" == "identity" ]]; then
  install_production_icon
fi
install_legal_resources
xattr -cr "$APP"
if [[ "$SIGNING" == "identity" ]]; then
  codesign --force --deep --options runtime --timestamp --entitlements "$ROOT/packaging/entitlements.plist" --sign "$SUPERCHAT_SIGNING_IDENTITY" "$APP"
else
  codesign --force --deep --options runtime --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/Superchat.app"
install -m 0644 "$ROOT/LICENSE" "$DMG_STAGE/LICENSE.txt"
install -m 0644 "$ROOT/THIRD_PARTY_NOTICES.md" "$DMG_STAGE/THIRD_PARTY_NOTICES.md"
cp "$APP/Contents/Resources/SOURCE.txt" "$DMG_STAGE/SOURCE.txt"
xattr -cr "$DMG_STAGE/Superchat.app"
codesign --verify --deep --strict --verbose=2 "$DMG_STAGE/Superchat.app"
ln -s /Applications "$DMG_STAGE/Applications"
DMG="$OUTPUT/superchat-$VERSION-macos-universal.dmg"
hdiutil create -volname Superchat -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG"
if [[ "$SIGNING" == "identity" ]]; then
  codesign --force --timestamp --sign "$SUPERCHAT_SIGNING_IDENTITY" "$DMG"
fi
hdiutil verify "$DMG"
VERIFY_MOUNT="$TEMP_ROOT/verify-mount"
mkdir -p "$VERIFY_MOUNT"
hdiutil attach -nobrowse -readonly -mountpoint "$VERIFY_MOUNT" "$DMG" >/dev/null
codesign --verify --deep --strict --verbose=2 "$VERIFY_MOUNT/Superchat.app"
test -f "$VERIFY_MOUNT/Superchat.app/Contents/Resources/Licenses/AGPL-3.0.txt"
test -f "$VERIFY_MOUNT/Superchat.app/Contents/Resources/Licenses/Apache-2.0.txt"
test -f "$VERIFY_MOUNT/Superchat.app/Contents/Resources/Licenses/OFL-1.1.txt"
test -f "$VERIFY_MOUNT/Superchat.app/Contents/Resources/THIRD_PARTY_NOTICES.md"
test -f "$VERIFY_MOUNT/SOURCE.txt"
hdiutil detach "$VERIFY_MOUNT" >/dev/null
(cd "$OUTPUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

file "$STAGE/superchat"
find "$OUTPUT" -maxdepth 2 -type f -print
