---
title: Authenticator
description: Fill 2FA codes from your phone. The phone approves every fill.
---

Codes stay on your phone. Your Mac asks, you approve on the phone, and the code is filled in or typed for you.

## Add your accounts

In the Mydroid phone app, open **Authenticator** and add accounts. To move them from Google Authenticator, use **Settings → Authenticator → Add accounts** on your Mac: it scans the export QR with the Mac's camera, then sends the accounts to your phone.

## Fill in the browser

1. Open **Mydroid → Settings → Authenticator** on the Mac.
2. Choose **Set up…** next to Chrome, Edge, Brave, or Arc. Follow the steps to load the extension that comes with Mydroid.
3. Open a site that asks for a code. In the browser toolbar, open Mydroid and choose **Enable on this site**.
4. Click **Fill from phone** under the code field. Approve the request in Mydroid on Android.

The welcome page shows whether the browser, Mac, and phone can talk to each other. Use **Try a sample fill** to see what happens. If you want the button on every HTTPS site, choose **Enable on all sites** on the welcome page.

The extension can't see any page until you allow a site. It only looks for code fields. Turn access off any time on the extension's options page.

The setup sheet shows **Ready** when the extension and the app are connected.

If a site doesn't match any account, you choose one to link it. Lookalike sites such as `paypa1.com` get a warning first.

## Fill anywhere

Press **⌃⌥C** in any app. Mydroid reads the browser's address, asks your phone and types the code. The first time, macOS asks for Automation and Accessibility access.
