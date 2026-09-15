#!/bin/bash
# Re-sign an unsigned IPA with an Ad Hoc distribution certificate + provisioning profiles.
# Env in:
#   IN_IPA       absolute path to unsigned .ipa
#   OUT_IPA      absolute path for the signed .ipa
#   APP_PROFILE  absolute path to the app .mobileprovision
#   EXT_PROFILE  absolute path to the extension .mobileprovision
#   KEYCHAIN     absolute path to the keychain holding the identity
set -euo pipefail

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

rm -f "$OUT_IPA"
unzip -q "$IN_IPA" -d "$WORK"

APP="$(ls -d "$WORK"/Payload/*.app)"
EXT="$(ls -d "$APP"/PlugIns/*.appex 2>/dev/null || true)"
echo "app: $APP"
echo "ext: $EXT"

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/Apple Distribution/ {print $2; exit}')"
if [ -z "$IDENTITY" ]; then
  echo "no Apple Distribution identity in keychain" >&2
  security find-identity -v -p codesigning "$KEYCHAIN" >&2
  exit 1
fi
echo "identity: $IDENTITY"

ent_from_profile() {
  security cms -D -i "$1" > "$WORK/profile.plist"
  /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$WORK/profile.plist" > "$2"
}

ent_from_profile "$APP_PROFILE" "$WORK/app.entitlements"
cp "$APP_PROFILE" "$APP/embedded.mobileprovision"

if [ -n "$EXT" ]; then
  ent_from_profile "$EXT_PROFILE" "$WORK/ext.entitlements"
  cp "$EXT_PROFILE" "$EXT/embedded.mobileprovision"
fi

sign_plain() {
  codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$1"
}

# 1. frameworks and dylibs inside the extension
if [ -n "$EXT" ] && [ -d "$EXT/Frameworks" ]; then
  for f in "$EXT"/Frameworks/*; do sign_plain "$f"; done
fi

# 2. the extension itself, with its own entitlements
if [ -n "$EXT" ]; then
  codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" \
    --entitlements "$WORK/ext.entitlements" "$EXT"
fi

# 3. frameworks and dylibs inside the app
if [ -d "$APP/Frameworks" ]; then
  for f in "$APP"/Frameworks/*; do sign_plain "$f"; done
fi

# 4. the app itself
codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" \
  --entitlements "$WORK/app.entitlements" "$APP"

echo "--- verify app ---"
codesign -dv --entitlements - "$APP" 2>&1 || true
if [ -n "$EXT" ]; then
  echo "--- verify extension ---"
  codesign -dv --entitlements - "$EXT" 2>&1 || true
fi
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$(dirname "$OUT_IPA")"
( cd "$WORK" && zip -qry "$OUT_IPA" Payload )
echo "signed ipa: $OUT_IPA"
ls -la "$OUT_IPA"
