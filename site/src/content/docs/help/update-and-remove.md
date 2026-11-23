---
title: Update and remove
description: Update Mydroid, or remove it completely.
---

## Update

- **Mac:** run the [install line](/get-started/install-mac/) again. It replaces the app and keeps your pairing.
- **Phone:** install the new `Mydroid.apk` over the old one.

Update both when a release says the protocol changed. Mydroid tells you which side is older.

## Remove from your Mac

```sh
curl -fsSL https://raw.githubusercontent.com/gautamm20/mydroid/main/install.sh | bash -s -- --uninstall
```

Add `--purge` to delete your pairing and settings too. Your photos and downloads stay where they are.

## Remove from your phone

Uninstall **Mydroid** in Settings → Apps. Then remove the phone from your Mac's Settings → Phone if you want a clean slate.
