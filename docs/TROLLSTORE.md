# Madeira on iOS 16 with TrollStore

This fork builds Madeira for **iOS 16.0 and later**, installed with
[TrollStore](https://github.com/opa334/TrollStore) instead of a sideloader.
iOS 16.2 is the target. Every build comes from GitHub Actions
(`.github/workflows/build-trollstore.yml`). No Mac is needed.

## Install

1. Download `Madeira-<version>-trollstore.tipa` from the latest release, or
   from the `Madeira-trollstore-tipa` artifact of a successful Actions run.
2. Open it with TrollStore and install it.
3. Start Madeira with JIT, in either of two ways:
   - In TrollStore's app list, long-press **Madeira** → **Open with JIT**.
   - Or open Madeira normally and tap **Enable JIT**. Madeira asks TrollStore
     through its `apple-magnifier://enable-jit` URL; TrollStore 2.0.9 or later
     is needed for that.

You don't need StikDebug, LocalDevVPN, a pairing file or a computer. The
signature doesn't expire, so there's no weekly refresh.

## What differs from upstream

| Area | Upstream (iOS 26) | This fork (iOS 16) |
|---|---|---|
| JIT memory | iOS 26 has TXM, so only a debugger can make executable pages. StikDebug stays attached and answers Madeira's `BRK #0xf00d` requests. | No TXM. With `CS_DEBUGGED` set by TrollStore's attach-and-detach, Madeira maps its own RX pool (`jit_local_mode()` in `app/Madeira/JITAllocator.c`). No debugger stays attached. |
| Enabling JIT | StikDebug or the built-in StikJIT helper | TrollStore |
| JIT helper extension, StikJIT.framework | bundled | removed from the package (they need iOS 26 / 17.4) |
| Entitlements | from the sideloader's profile | `ci/trollstore.entitlements`: `get-task-allow`, increased memory limit, extended virtual addressing, keychain group |
| Shader libraries | Metal 3.1/3.2, AIR 2.6/2.7 | On iOS < 17, airconv stamps Metal 3.0 / AIR 2.5, the highest iOS 16 loads (`ci/patches/dxmt`). `DXMT_LEGACY_AIR=0/1` overrides this. |
| SwiftUI | iOS 17 APIs (`@Observable`, two-value `onChange`, `ContentUnavailableView`) | iOS 16 equivalents |

`MADEIRA_JIT_LOCAL=0/1` (in `madeira.cfg` as `env.MADEIRA_JIT_LOCAL`) forces
the JIT mode either way.

## Requirements and limits

- iOS 16.0 or later with TrollStore. A12 or newer; Metal 3 (needed by the
  D3D11/D3D12 paths) needs an A13 or newer.
- This port has not been tested on a device. Upstream is developed on iOS 26
  and recent Pro iPhones. Expect the same rough edges as upstream, plus
  iOS 16-specific ones, mainly in the Metal translation layers (DXMT, and
  D3D12 through Metal Shader Converter). Logs are under **Settings → Logs**.
  Please report what you find.
- Microsoft's Visual C++ runtime isn't bundled, same as upstream.

## Building

Push to `main` or run the workflow by hand. It has three jobs:

- `native`: `ci/build-native.sh` builds Wine's unix side, FEX, FFmpeg,
  GnuTLS, freetype and the Rust pairing library for iOS 16.
- `dxmt`: builds LLVM for iOS (cached, about an hour the first time) and DXMT.
- `app`: `ci/build-app.sh` runs `xcodebuild` without signing, strips the
  iOS 26-only parts, signs with `ldid` and the TrollStore entitlements, and
  zips a `.tipa`.

Pushing a `v*` tag publishes the `.tipa` as a release.
