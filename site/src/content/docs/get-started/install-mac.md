---
title: Install on your Mac
description: One line in Terminal installs Mydroid for Mac.
---

Needs macOS 14 or newer.

1. Open **Terminal** (press ⌘ Space, type `Terminal`, press Return).
2. Paste this line and press Return:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/gautamm20/mydroid/main/install.sh | bash
   ```

3. Mydroid opens in your menu bar. Follow the setup window, then [pair your phone](/get-started/pair/).

The script downloads the latest release, checks its checksum, installs it in Applications and opens it. [Read it first](https://github.com/gautamm20/mydroid/blob/main/install.sh) if you like.

## Install by hand

Download `Mydroid-mac.zip` from the [latest release](https://github.com/gautamm20/mydroid/releases/latest), unzip it and drag **Mydroid** to Applications. macOS then blocks the first open because the app isn't from the App Store:

1. Open Mydroid once and dismiss the warning.
2. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
3. Confirm with your password.

## Update or remove

See [Update and remove](/help/update-and-remove/).
