#!/bin/bash
# Builds every release file into dist/: Mydroid-mac.zip, Mydroid.apk, Mydroid-extension.zip and SHA256SUMS.
#   scripts/release/build.sh 0.2.0
# The Android signing key comes from the environment or from ~/.mydroid-release/ on your Mac:
#   MYDROID_KEYSTORE, MYDROID_KEYSTORE_PASSWORD, MYDROID_KEY_ALIAS (default: mydroid)
# First run on a Mac with no key creates one in ~/.mydroid-release/. Back that folder up: a lost key means
# nobody can update the phone app without uninstalling it first.
set -euo pipefail

VERSION="${1:?usage: build.sh <version, e.g. 0.2.0>}"
VERSION="${VERSION#v}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="$ROOT/dist"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"

IFS=. read -r MAJ MIN PAT <<<"${VERSION%%-*}"
export MYDROID_VERSION_NAME="$VERSION"
export MYDROID_VERSION_CODE="$(( MAJ * 10000 + MIN * 100 + ${PAT:-0} ))"

if [ -z "${MYDROID_KEYSTORE:-}" ]; then
  KEYDIR="$HOME/.mydroid-release"
  export MYDROID_KEYSTORE="$KEYDIR/mydroid.jks"
  if [ ! -f "$MYDROID_KEYSTORE" ]; then
    mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
    pw="$(openssl rand -base64 24)"
    keytool -genkeypair -keystore "$MYDROID_KEYSTORE" -alias mydroid -keyalg RSA -keysize 4096 -validity 36500 \
      -storepass "$pw" -keypass "$pw" -dname "CN=Mydroid" >/dev/null
    printf '%s' "$pw" > "$KEYDIR/password"; chmod 600 "$KEYDIR/password"
    echo "Created a new Android signing key in $KEYDIR. Back it up now."
  fi
  MYDROID_KEYSTORE_PASSWORD="$(cat "$KEYDIR/password")"
  export MYDROID_KEYSTORE_PASSWORD
fi

rm -rf "$DIST"; mkdir -p "$DIST"

echo "== Mac app"
MYDROID_UNIVERSAL=1 MYDROID_VERSION="$VERSION" OUT="$DIST/mac" "$ROOT/mac/scripts/build-app.sh"
ditto -c -k --keepParent --sequesterRsrc "$DIST/mac/Mydroid.app" "$DIST/Mydroid-mac.zip"

echo "== Android app"
( cd "$ROOT/android" && ./gradlew -q :app:assembleRelease )
APK="$(ls "$ROOT"/android/app/build/outputs/apk/release/*.apk | head -1)"
BT="$(ls -d "$HOME"/Library/Android/sdk/build-tools/* 2>/dev/null | sort -V | tail -1)"
APKSIGNER="$(command -v apksigner || echo "$BT/apksigner")"
"$APKSIGNER" verify --print-certs "$APK" | tee "$DIST/apk-certificate.txt"
cp "$APK" "$DIST/Mydroid.apk"

echo "== Browser extension"
"$ROOT/scripts/release/extension.sh" "$DIST/Mydroid-extension.zip"

( cd "$DIST" && shasum -a 256 Mydroid-mac.zip Mydroid.apk Mydroid-extension.zip > SHA256SUMS && cat SHA256SUMS )
echo
echo "Release files are in $DIST (Mydroid-mac.zip, Mydroid.apk, Mydroid-extension.zip, SHA256SUMS)."
