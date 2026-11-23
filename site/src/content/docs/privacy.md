---
title: Privacy
description: What Mydroid reads, where it goes, and what stays put.
---

Mydroid has no accounts, no servers, no analytics and no crash reporting. Your phone sends things only to your paired Mac, over your local network, encrypted with a key made when you paired.

## What the phone can share

Each item below works only when you turn the feature on and give Android's permission.

| Feature | What it reads | Where it goes |
|---|---|---|
| Notifications | Notifications from your apps | Your Mac |
| Photos | Your camera roll | Your Mac's Pictures folder |
| Calls | Call state, numbers and contact names | Your Mac |
| Text messages | SMS and MMS, when your Mac asks | Your Mac |
| Clipboard | Text you copy | Your Mac. Off by default. Items marked private are skipped |
| Authenticator | Nothing leaves the phone except a code you approve | Your Mac, for that one fill |
| Bluetooth | Whether your Mac is near. No data. | Nowhere |

## What your Mac keeps

Your pairing key sits in the Mac's Keychain. Photos and downloads are ordinary files in Pictures and Downloads. A short history of app chats (up to 200 messages each) is kept in the app's folder so conversations make sense; one-time codes are never kept.

## Remove everything

Run the uninstall line in [Update and remove](/help/update-and-remove/) with `--purge`, and uninstall the phone app.

## Questions and reports

Security issues: see [SECURITY.md](https://github.com/gautamm20/mydroid/blob/main/SECURITY.md).
