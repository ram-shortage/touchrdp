# Security model

TouchRDP's main job is to keep a Windows password safe while still letting you connect with a single Touch ID. This document covers what it defends against, how, and where the limits are.

## Threat model

| Threat | Covered | How |
|--------|---------|-----|
| Someone at your unlocked Mac connects without permission | Yes | Touch ID is required before any saved password is released. |
| Password stolen from disk | Yes | Passwords live only in the Keychain. Connection profiles contain no secrets. |
| Password leaked through the clipboard, logs or crash dumps | Yes | The password is never put on the clipboard or logged, and the bridge wipes its copy right after sign-in. |
| Man-in-the-middle on the connection | Yes, unless you turn checking off | NLA (TLS plus CredSSP) by default, and certificates pinned on first use with an explicit review when they change. A connection set to "Don't check" has no protection here. |
| Malware running as you reads saved passwords | Partly | Covered on a signed build (Secure Enclave). Not covered on an unsigned build; see Limitations. |
| A hostile Windows host reads or writes your files | Yes, opt-in | Folder sharing is off by default and limited to one folder you pick. |
| A hostile host listens through your microphone | Yes | Only audio playback is enabled; the microphone is never redirected. |
| A fully compromised macOS or kernel keylogger | No | Out of scope for any client. |

## The password vault

The vault picks the strongest protection the app's signature allows, and the app shows which one is active.

- **Hardware-bound (signed builds).** The password is stored as a data-protection Keychain item with a `biometryCurrentSet` access control. The Secure Enclave seals it, and it can only be read after a Touch ID match against the fingerprints enrolled right now. Adding or removing a fingerprint invalidates the item, and the app asks you to save the password again. This needs an Apple Development signature; see [ENABLE_SECURE_ENCLAVE.md](ENABLE_SECURE_ENCLAVE.md).
- **App-gated (unsigned or ad-hoc builds).** The password is a normal app-scoped Keychain item, and the app requires a Touch ID check before every read.

All items are device-only and never synced to iCloud.

### What happens to the password

1. You type it once into a secure field, and it goes straight to the Keychain.
2. On connect, Touch ID releases it, and the engine passes it to FreeRDP's settings.
3. Once FreeRDP has used it for the NLA handshake, the bridge zeroes its own copy and clears the FreeRDP setting in place.
4. The session controller never keeps it. A reconnect asks the vault again.

### How long a Touch ID counts for

Each connection has a credential policy:

| Policy | Behaviour |
|--------|-----------|
| Ask every time (default) | Every connect you start prompts for Touch ID. Automatic reconnects shortly afterwards reuse that Touch ID without a new prompt. |
| Reuse recent Touch ID | No prompt if you authenticated within the reuse window. |
| Saved, longest window | Uses the longest window macOS allows, but is still gated by Touch ID. |

macOS caps reuse at five minutes. Every new authentication context disables reuse of the Mac's own unlock, so unlocking your Mac never counts as approving a connection. Only the authentication context is cached, never the password, and saving or deleting a password clears it.

### RD Gateway password

A connection can have a separate password for its RD Gateway. It's stored as a second Keychain item with the same protection, released by the same single Touch ID prompt, and wiped by the bridge in exactly the same way. Turning the option off or deleting the connection deletes it.

## Certificates

- **First connection:** the certificate's fingerprint, issuer and any host-name mismatch are shown for you to review. It's only pinned once you approve it, so a first-connection attack isn't silently accepted.
- **Later connections:** accepted only if the fingerprint matches the pinned one.
- **Changed certificate:** rejected by default. You can compare the old and new details and approve it explicitly.
- **Trusting a certificate in advance:** in the connection editor, **Trust a Certificate…** pins a certificate before the first connection, from its file (`.cer`, `.crt`, `.pem` or `.der`, binary or Base-64) or its SHA-256 fingerprint. It's stored exactly as if you had approved it in the review, so the first connection goes straight through and a different certificate is still rejected as a change. Windows shows a SHA-1 thumbprint by default; TouchRDP only accepts SHA-256 and says so if you paste a SHA-1 one.
- **Per-connection checking mode** (Connection tab → Security → Server certificate):

  | Mode | First-seen certificate | Changed certificate |
  |------|------------------------|---------------------|
  | Ask me to review (default) | Shown for review | Rejected, shown for review |
  | Trust automatically the first time | Trusted and pinned without asking, even if the name doesn't match | Rejected, shown for review |
  | Don't check | Accepted, not pinned | Accepted, not pinned |

  "Trust automatically" protects every connection after the first; the first one is only as safe as the network it's made on. "Don't check" accepts any certificate on every connection and never reads or changes your pins, so switching back restores exactly the pins you had. The connection's details show **Certificate: Not checked** while it's set.
- FreeRDP only exposes the subject, issuer and SHA-256 fingerprint, not the full certificate, so validity dates and serial numbers can't be shown.

## Reconnects

- Sign-in failures and certificate problems are never retried automatically, so the app can't hammer a server with bad credentials.
- When the server ends the session because another device took it over, an administrator disconnected it, or you were logged off, the app doesn't reconnect by itself. It shows a Reconnect button instead, so two clients can't keep kicking each other off.
- Network drops are retried within a per-connection budget (default one attempt, at most five, at least five seconds apart). The budget is only restored after a connection has stayed up for 60 seconds.
- Network-return and wake-from-sleep events can trigger one immediate retry per drop. They are debounced and use the same Touch ID-gated password path.

## Clipboard

- Clipboard sync is per connection. The Mac's clipboard is only sent while the session window is focused, so things you copy elsewhere aren't sent to the host in the background. Size is capped.
- **Images** are a separate opt-in, focus-gated in the same way, with a 64 MiB cap.
- **Files** are a third opt-in that covers both directions.
  - **Mac to Windows:** files are only *offered*; the host pulls them while the offer stands. Limits are 64 files and 256 MiB per offer, regular files only. Folders and symbolic links are rejected without being followed, and each file is opened once with `O_NOFOLLOW` so the path can't be swapped afterwards. Requests from the host are capped at 16 MiB per chunk and can't read past the file.
  - **Windows to Mac:** the app puts file *promises* on the pasteboard, so nothing is copied until you paste in Finder, and the host can't push data unasked. The file list from the server is treated as hostile: it's size-capped, checked for truncation, and each file name is cleaned so it can't escape the destination folder. Limits are 256 MiB per file, 1 GiB per copy, and 30 seconds per request.

## Sharing devices

- **Audio:** playback only. The microphone is never redirected.
- **Folder sharing:** off by default. When on, exactly one folder you choose is shared, read/write, because RDP's drive sharing has no read-only mode. The folder is checked when you pick it and again at connect, and sensitive locations (`/`, your home folder, `/Volumes`, `/System`, `/Library`, `/private`) are refused.
- **Printers:** off by default. When on, all local printers are offered to the session. The host learns their names and can send print jobs to them, but gets no access to local files.

## Stay Awake

Stay Awake holds off the remote lock screen by sending a harmless F15 key press. It is off by default, isn't saved between sessions, shows a countdown in the toolbar, and expires after a set time (five minutes by default, between 1 and 60) with no real activity from you. It can't unlock a session that's already locked and doesn't touch any credentials.

## Type Password (lock screen)

RDP has no way to hand a password to a session that's already running. The only routes in are a keyboard, a redirected smart card, or software installed on the Windows host. Type Password uses the keyboard route: it sends Ctrl-Alt-Del, waits for the sign-in screen, types the saved password, and presses Return.

**This is the one place the app can't be sure where the password goes.** RDP doesn't report whether the remote screen is locked, so if it's used at the wrong moment the password is typed into whichever window has focus and submitted there. The safeguards are:

- off by default, per connection, and the button doesn't exist until you turn it on;
- a dedicated toolbar button, never part of a menu or a reconnect action;
- a fresh Touch ID every time, whatever the connection's reuse policy;
- Return is only sent if the same session is still connected after the last character;
- sending Ctrl-Alt-Del first means an unlocked session shows Windows' security screen, which has no text field.

On the network this is identical to typing the password by hand. The bridge zeroes its working copy after typing.

## Limitations

1. **Unsigned builds and local malware.** On an unsigned build, something already running as you could read the Keychain item directly and skip the app's Touch ID check. Sign the build to get the hardware-bound vault; see [ENABLE_SECURE_ENCLAVE.md](ENABLE_SECURE_ENCLAVE.md).
2. **Swift strings.** The released password exists briefly as a Swift `String`, whose memory can't be guaranteed to be wiped. The window is kept as short as possible, and on signed builds the stored copy stays sealed by the Secure Enclave regardless.
3. **FreeRDP's own copies.** During the NLA handshake, FreeRDP keeps internal copies of the password that the bridge can't reach. FreeRDP frees them, but doesn't guarantee to zero them.
4. **Multi-factor sign-in.** The app supplies only the password. Any additional factor has to be completed in the session.
5. **Type Password can't check its target.** See above. Leave it off for hosts where a mistyped password would be a problem.
6. **Folder sharing is read/write.** A compromised host can change or delete anything in the shared folder. Share a small, dedicated folder.
7. **Turning certificate checking off.** A connection set to "Don't check" can't tell the real server from an impostor, and with NLA your password is sent to whichever one answers. Use it only on networks you control, and prefer trusting the certificate in advance.
8. **Third-party code.** Releases bundle a pinned FreeRDP built from source, plus FFmpeg and OpenSSL from Homebrew. Keep FreeRDP updated by changing the pin in `Tools/build-freerdp.sh`.

## Checks to run before a release

- [ ] `~/Library/Application Support/TouchRDP/` contains profiles and pinned certificates only, never passwords.
- [ ] No password appears in logs, standard output or the clipboard after connecting.
- [ ] Keychain items are device-only and not synced.
- [ ] A changed certificate is rejected and goes through the review flow.
- [ ] A certificate trusted in advance (file and pasted fingerprint) connects without a review; a different one is reviewed as a change.
- [ ] A wrong password doesn't trigger automatic reconnects.
