#!/bin/bash
# Build every native library the app target links, for iOS 16 (TrollStore
# fork), on a GitHub macOS runner. Mirrors docs/BUILDING.md steps 1-4b and
# supplies the inputs it lists as "not in the repository".
#
#   ci/build-native.sh [stage...]
#
# Stages (default: all, in this order): freetype gnutls ffmpeg wine ntdll
# wineserver win32u fex llvm dxmt rppairing
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MADEIRA_IOS_MIN="${MADEIRA_IOS_MIN:-16.0}"
JOBS="$(sysctl -n hw.ncpu)"
TC="$R/toolchains"
mkdir -p "$TC"

LLVM_MINGW=llvm-mingw-20260421-ucrt-macos-universal
LLVM_MINGW_SHA=bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7
LLVM_SHA=8dfdcc7b7bf66834a761bd8de445840ef68e4d1a      # docs/BUILDING.md
FREETYPE_TAG=VER-2-13-3

log() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }

# The build scripts print FAILED per object and keep going; show why.
dump_errs() {
    local d=$1
    for e in "$d"/*.err; do
        [ -s "$e" ] || continue
        if grep -q "error:" "$e"; then
            echo "----- $e"
            grep -B2 -A3 "error:" "$e" | head -60
        fi
    done
}

stage_freetype() {
    log "freetype $FREETYPE_TAG"
    [ -d "$R/research/freetype" ] ||
        git clone --depth 1 --branch "$FREETYPE_TAG" https://github.com/freetype/freetype.git "$R/research/freetype"
    bash "$R/build/freetype-ios/build.sh"
}

stage_gnutls() {
    log "GMP / Nettle / GnuTLS"
    bash "$R/build/gnutls-ios/build.sh"
    # The script installs into toolchains/gnutls-ios only; the app links the
    # copies in app/Madeira (tracked, built for iOS 17), so replace them.
    for l in gmp nettle hogweed gnutls; do
        cp "$TC/gnutls-ios/lib/lib$l.a" "$R/app/Madeira/lib$l.a"
    done
}

stage_ffmpeg() {
    log "FFmpeg (LGPL)"
    bash "$R/build/ffmpeg/build.sh"
}

# llvm-mingw (pinned by docs/BUILDING.md) and Homebrew's bison 3 / flex on PATH.
mingw_toolchain() {
    if [ ! -d "$TC/$LLVM_MINGW" ]; then
        curl -fsSL -o "$TC/$LLVM_MINGW.tar.xz" \
            "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$LLVM_MINGW.tar.xz"
        echo "$LLVM_MINGW_SHA  $TC/$LLVM_MINGW.tar.xz" | shasum -a 256 -c -
        tar -C "$TC" -xJf "$TC/$LLVM_MINGW.tar.xz"
        rm "$TC/$LLVM_MINGW.tar.xz"
    fi
    export PATH="$TC/$LLVM_MINGW/bin:$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"
}

stage_wine() {
    log "llvm-mingw + configured Wine tree"
    mingw_toolchain
    local B="$R/wine/build-arm64ec"
    if [ ! -f "$B/config.status" ]; then
        mkdir -p "$B"
        (cd "$B" && ../configure --enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer) ||
            { tail -80 "$B/config.log"; exit 1; }
    fi
    make -C "$B" -j"$JOBS" __tooldeps__
    # Every IDL-generated header (wtypes.h, dwrite.h, mfobjects.h, ...): `make
    # include` is a no-op because the directory exists. -k: a few .idl files
    # make no header.
    local hdrs
    hdrs=$(cd "$R/wine/include" && ls *.idl | sed 's|\.idl$|.h|; s|^|include/|')
    make -C "$B" -k -j"$JOBS" $hdrs >/dev/null 2>"$B/idl-headers.err" || true
    ls "$B/include/wtypes.h" "$B/include/dwrite.h" "$B/include/mfobjects.h"
    # The unix-side scripts read the same configured tree under this name.
    ln -sfn build-arm64ec "$R/wine/build-macos"
}

# ARM64EC Windows modules the bundle lacks (installed into
# app/Madeira/arm64ec-windows): comctl32_v6, Common Controls 6.0 for 64-bit
# programs. Upstream seeds the side-by-side store only for 32-bit processes,
# so an x64 program whose manifest asks for Common Controls 6 got comctl32 5
# and aborted at its first v6-only call (TaskDialogIndirect).
#
# ntdll is rebuilt too, from the pinned Wine plus ci/patches/wine: its
# activation-context code must resolve "*" to amd64 in an ARM64EC process
# (0002), so x64 programs find the amd64_ entries the app seeds and the
# aarch64 desktop keeps its arm64_ lookups. The shipped ntdll.dll was built
# from the same pinned commit (7b56800), so nothing else changes.
stage_pe64() {
    log "ARM64EC modules: comctl32_v6, ntdll"
    mingw_toolchain
    JOBS="$JOBS" bash "$R/build/wine-pe/build-modules.sh" comctl32_v6
    test -f "$R/app/Madeira/arm64ec-windows/comctl32_v6.dll"
    # The shipped image already contains an "amd64" string elsewhere, so check the source.
    grep -A5 '^#elif defined __arm64ec__' "$R/wine/dlls/ntdll/actctx.c" | grep -q 'L"amd64"' ||
        { echo "ci/patches/wine/0002 is not applied" >&2; exit 1; }
    local before; before=$(wc -c < "$R/app/Madeira/arm64ec-windows/ntdll.dll")
    bash "$R/build/wine-pe/build-ntdll.sh"
    echo "ntdll.dll: shipped $before bytes, rebuilt $(wc -c < "$R/app/Madeira/arm64ec-windows/ntdll.dll") bytes"
}

# FEX's WOW64 module (app/Madeira/aarch64-windows/xtajit.dll), the CPU backend
# 32-bit programs run on, rebuilt from the pinned FEX plus ci/patches/FEX
# (0002 runs its C++ constructors in BTCpuProcessInit; without it every 32-bit
# program died in BTCpuThreadInit). The shipped copy was built from the same
# pinned commit (7b56800).
stage_wow64fex() {
    log "FEX WOW64 module (xtajit.dll)"
    mingw_toolchain
    grep -q '__main();' "$R/FEX/Source/Windows/Common/CRT/CRT_iOS.cpp" ||
        { echo "ci/patches/FEX/0002 is not applied" >&2; exit 1; }
    local before; before=$(wc -c < "$R/app/Madeira/aarch64-windows/xtajit.dll")
    bash "$R/build/fex-wow64/build.sh"
    echo "xtajit.dll: shipped $before bytes, rebuilt $(wc -c < "$R/app/Madeira/aarch64-windows/xtajit.dll") bytes"
}

# 32-bit programs (WoW64, docs/WOW64.md): the i386 Windows farm in
# app/Madeira/i386-windows (every i386 Wine module plus DXMT's 32-bit
# d3d9/d3d10core/d3d11/dxgi/winemetal). Without it the launcher treats an i386
# program as 64-bit and it dies in build_wow64_parameters.
stage_i386() {
    log "i386 Windows farm (WoW64)"
    mingw_toolchain
    JOBS="$JOBS" bash "$R/build/wine-i386/build.sh" || {
        tail -60 "$R/wine/build-i386/madeira-i386-build.log" 2>/dev/null
        exit 1
    }
    test -f "$R/app/Madeira/i386-windows/ntdll.dll"
    ls "$R/app/Madeira/i386-windows" | wc -l
}

stage_ntdll() {
    log "ntdll unix"
    bash "$R/build/ntdll-unix/build.sh" || { dump_errs "$R/build/ntdll-unix/obj"; exit 1; }
    dump_errs "$R/build/ntdll-unix/obj"
    test -f "$R/app/Madeira/libntdll_unix.a"
}

# build/wineserver/build.sh patches a base libwineserver.a that no script
# makes: build it from wine/server/*.c with the same flags (the script then
# swaps in its patched objects and renames the colliding symbols).
wineserver_base() {
    local B="$R/build/wineserver" O="$R/build/wineserver/obj/base"
    local SDK; SDK=$(xcrun --sdk iphoneos --show-sdk-path)
    local flags=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min="$MADEIRA_IOS_MIN" -O2
        -I"$R/wine/include" -I"$R/wine/include/wine" -I"$R/wine/build-macos/include"
        -I"$B" -I"$R/wine/server" -I"$R/build/ntdll-unix/shims"
        -I"$R/build/madsync" -DHAVE_LINUX_NTSYNC_H=1
        -include "$B/config_ios.h" -include stdarg.h -include "$B/unicode_fix.h"
        -include "$B/wineserver_ios_kill.h"
        -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
        -D__WINESRC__ -DWINE_IOS=1 -Dmain=wineserver_main -Wno-implicit-function-declaration)
    # Replaced by build.sh's patched objects, so a failure here does not matter.
    local replaced=" request main mach unicode fd process window user class region queue mapping winstation thread sock object async event semaphore handle inproc_sync "
    mkdir -p "$O"
    local bad=""
    for src in "$R"/wine/server/*.c; do
        local n; n=$(basename "$src" .c)
        if ! xcrun -sdk iphoneos clang "${flags[@]}" -c "$src" -o "$O/$n.o" 2>"$O/$n.err"; then
            rm -f "$O/$n.o"
            case "$replaced" in
                *" $n "*) echo "  base $n: failed (replaced by build.sh)";;
                *) echo "  base $n: FAILED"; grep -m5 "error:" "$O/$n.err"; bad="$bad $n";;
            esac
        fi
    done
    [ -z "$bad" ] || echo "WARNING: base objects that failed:$bad"
    mkdir -p "$R/build/wineserver/obj"
    ar rcs "$R/build/wineserver/obj/libwineserver.a" "$O"/*.o
}

stage_wineserver() {
    log "wineserver"
    export PATH="$(brew --prefix llvm)/bin:$PATH"   # llvm-objcopy
    [ -f "$R/build/wineserver/obj/libwineserver.a" ] || [ -f "$R/app/Madeira/libwineserver.a" ] || wineserver_base
    bash "$R/build/wineserver/build.sh" || { dump_errs "$R/build/wineserver/obj"; exit 1; }
    test -f "$R/app/Madeira/libwineserver.a"
}

stage_win32u() {
    log "win32u unix"
    bash "$R/build/win32u-unix/build.sh" || { dump_errs "$R/build/win32u-unix/obj"; exit 1; }
    test -f "$R/app/Madeira/libwin32u_unix.a"
}

stage_fex() {
    log "FEXCore (iOS)"
    bash "$R/build/fex-ios/build.sh"
}

stage_llvm() {
    log "LLVM $LLVM_SHA for iOS (airconv)"
    local S="$TC/llvm-project" H="$TC/llvm-host-build" B="$TC/llvm-ios-build"
    if [ -f "$B/.done" ]; then echo "cached"; return 0; fi
    if [ ! -d "$S/llvm" ]; then
        git init -q "$S"
        git -C "$S" fetch -q --depth 1 https://github.com/llvm/llvm-project.git "$LLVM_SHA"
        git -C "$S" checkout -q FETCH_HEAD
    fi
    local common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD=
        -DLLVM_ENABLE_PROJECTS= -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF
        -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF -DLLVM_ENABLE_ZLIB=OFF
        -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF
        -DLLVM_ENABLE_BINDINGS=OFF -DCMAKE_CXX_FLAGS=-Wno-deprecated-declarations)
    cmake -S "$S/llvm" -B "$H" "${common[@]}"
    ninja -C "$H" llvm-tblgen
    cmake -S "$S/llvm" -B "$B" "${common[@]}" \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MADEIRA_IOS_MIN" \
        -DLLVM_HOST_TRIPLE="arm64-apple-ios$MADEIRA_IOS_MIN" \
        -DLLVM_DEFAULT_TARGET_TRIPLE="arm64-apple-ios$MADEIRA_IOS_MIN" \
        -DLLVM_TARGET_ARCH=AArch64 -DLLVM_BUILD_TOOLS=OFF -DLLVM_BUILD_UTILS=OFF \
        -DLLVM_TABLEGEN="$H/bin/llvm-tblgen"
    ninja -C "$B" LLVMPasses LLVMBitWriter LLVMBitReader LLVMCore LLVMSupport
    # Keep only what dxmt-ios/build.sh and the combined archive read (CI cache size).
    find "$B" -name '*.o' -delete
    touch "$B/.done"
}

stage_dxmt() {
    log "DXMT unix + airconv, libdxmt_combined.a"
    # iOS 16 loads Metal 3.0 libraries at most (see ci/patches/dxmt).
    export DXMT_METAL_STD="${DXMT_METAL_STD:-metal3.0}" DXMT_METAL_SDK=iphoneos \
           DXMT_METAL_TARGET="air64-apple-ios$MADEIRA_IOS_MIN"
    bash "$R/build/dxmt-ios/build.sh" || { dump_errs "$R/build/dxmt-ios/obj"; exit 1; }
    # The combined archive: DXMT's objects plus the LLVM libraries airconv uses.
    # Not scripted upstream ("build it before deploying"); libtool -static
    # merges them, and the app link pulls only what it references.
    local llvm_libs=("$TC"/llvm-ios-build/lib/libLLVM*.a)
    xcrun -sdk iphoneos libtool -static -no_warning_for_no_symbols \
        -o "$R/app/Madeira/libdxmt_combined.a" "$R/build/dxmt-ios/libdxmt_unix.a" "${llvm_libs[@]}"
    ls -l "$R/app/Madeira/libdxmt_combined.a"
}

stage_rppairing() {
    log "rppairing (Rust)"
    rustup target add aarch64-apple-ios
    bash "$R/build/rppairing-ios/build.sh"
}

# Madeira's submodules are upstream forks we do not own; this port's changes
# to them are patches applied here.
for d in "$R"/ci/patches/*/; do
    sub=$(basename "$d")
    for p in "$d"*.patch; do
        if git -C "$R/$sub" apply --check "$p" 2>/dev/null; then
            git -C "$R/$sub" apply "$p" && echo "applied $sub/$(basename "$p")"
        fi
    done
done

# Every archive the app links must target iOS <= $MADEIRA_IOS_MIN: a newer
# object links with only a warning and can then use APIs iOS 16 lacks.
stage_verify() {
    log "deployment targets of the linked archives"
    local bad=0 f v
    for f in "$R"/app/Madeira/lib*.a "$R"/FEX/build-ios/FEXCore/Source/*.a; do
        [ -f "$f" ] || continue
        v=$(otool -l "$f" 2>/dev/null | awk '$1=="minos"{print $2} $1=="version" && prev=="LC_VERSION_MIN_IPHONEOS"{print $2} {prev=$2}' | sort -uV | tail -1)
        printf '  %-28s %s\n' "$(basename "$f")" "${v:-?}"
        if [ -n "$v" ] && [ "$(printf '%s\n%s\n' "$v" "$MADEIRA_IOS_MIN" | sort -V | tail -1)" != "$MADEIRA_IOS_MIN" ]; then
            echo "    ^ newer than iOS $MADEIRA_IOS_MIN"; bad=1
        fi
    done
    [ $bad -eq 0 ]
}

STAGES=("$@")
[ ${#STAGES[@]} -gt 0 ] || STAGES=(freetype gnutls ffmpeg wine ntdll wineserver win32u fex llvm dxmt rppairing)
for s in "${STAGES[@]}"; do
    start=$SECONDS
    "stage_$s"
    echo "--- $s took $((SECONDS - start))s"
done
