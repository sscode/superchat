#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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
xattr -cr "$APP"
if [[ "$SIGNING" == "identity" ]]; then
  codesign --force --deep --options runtime --timestamp --entitlements "$ROOT/packaging/entitlements.plist" --sign "$SUPERCHAT_SIGNING_IDENTITY" "$APP"
else
  codesign --force --deep --options runtime --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/Superchat.app"
xattr -cr "$DMG_STAGE/Superchat.app"
codesign --verify --deep --strict --verbose=2 "$DMG_STAGE/Superchat.app"
ln -s /Applications "$DMG_STAGE/Applications"
VERSION="$(node -p "require('./package.json').version")"
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
hdiutil detach "$VERIFY_MOUNT" >/dev/null

file "$STAGE/superchat"
find "$OUTPUT" -maxdepth 2 -type f -print
