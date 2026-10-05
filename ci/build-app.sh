#!/bin/bash
# Build Madeira.app (Debug, the configuration that runs games) without a
# signing identity, then package it for TrollStore: drop the iOS 26-only JIT
# helper and StikJIT, sign with ldid and TrollStore's entitlements, zip a .tipa.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$R/out"
DD="$R/build/DerivedData"
mkdir -p "$OUT"
# Microsoft's VC++ runtime DLLs are not in the repository (docs/BUILDING.md);
# the project expects the folder, games that need the runtime install it.
mkdir -p "$R/app/Madeira/x86_64-vcruntime"

bash "$R/build/stage-licenses.sh" >/dev/null 2>&1 || true

set +e
xcodebuild -project "$R/app/Madeira.xcodeproj" -scheme Madeira -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    ENABLE_DEBUG_DYLIB=NO COMPILER_INDEX_STORE_ENABLE=NO \
    build > "$OUT/xcodebuild.log" 2>&1
rc=$?
set -e
grep -E "error:|warning: .*only available|BUILD (SUCCEEDED|FAILED)|\*\* " "$OUT/xcodebuild.log" | sort -u | head -300 || true
[ $rc -eq 0 ] || { echo "xcodebuild failed ($rc); full log in the xcodebuild-log artifact"; exit $rc; }

APP="$DD/Build/Products/Debug-iphoneos/Madeira.app"

# iOS 16.2 launch check: a symbol bound strongly to a system library that the
# OS does not export stops dyld before main. Every strong libc++ import must be
# in iOS 15.6's export list (a subset of 16.2's); newer ones are defined in the
# app instead (app/Madeira/iOS16LibcxxCompat.cpp) or avoided in the native build.
export LC_ALL=C   # one collation for sort and comm
imports=$(nm -m -u "$APP/Madeira" | grep -v weak | grep "from libc++" | awk '{print $3}' | sort -u)
too_new=$(comm -23 <(echo "$imports") <(grep -v '^#' "$R/ci/libcxx-ios15.6-exports.txt" | sort -u))
if [ -n "$too_new" ]; then
    echo "error: the binary imports libc++ symbols that iOS 16.2 may not have:"
    echo "$too_new"
    exit 1
fi
echo "libc++ imports: $(echo "$imports" | wc -l | tr -d ' '), all in iOS 15.6's libc++"

STAGE="$OUT/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/Madeira.app"
A="$STAGE/Payload/Madeira.app"
# iOS 26-only (StikJIT needs 17.4, the helper 26.0); JIT comes from TrollStore.
rm -rf "$A/PlugIns/MadeiraJITHelper.appex" "$A/Frameworks/StikJIT.framework"
rmdir "$A/PlugIns" 2>/dev/null || true
find "$A" -name '_CodeSignature' -type d -prune -exec rm -rf {} +
rm -f "$A/embedded.mobileprovision"

# Every Mach-O except the main executable: plain ad-hoc signature.
while IFS= read -r f; do
    if file "$f" | grep -q "Mach-O" && [ "$f" != "$A/Madeira" ]; then
        ldid -S "$f"
    fi
done < <(find "$A" -type f \( -name '*.dylib' -o -perm -u+x \))
ldid -S"$R/ci/trollstore.entitlements" "$A/Madeira"
ldid -e "$A/Madeira"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$A/Info.plist")
MINOS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$A/Info.plist")
echo "Madeira $VERSION, MinimumOSVersion $MINOS"
(cd "$STAGE" && zip -qry -9 "$OUT/Madeira-$VERSION-trollstore.tipa" Payload)
ls -l "$OUT"/*.tipa
