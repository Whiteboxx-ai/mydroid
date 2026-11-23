#!/bin/bash
# Packs the browser extension for the Chrome Web Store: scripts/release/extension.sh <out.zip>
# The store assigns its own ID, so the manifest `key` (which pins the unpacked ID) is left out of the zip.
set -euo pipefail
OUT="$(cd "$(dirname "${1:?usage: extension.sh <out.zip>}")" && pwd)/$(basename "$1")"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rsync -a --exclude test --exclude README.md --exclude .DS_Store "$ROOT/extension/" "$tmp/"
python3 - "$tmp/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m.pop("key", None); json.dump(m, open(p, "w"), indent=2)
PY
rm -f "$OUT"; ( cd "$tmp" && zip -qr -X "$OUT" . )
echo "Wrote $OUT"
