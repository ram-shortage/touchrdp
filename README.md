# TouchRDP

A native macOS Remote Desktop (RDP) client for Windows hosts. You authorise each connection with Touch ID. TouchRDP then takes the saved Windows password from the Keychain and passes it straight into the RDP sign-in, so you never type, paste or see a password prompt inside the session.

It is written in Swift (SwiftUI and AppKit) on top of [FreeRDP 3](https://www.freerdp.com), using Apple's LocalAuthentication and Security frameworks to guard passwords.

## Features

**Sign-in and security**
- Touch ID before any saved password is released. Each connection can prompt every time, or reuse a recent Touch ID for up to five minutes.
- Passwords are kept only in the Keychain. Connection profiles on disk never contain secrets.
- On a signed build, passwords are sealed by the Secure Enclave and tied to your currently enrolled fingerprints ([details](docs/ENABLE_SECURE_ENCLAVE.md)).
- Server certificates are pinned the first time you approve them. A changed certificate is rejected until you review and accept it.
- Optional separate RD Gateway password, released by the same single Touch ID prompt.
- Optional **Type Password** button for a remote lock screen. It is off by default and needs a fresh Touch ID every time.

**Sessions**
- Tabbed sessions, tear-off windows, and full screen with an auto-hiding toolbar.
- Live resize, Retina-aware rendering, and multi-monitor spanning or one window per display.
- Hardware H.264 decoding on the Apple Silicon media engine, with a per-connection software fallback.
- Clipboard in both directions for text, and optionally for images and files.
- Audio playback (the microphone is never shared), plus optional printer and single-folder sharing.
- Remote cursor shapes, keyboard layouts and key overrides, a Send Keys menu, and screenshots.
- Automatic reconnect with limits, so a flaky network or another device taking over the session can't cause a reconnect loop.
- Optional **Stay Awake**, which holds off the remote lock screen for a limited time.

**Connections**
- Groups, Quick Connect, `.rdp` file import, and per-connection display, performance and sharing settings.

## Download

Get the DMG from the [Releases](../../releases) page, open it and drag TouchRDP to Applications.

- Needs an Apple Silicon Mac running macOS 26 or later.
- Releases are code-signed but **not notarised**. The first time, right-click the app and choose **Open**, or allow it under System Settings → Privacy & Security.
- FreeRDP and everything else the app needs is bundled. Homebrew is not required.

## Building from source

```bash
brew install cmake pkgconf openssl@3 ffmpeg jpeg-turbo   # one-time
./Tools/build-freerdp.sh    # pinned FreeRDP with hardware H.264 decoding -> Vendor/freerdp
./Tools/build-app.sh        # builds and signs TouchRDP.app
open TouchRDP.app
```

[docs/BUILDING.md](docs/BUILDING.md) covers the details, packaging a DMG, and the release process.

## Tests

```bash
swift test               # unit tests
swift run ValidateCore   # headless checks of the core logic
./Tools/verify.sh        # builds every target, then runs ValidateCore
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md): how the code is organised and how a connection flows through it.
- [Building and releasing](docs/BUILDING.md)
- [Security model](docs/SECURITY.md): threat model, how passwords are protected, and known limits.
- [Secure Enclave mode](docs/ENABLE_SECURE_ENCLAVE.md): signing a build so passwords are hardware-bound.

## Licence

TouchRDP is licensed under the [Apache License 2.0](LICENSE). Third-party components are listed in [NOTICE](NOTICE). The release DMG bundles FFmpeg built with GPL components (x264 and x265), so the distributed app as a whole is subject to the GPL. The TouchRDP source code itself is Apache 2.0.
