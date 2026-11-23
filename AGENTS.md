# Mydroid

A Mac menu-bar app (`mac/`), an Android app (`android/`), a Chrome extension (`extension/`), the wire protocol (`protocol/PROTOCOL.md`) and the website (`site/`).

## Where things live

- Build and test commands: `mac/README.md`, `android/README.md`, `extension/README.md`. Open the one for the part you change.
- Protocol behaviour: `protocol/PROTOCOL.md` only. Code and docs point at its section numbers.
- User docs: `site/src/content/docs/` only. The root `README.md` links there and carries no how-to text of its own.
- Releases: `docs/releasing.md`.

## Conventions the code doesn't show

- Mydroid ships outside every app store and needs no Apple or Google developer account. The Mac app is ad-hoc signed, and `install.sh` is the install path because `curl` downloads skip Gatekeeper. Keep both facts true when touching installers or docs.
- The extension ID is `NativeMessaging.extensionID` in `mac/Sources/MydroidNM/NativeMessaging.swift`, derived from the manifest `key`. The Chrome Web Store build drops the `key` (`scripts/release/extension.sh`) and gets its own ID. Add that ID next to the existing one in the native messaging manifest; replace nothing.
- All icons and store images come from `scripts/make-icons.py`. Edit the script and re-run it; leave generated files untouched.
- The Android signing key lives in `~/.mydroid-release/` and in CI secrets. It never enters the repo. Losing it blocks in-place updates for every user.
- `platform-tools` (adb) is bundled in the Mac app by `mac/scripts/build-app.sh`. Its redistribution terms are unconfirmed, so keep it out of anything described as final until that is settled.

## Writing for users

Write app text and docs in short, plain sentences, one idea each. Lead with what the user does. Show a step as one line. Name a thing once and keep that name everywhere. Put detail behind a link and keep the page a user lands on short.
