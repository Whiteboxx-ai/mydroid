# Releasing

## One-time setup

Keep the existing Android signing key and password in `~/.mydroid-release/` on your release Mac. Back up that folder. Updates must use the same key as the public APK.

## Each release

1. Run the local tests for the parts you changed. See [Contributing](../CONTRIBUTING.md).
2. Update `CHANGELOG.md` and push the release commit.
3. On the Mac with the signing key, run `scripts/release/build.sh 0.2.0` with the new version. It builds the Mac app for Apple silicon and Intel, the signed APK, and the extension ZIP.
4. Run `(cd dist && shasum -a 256 -c SHA256SUMS)`. Check the Android signing certificate against the previous release.
5. Create a draft GitHub release for the version, targeting the release commit. Attach the three binaries and `SHA256SUMS`. Publish once GitHub shows all four assets.

Release files use fixed names (`Mydroid-mac.zip`, `Mydroid.apk`) so `releases/latest/download/<name>` links and `install.sh` always work.

## Chrome Web Store

`dist/Mydroid-extension.zip` is the upload. The store gives it its own ID: add that ID to the native messaging manifest before publishing (see `AGENTS.md`). Store images come from `scripts/make-icons.py`.

## Website

From `site/`, run `npm ci`, `npm run build`, and `wrangler deploy`. The Worker serves the static site at `mydroid.whiteboxx.ai`. App downloads are attached to GitHub Releases.

## Android distribution

The website links to the signed APK. Keep the signing key backed up and register the package and signing identity for Android developer verification where required.

The homepage uses off-screen Mydroid fixture renders. The camera-roll render contains sample images from [Unsplash](https://unsplash.com/license). These photos keep their original terms.
