# Mydroid Authenticator (browser extension)

Fills 2FA codes in Chrome, Edge, Brave and Arc from your Android phone. The phone holds the secrets and approves every fill;
this extension only finds the code field, asks, and types the code in. It needs **Mydroid for Mac** (`mac/`) and the Mydroid
Android app with accounts in its authenticator (`PROTOCOL.md` section 14).

Chrome MV3, plain JavaScript, no build step.

## Extension ID

The manifest carries a `key`, so the ID is the same on every machine and in every Chromium browser:

```
mgcbfndjnaceidpgamoffmgkljhlmheb
```

Mydroid's native messaging manifest allows exactly `chrome-extension://mgcbfndjnaceidpgamoffmgkljhlmheb/`. A Swift test
(`NativeMessagingFramingTests.testExtensionIDMatchesManifestKey`) checks that the ID in the Mac app is the one this `key` produces. Don't change the
`key` without changing `NativeMessaging.extensionID` in `mac/Sources/MydroidNM/NativeMessaging.swift`.

## Install (development, unpacked)

Mydroid for Mac does it with you. Open **Settings › Authenticator**, find your browser and press **Set up…**. A short sheet walks through it: it connects Mydroid to the browser, opens the browser's extensions page,
shows where **Developer mode** is, and gives you the extension folder as a tile to **drag onto the page** (or **Copy path** / **Show in Finder** if you'd rather use **Load unpacked**). When the extension starts it says
hello to Mydroid and the sheet turns to "Fill from phone is ready".

The extension is copied at every Mydroid launch to a stable folder: `~/Library/Application Support/Mydroid/Browser Extension/` (refreshed when the app carries a newer version). Load that folder, not the one inside the app.

By hand: build Mydroid (`mac/scripts/build-app.sh`), open it, run **Set up…** for the browser (it writes `com.mydroid.otp.json` into the browser's `NativeMessagingHosts` folder), then in `chrome://extensions` (`edge://`, `brave://`) turn on
**Developer mode**, choose **Load unpacked** and pick the stable folder. The toolbar popup should say **Connected**.

**For real users** the one-click path is publishing this extension to the **Chrome Web Store** (and **Edge Add-ons**): Chrome blocks self-hosted installs on macOS. The fixed ID below keeps the native messaging manifest valid
for a store build. Until that exists, the guided Load-unpacked flow is what we have.

## Website access

The manifest declares no website access, so installing the extension reads no pages. The first install opens `welcome.html` with an **Enable on all sites** button;
the toolbar popup offers **Enable on this site** and **All sites**, and the options page shows what is on and can turn it off. Each button calls
`chrome.permissions.request` straight from its click (`access.js`), as Chrome requires. The background worker watches `permissions.onAdded` and `onRemoved` and registers
the content script (`chrome.scripting.registerContentScripts`) for exactly the granted sites, then starts it in the tab the user is on. Until a site is allowed, the
**⌃⌥C** shortcut in Mydroid for Mac still fills codes anywhere.

## What you see

- On a page asking for a code (`autocomplete="one-time-code"`, OTP-named inputs, split digit boxes, or page text such as "enter the verification code"), a compact
  **Fill from phone** chip (an icon and a few words, like a native AutoFill chip) appears under the field. It is drawn in a closed shadow root, so the site can't style or script it, and follows `prefers-color-scheme`.
- Click it. The chip says **Approve on your phone…** with a spinner. Approve on the phone and the code is filled (a single box or each split box), with
  `keydown`/`beforeinput`/`input`/`keyup`/`change` events so React, Vue and Angular forms notice. It then says **Filled**.
- Other outcomes are one short label, with **Retry** where it helps: **Denied**, **Timed out**, **Phone locked**, **Phone not connected**, **Mydroid isn't running**, **Not set up here**. The longer explanation sits behind the small (i).
- **No account for this site**: press **Link…** and pick from your phone's list in a small popover under the chip. If the address looks like one of your sites (`paypa1.com`), the popover warns you and you must confirm **Link anyway**. Nothing is linked before that.
- **Several accounts match**: **Choose account** opens the same popover.
- After a fill, **Always fill here** turns on auto-fill for that site (no click needed; you still approve on your phone, unless auto-approve is on there).
  Manage the list in Mydroid › Settings › Authenticator › Fill automatically on, or per site in the extension popup.
- On startup and install the worker sends one `hello` (browser name and extension version, nothing else) so Mydroid's setup sheet can tell the extension is loaded.

The username you typed earlier in the same tab (a login or email field) is remembered in `chrome.storage.session` (memory only, cleared when the browser or tab closes)
and sent with the request so the phone can pick the right account.

## Security notes

- Secrets never reach the extension or the Mac. It receives one current code per approved request.
- The **site is decided by the background worker from the sending frame's own URL**, never from anything the page says. https only (plus `http://localhost`).
- Only a real user click (`event.isTrusted`) starts a fill from the chip. Page scripts can't click it.
- The native host refuses any caller whose origin isn't this extension, and the Mac app's socket (`~/Library/Application Support/Mydroid/otp.sock`) is mode 0600 and checks the peer's user ID.
- Codes, sites and accounts are never logged.

## Files

| file | what |
|---|---|
| `manifest.json` | MV3 manifest, with `key` |
| `detector.js` | pure code-field and username detection (runs in the page and under Node) |
| `content.js` | the chip (shadow DOM), fill logic, username memory |
| `background.js` | service worker: `chrome.runtime.connectNative('com.mydroid.otp')`, site check, per-tab username, the startup `hello` |
| `popup.html/js`, `options.html/js`, `ui.css` | toolbar popup (status, per-site auto-fill) and the options page |
| `test/detector.test.js`, `test/background.test.js` | detector tests, and the worker's hello against a fake `chrome`; no browser needed |
| `test/fixtures.html`, `test/e2e.mjs` | synthetic login pages, and a headless-browser run of the real content script |

## Tests

```sh
node test/background.test.js        # 5 checks: hello on install and on startup, nothing else in it, a missing host never throws
node test/access.test.js            # 6 checks: no up-front host access, the welcome page on first install, the script follows the granted sites
node test/detector.test.js          # 16 checks: single input, split boxes, a Salesforce-like page, non-OTP numeric fields that must not trigger
node test/e2e.mjs                   # needs Node 22+ and a Chromium browser; add --shots <dir> to save a PNG per chip state (light and dark)
```

`e2e.mjs` starts its **own headless browser with a throwaway profile**. It never touches your browsers, profiles or windows, and it replaces the
background worker with a scripted stub, so it needs neither Mydroid nor a phone. It clicks with real mouse events and checks the field values,
the events, the link flow and that script-made clicks are ignored. Open `test/fixtures.html` in a browser (`?page=single|split|salesforce|phone`) to look at it by hand.

Validate the manifest: `python3 -c "import json; json.load(open('manifest.json'))"`.

## Limits

- Safari and other browsers: use the **⌃⌥C** shortcut in Mydroid instead (it reads the front browser's address and types the code).
- Developer-mode loading shows Chrome's "disable developer mode extensions" notice on some setups. A Web Store (and Edge Add-ons) listing would remove the manual steps; the
  fixed ID keeps the native messaging manifest valid either way.
