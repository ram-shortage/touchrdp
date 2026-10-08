# Architecture

TouchRDP is a Swift package with four layers. Each layer may only depend on the ones below it, and the package's target dependencies enforce that.

```
TouchRDP (SwiftUI + AppKit app)
   │
   ▼
TouchRDPEngine (Swift) ──────► CRDPBridge (C) ──► FreeRDP 3
   │
   ▼
TouchRDPCore (pure Swift: models, rules, storage, vault)
```

| Target | Language | What it does |
|--------|----------|--------------|
| `CRDPBridge` | C | A thin wrapper around `libfreerdp-client3`. Swift only sees `rdpbridge.h`, a small, clean API; FreeRDP's own headers stay inside `rdpbridge.c`. It runs the RDP event loop on its own thread and reports state, frames, certificates, clipboard data and errors through callbacks. |
| `TouchRDPCore` | Swift | Everything that doesn't need FreeRDP or a UI: connection models, the Keychain vault, the connection and certificate stores, keyboard mapping, reconnect rules, clipboard and file-transfer validation, multi-monitor layout maths. It can be tested on its own. |
| `TouchRDPEngine` | Swift | Turns the C bridge into Swift objects. `FreeRDPSession` wraps one bridge connection; `SessionController` owns a session, handles reconnects and exposes observable state to SwiftUI; `AppCoordinator` ties the vault, stores and sessions together. |
| `TouchRDP` | Swift | The app: connection list, editor, tabbed and detached session windows, preferences and menus. |
| `ValidateCore` | Swift | A headless check harness for `TouchRDPCore` (`swift run ValidateCore`). |
| `ValidateLive` | Swift | A live end-to-end check that drives a real RDP connection through the bridge. Needs a Windows host. |

Unit tests are in `Tests/TouchRDPCoreTests`.

## How a connection works

1. **Reachability check.** `ReachabilityProbe` opens a plain TCP connection to the host first, so a network problem is reported as a network problem, not as a failed password prompt.
2. **Touch ID and password.** `AppCoordinator` asks `KeychainCredentialVault` for the password. The vault shows the Touch ID prompt (or reuses a recent one, depending on the connection's policy) and returns the secret.
3. **Connect.** `FreeRDPSession` passes the settings and password to the bridge, which starts FreeRDP on its own thread. The password is used for the NLA (network-level authentication) handshake, then wiped from the bridge's memory and from FreeRDP's settings.
4. **Certificate check.** FreeRDP calls back with the server certificate. The engine compares it with `FileCertificateTrustStore` and, if it's new or changed, waits for the user to review it before continuing.
5. **Frames.** FreeRDP draws into a software framebuffer. The bridge reports which rows changed; the engine copies only those rows into a pooled `IOSurface` (shared GPU-ready memory) and hands it to the view, which displays it without another copy. Frame delivery to the main thread is coalesced so a busy session can't flood the UI.
6. **Input.** Key presses are mapped to PC scancodes by `ScancodeKeyboardMapper`, with a Unicode fallback for characters the remote layout can't produce. Mouse, scroll and modifier changes go through the same bridge input API.
7. **Disconnects and reconnects.** When a session ends, the bridge reports the server's reason. `ReconnectDecider` decides whether to retry: network drops are retried within a per-connection budget; sign-in failures, certificate problems, and sessions ended or taken over by the server are not. The budget is only restored after a connection has stayed up for 60 seconds, so a connect-then-drop cycle can't loop forever. `ReconnectMonitor` also triggers a prompt retry when the network comes back or the Mac wakes.

## Video decoding

Windows sends most screen updates as H.264 video when the graphics pipeline is in use. The FreeRDP build in `Vendor/freerdp` is compiled with FFmpeg's VideoToolbox support, so H.264 is decoded by the Apple Silicon media engine. A small patch (`Tools/freerdp-patches/`) lets each connection switch to software decoding instead. "Full-colour text" (AVC444) can also be turned off per connection, which halves the decoding work.

If `Vendor/freerdp` is missing, the package links Homebrew's FreeRDP instead, which decodes in software. `TOUCHRDP_FREERDP_PREFIX=/path` overrides both.

## Where data is stored

| Data | Location |
|------|----------|
| Connection profiles (no secrets) | `~/Library/Application Support/TouchRDP/` |
| Pinned server certificates | `~/Library/Application Support/TouchRDP/` |
| Passwords | macOS Keychain, device-only, never synced |

## Threads

FreeRDP callbacks arrive on the bridge's RDP thread. The engine moves everything to the main thread before touching UI state, except the certificate check, which blocks the RDP thread until the user decides. Shared bridge state is guarded by a lock, and teardown waits for the RDP thread to finish before freeing anything.
