#!/bin/bash
# Installs Mydroid on a Mac. Run: curl -fsSL https://raw.githubusercontent.com/gautamm20/mydroid/main/install.sh | bash
# Options: --version vX.Y.Z   install a specific release
#          --uninstall        remove the app (add --purge to delete its data too)
# Test overrides: MYDROID_BASE_URL (folder holding Mydroid-mac.zip and SHA256SUMS), MYDROID_INSTALL_DIR (install there and
#                 leave any running Mydroid alone), MYDROID_REPO.
set -euo pipefail

REPO="${MYDROID_REPO:-gautamm20/mydroid}"
VERSION=""
MODE=install
PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a tag}"; shift ;;
    --uninstall) MODE=uninstall ;;
    --purge) PURGE=1 ;;
    -h|--help) sed -n 2,6p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "Mydroid for Mac only runs on macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || die "Mydroid needs macOS 14 or newer (this Mac has $(sw_vers -productVersion))."

quit_app() {
  pgrep -x Mydroid >/dev/null || return 0
  osascript -e 'tell application id "com.mydroid.mac" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Mydroid >/dev/null || return 0; sleep 0.5; done
  pkill -x Mydroid || true
}

if [ "$MODE" = uninstall ]; then
  quit_app
  for d in /Applications "$HOME/Applications"; do
    [ -d "$d/Mydroid.app" ] && { rm -rf "$d/Mydroid.app" && say "Removed $d/Mydroid.app"; }
  done
  # The browser connection files Mydroid wrote; they are useless without the app.
  rm -rf "$HOME/Library/Application Support/Mydroid/NativeMessagingHosts"
  find "$HOME/Library/Application Support" -path '*NativeMessagingHosts/com.mydroid.otp.json' -delete 2>/dev/null || true
  if [ "$PURGE" = 1 ]; then
    rm -rf "$HOME/Library/Application Support/Mydroid" "$HOME/Library/Caches/Mydroid"
    security delete-generic-password -s com.mydroid.mac >/dev/null 2>&1 || true
    say "Deleted Mydroid's data. Your photos and downloads stay where they are."
  else
    say "Kept your pairing and settings. Add --purge to delete them too."
  fi
  exit 0
fi

if [ -n "${MYDROID_BASE_URL:-}" ]; then
  BASE="$MYDROID_BASE_URL"
elif [ -n "$VERSION" ]; then
  BASE="https://github.com/$REPO/releases/download/$VERSION"
else
  BASE="https://github.com/$REPO/releases/latest/download"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() { # url dest
  case "$1" in
    file://*) cp "${1#file://}" "$2" ;;
    *) curl -fL --proto '=https' --tlsv1.2 --retry 3 --progress-bar "$1" -o "$2" ;;
  esac
}

say "Downloading Mydroid…"
fetch "$BASE/SHA256SUMS" "$work/SHA256SUMS" || die "Couldn't reach the download. Check your connection and try again."
fetch "$BASE/Mydroid-mac.zip" "$work/Mydroid-mac.zip" || die "Couldn't download Mydroid-mac.zip."

expected="$(awk '$2 == "Mydroid-mac.zip" || $2 == "*Mydroid-mac.zip" {print $1}' "$work/SHA256SUMS")"
actual="$(shasum -a 256 "$work/Mydroid-mac.zip" | awk '{print $1}')"
[ -n "$expected" ] || die "SHA256SUMS has no entry for Mydroid-mac.zip."
[ "$expected" = "$actual" ] || die "The download is damaged (checksum mismatch). Nothing was installed."

ditto -x -k "$work/Mydroid-mac.zip" "$work/out"
app="$work/out/Mydroid.app"
[ -d "$app" ] || die "The download didn't contain Mydroid.app."
codesign --verify --deep --strict "$app" 2>/dev/null || die "The app's signature check failed. Nothing was installed."

if [ -n "${MYDROID_INSTALL_DIR:-}" ]; then dest="$MYDROID_INSTALL_DIR"; mkdir -p "$dest"
elif [ -w /Applications ]; then dest=/Applications
else dest="$HOME/Applications"; mkdir -p "$dest"; fi
[ -n "${MYDROID_INSTALL_DIR:-}" ] || quit_app
rm -rf "$dest/Mydroid.app"
ditto "$app" "$dest/Mydroid.app"
xattr -dr com.apple.quarantine "$dest/Mydroid.app" 2>/dev/null || true

say "Installed Mydroid in $dest."
[ -n "${MYDROID_INSTALL_DIR:-}" ] && exit 0
open "$dest/Mydroid.app"
say "Mydroid is open in your menu bar. Follow the setup window to pair your phone."
