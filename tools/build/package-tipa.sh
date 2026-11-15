#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DERIVED="$ROOT/app/DerivedData"
DIST="$ROOT/dist"
CONFIGURATION="${CONFIGURATION:-Debug}"
IPA="${MADEIRA_IPA:-}"
APP="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/Madeira.app"
STAGE="$DIST/trollstore-stage"

rm -rf "$STAGE" "$DIST/Madeira.tipa"
mkdir -p "$STAGE/Payload"
if [[ -n "$IPA" ]]; then
  [[ -s "$IPA" ]] || { echo "ERROR: IPA not found: $IPA" >&2; exit 1; }
  ditto -x -k "$IPA" "$STAGE"
  [[ -d "$STAGE/Payload/Madeira.app" ]] || { echo "ERROR: IPA has no Payload/Madeira.app" >&2; exit 1; }
else
  [[ -d "$APP" ]] || { echo "ERROR: build Madeira.app first: $APP" >&2; exit 1; }
  python3 "$ROOT/tools/build/runtime-components.py" bundle "$APP"
  ditto "$APP" "$STAGE/Payload/Madeira.app"
fi
A="$STAGE/Payload/Madeira.app"
# Mark this package so local JIT allocation is never selected for ordinary
# sideloads that happen to run on an older iOS version.
if /usr/libexec/PlistBuddy -c 'Print :MadeiraTrollStore' "$A/Info.plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Set :MadeiraTrollStore true' "$A/Info.plist"
else
  /usr/libexec/PlistBuddy -c 'Add :MadeiraTrollStore bool true' "$A/Info.plist"
fi
/usr/libexec/PlistBuddy -c 'Set :MinimumOSVersion 18.0' "$A/Info.plist"
# Drop iOS 26-only JIT components, then remove Xcode signatures before
# applying TrollStore entitlements.
rm -rf "$A/PlugIns/MadeiraJITHelper.appex" "$A/PlugIns/MadeiraMemoryHost.appex" "$A/Frameworks/StikJIT.framework"
rmdir "$A/PlugIns" 2>/dev/null || true
find "$A" -name '_CodeSignature' -type d -prune -exec rm -rf {} +
rm -f "$A/embedded.mobileprovision"

if ! command -v ldid >/dev/null; then
  echo "ERROR: ldid is required to sign a TrollStore package" >&2
  exit 1
fi
while IFS= read -r -d '' f; do
  file_info=$(file "$f")
  if [[ "$file_info" == *Mach-O* && "$f" != "$A/Madeira" ]]; then ldid -S "$f"; fi
done < <(find "$A" -type f -print0)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$A/Info.plist")
# App-bundle keys are outside the code signature; keep the packaged Info.plist
# changes intact after applying the final executable signature.
/usr/libexec/PlistBuddy -c 'Set :MinimumOSVersion 18.0' "$A/Info.plist"
ENTITLEMENTS="$STAGE/trollstore.entitlements"
/usr/libexec/PlistBuddy -x -c 'Print' "$ROOT/ci/trollstore.entitlements" > "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Set :application-identifier MADEIRA.$BUNDLE_ID" \
  -c "Set :keychain-access-groups:0 MADEIRA.$BUNDLE_ID" "$ENTITLEMENTS"
ldid -S"$ENTITLEMENTS" "$A/Madeira"
ldid -e "$A/Madeira"

mkdir -p "$DIST"
(cd "$STAGE" && zip -qry -9 "$DIST/Madeira.tipa" Payload)
unzip -tq "$DIST/Madeira.tipa"
# Check the final archive layout and TrollStore-only metadata, not just the
# upstream runtime payloads.
VERIFY="$STAGE/verify"
mkdir -p "$VERIFY"
unzip -q "$DIST/Madeira.tipa" -d "$VERIFY"
VAPP="$VERIFY/Payload/Madeira.app"
test -d "$VAPP"
/usr/libexec/PlistBuddy -c 'Print :MadeiraTrollStore' "$VAPP/Info.plist" | grep -qx 'true'
/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$VAPP/Info.plist" | grep -qx '18.0'
test ! -e "$VAPP/PlugIns/MadeiraJITHelper.appex"
test ! -e "$VAPP/PlugIns/MadeiraMemoryHost.appex"
test ! -e "$VAPP/Frameworks/StikJIT.framework"
ldid -e "$VAPP/Madeira" > "$STAGE/final-entitlements.plist"
python3 - "$STAGE/final-entitlements.plist" "$BUNDLE_ID" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as source:
    entitlements = plistlib.load(source)
expected = {
    'application-identifier': f'MADEIRA.{sys.argv[2]}',
    'keychain-access-groups': [f'MADEIRA.{sys.argv[2]}'],
    'com.apple.developer.kernel.increased-memory-limit': True,
    'com.apple.security.cs.allow-jit': True,
    'com.apple.security.cs.allow-unsigned-executable-memory': True,
}
for key, value in expected.items():
    if entitlements.get(key) != value:
        raise SystemExit(f'Invalid TrollStore entitlement {key}: {entitlements.get(key)!r}')
print('Validated TrollStore entitlements')
PY
python3 "$ROOT/tools/build/runtime-components.py" ipa "$DIST/Madeira.tipa"
echo "Created $DIST/Madeira.tipa"
