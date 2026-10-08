# Secure Enclave mode

TouchRDP's password vault has two levels of protection and picks the strongest one the app's signature allows when it starts:

| Mode | How the password is protected | Needs |
|------|-------------------------------|-------|
| **Hardware-bound** | Sealed by the Secure Enclave, readable only after a Touch ID match against the currently enrolled fingerprints. Enforced by macOS. | An Apple Development signature |
| **App-gated** | A normal Keychain item; the app requires Touch ID before reading it. | Nothing |

Unsigned and ad-hoc builds run app-gated, because the `keychain-access-groups` entitlement the hardware-bound mode needs is only honoured on properly signed apps. A free Apple Development certificate (a personal team, no paid membership) is enough. No code changes are needed.

Official releases are already signed this way.

## 1. Get an Apple Development certificate

1. Open Xcode → **Settings** → **Accounts**.
2. Click **+** and sign in with an Apple ID. A free account works; Xcode creates a personal team.
3. Under **Manage Certificates**, add an **Apple Development** certificate.

Check it's installed:

```bash
security find-identity -v -p codesigning
```

## 2. Build with it

```bash
SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./Tools/build-app.sh
```

For a self-contained app, run `vendor-libs.sh` with the same identity afterwards (see [BUILDING.md](BUILDING.md)).

## 3. Check it worked

Launch the app and open **Settings**. The active tier should read **Hardware-bound (Secure Enclave)**. The connection details and editor show the same label next to saved passwords.

If it says **Touch ID gated** instead:

- make sure the identity appears in `security find-identity -v -p codesigning`;
- look in the Console app for entitlement errors, filtering on `com.touchrdp.app`.

## Things to know

- Adding or removing a fingerprint invalidates hardware-bound items. The app tells you and asks you to save the password again.
- Saving a password removes any copy stored at the other level first, so moving from app-gated to hardware-bound happens the next time you save each password.
- Keep using the same certificate. Keychain items belong to the app's signature, so a build signed differently can't read passwords saved by the previous one.
- A development certificate is for local use. It can't be used for the App Store or for notarisation.
