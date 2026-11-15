# Madeira on iOS 18 with TrollStore

This branch follows current upstream Madeira and adds TrollStore packaging and JIT support. It is based on the upstream tree at the point this update was prepared; it does **not** carry forward the older fork's iOS 16 compatibility claim. Current upstream builds against iOS 18 and newer Apple toolchains.

## Install and enable JIT

1. Build or download `Madeira.tipa` from the TrollStore workflow artifact/release.
2. Install the `.tipa` with TrollStore.
3. Tap Madeira's **Enable JIT**, or use TrollStore's **Open with JIT** action. On pre-iOS 26 systems Madeira uses TrollStore's `apple-magnifier://enable-jit` URL and maps its executable pool locally after TrollStore sets `CS_DEBUGGED`. On iOS 26+, the existing StikDebug/built-in JIT paths remain in use.

This needs TrollStore 2.0.9 or later for the in-app URL handoff. If the handoff fails, launch Madeira from TrollStore using **Open with JIT**. The package marks its own Info.plist so ordinary sideloads on the same OS version do not switch into the local allocator.

## Build

The normal upstream IPA build is unchanged. After running the existing current-upstream native build and `tools/build-ipa.sh`, run `tools/build/package-tipa.sh`. Or pass `MADEIRA_IPA=dist/Madeira.ipa` to package an IPA produced by CI. Packaging removes the iOS 26-only helper extension/frameworks, signs nested Mach-O files and the main app with `ci/trollstore.entitlements`, then creates `dist/Madeira.tipa`. The application identifier and keychain group are set to `MADEIRA.<CFBundleIdentifier>`. This isolates the TrollStore package from credentials saved under another signing identity, so users may need to sign in again to Apple, Steam, GOG, Epic, EA or itch.io.

The TIPA package uses current upstream's iOS 18 floor. It does not make upstream compatible with iOS 16; reaching iOS 16 would require rebasing the old fork's broader SwiftUI, Metal/DXMT, libc++ and native dependency compatibility work.

## Validation status

The TrollStore JIT changes are not yet device-verified. Validate install, URL handoff, CS_DEBUGGED polling, executable pool allocation and representative JIT workload on hardware before considering this ready to distribute.
