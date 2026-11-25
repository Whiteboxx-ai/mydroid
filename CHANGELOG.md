# Changelog

## 0.1.6 · 25 November 2026

- Now Playing clears when your phone has no media to show. You can resume a paused track from the Mac for up to a minute.
- The Mac shows a Battery Saver warning when your phone reports it is on. Notifications may arrive late, and your phone may disconnect.
- Click the Dock icon or choose **Open Main Window** in the menu bar panel. Closing the window keeps Mydroid running.
- Choose **Quit Mydroid** from the gear menu. To hide the Dock icon, turn off **Show Mydroid in the Dock** in **Settings → General**.

## 0.1.5 · 25 November 2026

### Android

- Mydroid checks the connection as soon as Android restores network access. If the phone has disconnected, Mydroid tries to reconnect.
- Check Android’s battery exemption separately from your phone’s background settings. Setup offers an optional **Allow while idle** step on OnePlus, OPPO, and realme. [Keep Mydroid connected](https://mydroid.whiteboxx.ai/help/keep-it-running/)
- Setup asks for call and text permissions only on devices that support those features. If you need to grant a permission in Android Settings, Mydroid can take you to App info.

### Mac

- Your Mac starts advertising over Bluetooth again after it wakes, so nearby phones can find it.
- Call Audio can reuse an existing wireless debugging connection after Mydroid verifies it belongs to your paired phone. [Set up Call Audio](https://mydroid.whiteboxx.ai/features/messages-and-calls/)
- The menu bar panel closes when you open the main window or Call Audio setup.
- WhatsApp notifications open the Mac app directly when it’s installed. If you use WhatsApp Web, Mydroid still opens the chat when it has the sender’s number.

## 0.1.4

- The Mac keeps the same Wi-Fi port when it wakes, so your phone can reconnect using the address it already knows.
- Android handles quick replies from the Mac when you browse or download shared files.

## 0.1.3

- Android keeps trying to reconnect when your Mac may still be reachable and retries sooner when the phone leaves Doze.
- Mydroid falls back to Wi-Fi reconnection if it can’t start Bluetooth presence scanning.
- Android Settings shows whether Mydroid is exempt from battery optimization. The help guide covers background settings by phone brand.
- Compatible with Mydroid for Mac 0.1.2.

## 0.1.2

- Install Mydroid Authenticator from the Chrome Web Store. Developer Mode is still available.
- Call Audio shows its pairing QR code as soon as setup opens.
- Mydroid on your Mac and phone reports Android background restrictions using the system’s background activity setting.
- Remote sends one Accessibility request when needed and gives System Settings time to handle it.
- WhatsApp opens directly when a notification doesn’t identify a contact number.
- Improved handling of masked app notifications and verification codes on Android.
- Mydroid now lives in the Whiteboxx GitHub organization.

## 0.1.1

- The Mac app offers Chrome Web Store and Developer Mode installs for Mydroid Authenticator.
- The signed Android download uses `com.whiteboxxai.mydroid`.

## 0.1.0

- Remote is rebuilt around four tabs: Pad (edge scroll, click buttons, three-finger swipes, typing view, settings), Present (deck picker, slide number and notes, laser), Playing (Music and Spotify with cover art and volume) and Open (apps and files on your Mac).
- The Mac's Now Playing card for your phone's music shows the cover and a time bar.
- New Dock icon and a teal brand across the Mac app, Android app, extension and site.
- The permission-waiting flow tells you what to do and offers a one-click reset.
- Send to Mac copies a shared file before the share screen closes.

- Added the public website, step-by-step install and build guides, and a new browser welcome page.
