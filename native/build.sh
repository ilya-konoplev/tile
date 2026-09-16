#!/bin/bash
# Builds ActivityHeatmap.app from the SwiftPM executable target.
#
# Usage:
#   ./build.sh              # debug build (fast, default)
#   ./build.sh release      # release build
#
# Signing: looks for a certificate named "ActivityHeatmap Dev" in the
# login keychain (see make_cert.sh / history/STAGE1.md for how to create it once,
# by hand, in Keychain Access). If it's not found, falls back to ad-hoc
# signing (-) and prints a warning – ad-hoc signatures are unstable across
# rebuilds and will NOT keep Full Disk Access granted (risk #1 in
# ARCHITECTURE.md).

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP_NAME="ActivityHeatmap"
BUNDLE_ID="com.local.activityheatmap"
SIGN_IDENTITY_NAME="ActivityHeatmap Dev"

echo "==> swift build (-c $CONFIG)"
swift build -c "$CONFIG"

BIN_PATH=".build/$CONFIG/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

APP_DIR="$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

# Kill any running instance BEFORE replacing the bundle. Without this the old
# process keeps running from the (now deleted) bundle: `open` on an already-
# running app just re-activates it instead of launching the fresh binary, so a
# rebuild silently leaves the previous build on screen. This actually happened
# — the desktop widget ran a four-day-old build through a whole session of
# "rebuilds" that never took effect (STATUS.md, критичный #2).
WAS_RUNNING=0
if pgrep -f "$APP_DIR/Contents/MacOS/$APP_NAME" >/dev/null; then
  WAS_RUNNING=1
  echo "==> stopping running $APP_NAME before rebuild"
  pkill -f "$APP_DIR/Contents/MacOS/$APP_NAME" || true
  # Give it a moment to release the bundle and exit.
  for _ in 1 2 3 4 5; do
    pgrep -f "$APP_DIR/Contents/MacOS/$APP_NAME" >/dev/null || break
    sleep 0.4
  done
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"

# App icon ("1a" from the design's logo mockup) + the menu bar glyph, both
# pre-rasterized (see Resources/README.md) since there's no Xcode asset
# catalog compiler in this Command-Line-Tools-only setup.
cp Resources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"
cp Resources/MenuBarIcon.png "$RESOURCES_DIR/MenuBarIcon.png"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> signing"
# NOTE: deliberately no `-v` here. A self-signed certificate that the user has
# not explicitly marked "Always Trust" reports CSSMERR_TP_NOT_TRUSTED, so
# `find-identity -v` (valid only) lists zero identities and we would silently
# fall back to ad-hoc signing. Verified live: codesign signs happily with such a
# certificate, and the resulting designated requirement pins the certificate
# leaf hash – which is exactly what keeps Full Disk Access from being revoked
# across rebuilds. Trust status is irrelevant for local signing; requiring it
# would force a needless change to the user's keychain trust settings.
#
# Sign by SHA-1 fingerprint, never by name. If the certificate was created more
# than once (easy to do – the wizard does not warn), several entries share the
# name and codesign aborts with "ambiguous (matches ... and ...)", leaving the
# bundle unsigned. Fingerprints are unique.
#
# The chosen fingerprint is pinned in .signing-identity, because Full Disk
# Access is bound to the certificate leaf hash: silently switching to another
# same-named certificate on a later build would revoke the grant.
PIN_FILE="$(dirname "$0")/.signing-identity"
SIGN_HASH=""
if [ -f "$PIN_FILE" ]; then
  SIGN_HASH="$(cat "$PIN_FILE")"
  if ! security find-identity -p codesigning | grep -q "$SIGN_HASH"; then
    echo "    WARNING: pinned certificate $SIGN_HASH is gone from the keychain."
    echo "    Re-pinning to another one; you will have to grant Full Disk Access again."
    SIGN_HASH=""
  fi
fi
if [ -z "$SIGN_HASH" ]; then
  # Sorted so repeated runs pick the same one when duplicates exist.
  SIGN_HASH="$(security find-identity -p codesigning \
    | grep "$SIGN_IDENTITY_NAME" | awk '{print $2}' | sort | head -1)"
  [ -n "$SIGN_HASH" ] && printf '%s' "$SIGN_HASH" > "$PIN_FILE"
fi

DUPLICATES="$(security find-identity -p codesigning | grep -c "$SIGN_IDENTITY_NAME" || true)"

if [ -n "$SIGN_HASH" ]; then
  echo "    using stable identity: $SIGN_IDENTITY_NAME ($SIGN_HASH)"
  if [ "$DUPLICATES" -gt 1 ]; then
    echo "    note: $DUPLICATES certificates share this name; pinned the one above."
    echo "    The extra ones are harmless but can be deleted in Keychain Access."
  fi
  codesign --force --deep --sign "$SIGN_HASH" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    "$APP_DIR"
else
  echo "    WARNING: certificate '$SIGN_IDENTITY_NAME' not found in keychain."
  echo "    Falling back to ad-hoc signing (-). This signature changes on"
  echo "    every rebuild and Full Disk Access WILL be revoked each time."
  echo "    Run ./make_cert.sh for instructions to create a stable cert."
  codesign --force --deep --sign - \
    --identifier "$BUNDLE_ID" \
    "$APP_DIR"
fi

echo "==> verifying signature"
codesign -dv "$APP_DIR" 2>&1 | sed 's/^/    /'

# Relaunch only if we stopped a running instance, so `./build.sh` restores the
# state the user had — a fresh widget instead of a killed one. If it wasn't
# running, leave it alone: building is not the same as choosing to run.
if [ "$WAS_RUNNING" -eq 1 ]; then
  echo "==> relaunching $APP_NAME"
  open "$APP_DIR"
fi

echo "==> done: $APP_DIR"
