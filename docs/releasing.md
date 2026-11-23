# Releasing

## One-time setup

1. Create the Android signing key by running `scripts/release/build.sh 0.1.0` once on your Mac. It writes `~/.mydroid-release/mydroid.jks` and `password`. Back that folder up.
2. In the GitHub repo, add two secrets: `ANDROID_KEYSTORE_BASE64` (`base64 -i ~/.mydroid-release/mydroid.jks | pbcopy`) and `ANDROID_KEYSTORE_PASSWORD` (the contents of `password`).

## Each release

1. Update `CHANGELOG.md`.
2. Tag and push: `git tag v0.2.0 && git push origin v0.2.0`.
3. The Release workflow builds the Mac app (Apple silicon and Intel), the signed APK and the extension zip, attests them, and publishes them with `SHA256SUMS`.

Release files use fixed names (`Mydroid-mac.zip`, `Mydroid.apk`) so `releases/latest/download/<name>` links and `install.sh` always work.

## Chrome Web Store

`dist/Mydroid-extension.zip` is the upload. The store gives it its own ID: add that ID to the native messaging manifest before publishing (see `AGENTS.md`). Store images come from `scripts/make-icons.py`.

## Before the repo goes public

Choose a license, settle the `platform-tools` redistribution terms (`mac/scripts/build-app.sh`), and add the Android account for developer verification before January 2027.
