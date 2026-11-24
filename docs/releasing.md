# Releasing

## One-time setup

1. Create the Android signing key by running `scripts/release/build.sh 0.1.0` once on your Mac. It writes `~/.mydroid-release/mydroid.jks` and `password`. Back that folder up.
2. For automated GitHub releases, in the GitHub repo, add two secrets: `ANDROID_KEYSTORE_BASE64` (`base64 -i ~/.mydroid-release/mydroid.jks | pbcopy`) and `ANDROID_KEYSTORE_PASSWORD` (the contents of `password`).

## Each release

1. Update `CHANGELOG.md`.
2. Tag and push: `git tag v0.2.0 && git push origin v0.2.0`.
3. The Release workflow builds the Mac app (Apple silicon and Intel), the signed APK and the extension zip, attests them, and publishes them with `SHA256SUMS`.

Release files use fixed names (`Mydroid-mac.zip`, `Mydroid.apk`) so `releases/latest/download/<name>` links and `install.sh` always work.

## Chrome Web Store

`dist/Mydroid-extension.zip` is the upload. The store gives it its own ID: add that ID to the native messaging manifest before publishing (see `AGENTS.md`). Store images come from `scripts/make-icons.py`.

## Website

From `site/`, run `npm ci`, `npm run build`, and `wrangler deploy`. The Worker serves the static site at `mydroid.whiteboxx.ai`. App downloads are attached to GitHub Releases.

## Android distribution

The website links to the signed APK. Keep the signing key backed up and register the package and signing identity for Android developer verification where required.

The homepage uses off-screen Mydroid fixture renders. The camera-roll render contains sample images from [Unsplash](https://unsplash.com/license). These photos keep their original terms.
