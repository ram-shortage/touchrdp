# Building and releasing

## Requirements

- An Apple Silicon Mac.
- Xcode or the Command Line Tools with Swift 6.2 or later.
- Homebrew, for the build dependencies.

## 1. Build FreeRDP (recommended)

```bash
brew install cmake pkgconf openssl@3 ffmpeg jpeg-turbo
./Tools/build-freerdp.sh
```

This downloads a pinned FreeRDP release, checks its SHA-256, applies the patches in `Tools/freerdp-patches/`, and installs it into `Vendor/freerdp` (git-ignored). The build:

- turns on hardware H.264 decoding through VideoToolbox;
- compiles MD4 and RC4 into FreeRDP itself, so NLA sign-in doesn't depend on OpenSSL's optional "legacy" module being installed.

To pin a different FreeRDP release, set `FREERDP_VERSION` and `FREERDP_SHA256`.

The FreeRDP libraries are built for the macOS SDK they are compiled against. If your Mac runs a newer macOS than the one you want to support, point the build at the older SDK so the app doesn't call functions that don't exist there:

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./Tools/build-freerdp.sh
```

You can skip this step and use Homebrew's FreeRDP (`brew install freerdp`), but you'll get software-only video decoding.

## 2. Build the app

```bash
./Tools/build-app.sh
```

This builds a release binary and assembles `TouchRDP.app`. Signing depends on `SIGN_IDENTITY`:

| `SIGN_IDENTITY` | Result |
|-----------------|--------|
| not set | Signed with a stable local identity (`LOCAL_SIGN_IDENTITY`, default `MyCodeSign`), falling back to ad-hoc. Passwords use the app-gated Keychain tier. |
| `"Apple Development: you@example.com (TEAMID)"` | Signed with your Apple Development certificate and the Keychain entitlement. Passwords are sealed by the Secure Enclave. See [ENABLE_SECURE_ENCLAVE.md](ENABLE_SECURE_ENCLAVE.md). |

Keep the same signing identity between builds. Keychain items belong to the app's signature, so changing it makes previously saved passwords unreadable and you'll have to save them again.

The app built this way links FreeRDP from `Vendor/freerdp` or Homebrew, so it only runs on the machine that built it.

## 3. Make it self-contained

```bash
SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./Tools/vendor-libs.sh TouchRDP.app
```

This copies every non-system library the app uses (FreeRDP, FFmpeg, OpenSSL and their dependencies) into `TouchRDP.app/Contents/Frameworks`, rewrites their load paths, and re-signs everything from the inside out. The result runs on any Apple Silicon Mac with the same or a newer macOS. The script refuses a FreeRDP that wasn't built with MD4 compiled in, unless you set `ALLOW_EXTERNAL_MD4=1` for local testing.

## 4. Test

```bash
swift test               # unit tests
swift run ValidateCore   # headless core checks
./Tools/verify.sh        # builds every target, then runs ValidateCore
```

`ValidateLive` drives a real connection and needs a reachable Windows host; it isn't part of the routine checks.

## Releasing

Releases are **signed with an Apple Development certificate and not notarised**.

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Tools/Info.plist` on a branch, open a pull request, and merge it.
2. Build from a clean checkout of the merged commit:
   ```bash
   SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./Tools/build-freerdp.sh
   SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./Tools/build-app.sh
   SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./Tools/vendor-libs.sh TouchRDP.app
   codesign --verify --deep --strict TouchRDP.app
   ```
3. Make the disk image with an Applications shortcut:
   ```bash
   mkdir -p dmg && cp -R TouchRDP.app dmg/ && ln -s /Applications dmg/Applications
   hdiutil create -volname TouchRDP -srcfolder dmg -format UDZO TouchRDP-vX.Y.Z.dmg
   ```
4. Mount the DMG and launch the app from it to check it starts.
5. Publish it: `gh release create vX.Y.Z TouchRDP-vX.Y.Z.dmg --target <commit sha>`.

Note that a signature names its certificate, so anyone can read the certificate's name (for an Apple Development certificate, the Apple ID email) from a released app.

`Tools/package-app.sh` and `Tools/package-portable.sh` are older one-step packagers that produce an ad-hoc-signed DMG or zip. They are useful for quick local hand-offs but aren't used for releases.
