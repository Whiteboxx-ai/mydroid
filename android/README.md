# Mydroid for Android

Android half of Mydroid. Implements `protocol/PROTOCOL.md` v1; the phone is the client and always dials the Mac.

## Build

```
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties
./gradlew :protocol:test                 # crypto vectors, codec, transfer resume
./gradlew :simulator:test                # full 10-step smoke vs an in-test fake Mac
./gradlew :app:testDebugUnitTest         # Android unit tests and off-screen renders
./gradlew :simulator:installDist         # simulator/build/install/simulator/bin/simulator
./gradlew :app:assembleDebug             # app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
AGP 9.2.1 (9.3.1 needs Gradle 9.5; we are on 9.4.1), Kotlin 2.2.21, Compose BOM 2026.06.01.

After Gradle has downloaded the dependencies, add `--offline` to run the tests without network access.

Screenshot tests (Robolectric + Roborazzi, JVM only): `./gradlew :app:testDebugUnitTest` renders Home (including the Your Mac card), Settings, the text-send and Shortcuts sheets, Remote in each mode (and its "allow on your Mac" overlay) and the pairing Confirm screen (light/dark, 360 dp, 1.3x font) to `-Drender.dir=<dir>` (default in `app/build.gradle.kts`).

Interop: `simulator smoke --url <PAIR_URL> --state <dir> --photo <file> --photo2 <file>` prints `CONFIRM`, `STEP n ok`, then `SMOKE OK` (exit 0) or `SMOKE FAIL <reason>` (exit 1), 60 s limit.

## Layout

- `:protocol` pure JVM. `Crypto.kt` (HKDF on `javax.crypto.Mac`, AES-GCM), `Codec.kt` (framing, message codec), `Net.kt` (hello handshake, `SecureChannel`, QR URL parsing), `Session.kt` (`ClientSession` state machine, heartbeat, `CandidateRacer`, `Backoff`), `Transfer.kt` (send with resume, receive with `.part`, sha256, `Ledger`/`IncomingStore`/`FileSource` interfaces).
- `:simulator` smoke client using the same `:protocol` paths as the app, plus a fake-server test.
- `:app` (`com.whiteboxxai.mydroid`): `net/` (ConnectionManager, Discovery, foreground service), `notif/`, `photos/`, `calls/`, `clip/`, `files/` (incoming files, and the Mac's folders in the Files app), `find/`, `fix/`, `boot/`, `callaudio/` (setup status, keep-alive, `adb.verify`), `ui/` (Compose, Material 3, dynamic color). `com.mydroid.callbridge` is the shell-run call audio helper (below); its logic lives in `:protocol` (`CallAudio.kt`, `CallBridge.kt`).

## Permissions and why

| Permission | Why |
|---|---|
| INTERNET, ACCESS_NETWORK_STATE, ACCESS_WIFI_STATE, CHANGE_WIFI_MULTICAST_STATE | Talk to the Mac, react to network changes, Bonjour discovery (multicast lock held only while discovering) |
| CHANGE_NETWORK_STATE, FOREGROUND_SERVICE, FOREGROUND_SERVICE_CONNECTED_DEVICE | `connectedDevice` foreground service holding the connection |
| RECEIVE_BOOT_COMPLETED | Restart the service after boot and app update |
| POST_NOTIFICATIONS | Connection note, received files, fix prompts |
| USE_FULL_SCREEN_INTENT | Find-my-phone Stop screen |
| READ_MEDIA_IMAGES, READ_MEDIA_VISUAL_USER_SELECTED, READ_EXTERNAL_STORAGE (<=32), ACCESS_MEDIA_LOCATION | Camera roll sync and library browsing (7.7); original bytes with location |
| READ_PHONE_STATE, READ_CALL_LOG, ANSWER_PHONE_CALLS, READ_CONTACTS | Call state, caller number, answer/decline, contact name, and the call history list (7.8) |
| READ_SMS, SEND_SMS (+ READ_CONTACTS for names and photos) | "Text from your Mac" (PROTOCOL.md 7.5): list SMS/MMS conversations and messages, and send texts, only when the Mac asks and `settings.smsHistory` is on. Never writes to the SMS provider. Sideloaded builds on Android 13+ may need "Allow restricted settings" first |
| CALL_PHONE | "Call from your Mac" (7.8): `TelecomManager.placeCall` when the Mac sends `call.dial`. Audio stays on the phone |
| Notification access (special) | Mirror and reply to notifications |
| VIBRATE, MODIFY_AUDIO_SETTINGS | Find-my-phone |
| QUERY_ALL_PACKAGES (+ LAUNCHER `<queries>`) | Resolve real app names for mirrored notifications (Android 11+ package visibility). Sideload only; Play would need a declaration |
| BLUETOOTH_ADVERTISE (Android 12+, same "Nearby devices" group) | Walk-away lock only (section 12): advertise a beacon while connected. Asked in context from Settings or the Home banner, and only when the Mac turned the feature on |
| BLUETOOTH, BLUETOOTH_ADMIN (`maxSdkVersion=30`) | Android 10 and 11 only: the legacy pair that gates BLE advertising for the walk-away beacon (normal permissions, no prompt) |
| BLUETOOTH_SCAN (`neverForLocation`), BLUETOOTH_CONNECT (Android 12+, "Nearby devices") | Notice the Mac's Bluetooth LE advertisement (presence only, no data, never location) so the service runs only while the Mac is around |
| USE_BIOMETRIC (normal, no prompt) | Authenticator: ask for fingerprint, face or screen lock before codes show. The approval notification uses POST_NOTIFICATIONS |
| Companion device association (system dialog, one tap), REQUEST_COMPANION_RUN_IN_BACKGROUND, REQUEST_COMPANION_USE_DATA_IN_BACKGROUND, REQUEST_COMPANION_START_FOREGROUND_SERVICES_FROM_BACKGROUND | Background privileges that come with the association: start the service from a BLE wake-up, network in the background, open `link.open` links without a tap |
| WRITE_SECURE_SETTINGS (declared, never requested; only the Mac's `adb shell pm grant` can give it) | Optional Mac call audio: while it is enabled and granted, keep `Settings.Global adb_wifi_enabled` at 1 on boot and Wi-Fi connect. Nothing is ever written without both |
| Accessibility service (special, opt-in "Instant copy (advanced)", off by default, `clip/ClipAccessibilityService`) | Notice "Copy" taps so copied text reaches the Mac. Some banking/UPI apps warn while it is on. Sideloaded builds need "Allow restricted settings" first |

## Real vs not yet

Real and exercised: the whole protocol layer including resume and dedupe (JVM tests, fake-server smoke), app builds, installs and launches on an API 34 emulator, Welcome screen and deep-link failure path verified visually.

Written but NOT exercised on a real device (no device, no Mac): QR scanning (needs Google Play services), notification mirroring and replies, photo sync, call monitoring and control, Quick Settings tile, share target, find-my-phone, OEM battery screens, NSD discovery. The OEM component names come from public lists and may drift between ROM versions.

Known limits, candidly:
- Call audio stays on the phone unless the user opts into "Hear calls on your Mac" (set up from the Mac, below). Without it the Mac can answer, decline, end and mute, but not carry the audio.
- Caller number on Android 10+ arrives via the `PHONE_STATE` broadcast and needs READ_CALL_LOG; `ringing` is delayed ~400 ms to pick it up.
- Clipboard phone to Mac is tiered (below): select text then Send to Mac, the notification button, tile and share target need no permission; instant copy via accessibility is an opt-in. Mac to phone is automatic.
- Partial photo access (Android 14+) works but only already-selected photos are visible; the UI offers "Allow all".
- Sideloaded builds on Android 13+ need "Allow restricted settings" before notification access can be enabled (the app says so).
- FGS start from a cold boot can be refused by the OS; the notification listener rebind is the backstop.
- Photos: only `DCIM/` and `Pictures/Screenshot*` images added after pairing (finished files only, `IS_PENDING=0`); photo `xid` uses `DATE_MODIFIED`, so an edited photo re-uploads.

## Authenticator: 2FA codes (PROTOCOL.md 14)

An offline authenticator that lives on the phone. The Mac gets one code at a time, after approval, never a secret. Code: `app/.../auth/`, UI in `ui/Authenticator.kt`, pure logic in `:protocol/auth/` (JVM-tested).

**What it does.** Home, Your Mac card, Authenticator row: accounts with initials, live code and countdown ring. Tap copies (marked `IS_SENSITIVE`, wiped after 30 s unless something else was copied since). Long-press edits issuer, account, linked websites, delete (with confirmation). Add by scanning an `otpauth://` QR (shown on a computer screen), a Google Authenticator export (`otpauth-migration://`, multi-QR exports show "2 of 3 scanned") from another device's screen, by importing through the Mac's camera (below), or by hand (secret, issuer, account, advanced: SHA1/256/512, 6-8 digits, period, HOTP counter). Websites are pre-filled from a built-in issuer map (about 70 services, fuzzy and case-insensitive) and taught by the Mac (`auth.domain.set`).

**Security model.**
- Secrets never leave the phone, except inside a backup file the user seals with a passphrase. The Mac only ever receives `auth.list` metadata (id, issuer, account, domains, digits) and a single approved code.
- Vault at rest: JSON sealed with AES-256-GCM using a non-exportable Android Keystore key (`mydroid_auth_vault`, StrongBox when the phone has it, else TEE), one file in app storage, `allowBackup=false`. The key needs no user auth so an approved request still works while the phone is locked; the biometric gate protects the list on screen, not the file. If Android loses the key the vault reads as "unreadable" (Mac gets `locked`) and the app offers a backup restore. Not synced anywhere.
- Never logged: secrets, codes, issuers, accounts, domains. Logs (`MydroidAuth`) carry counts and outcomes. The Activity list keeps "Code sent to <Mac> for <issuer>" (issuer name only) in the app's private `activity.json`.
- `FLAG_SECURE` is on while the Authenticator is open (so no screenshots and a blank Recents card); the passphrase dialogs set it too.
- Biometric gate (Settings, on by default): platform `BiometricPrompt`, biometric or screen lock, asked again after 60 s in the background. A phone with no screen lock can't be gated; Settings says so.
- Mac requests (`auth.code.get`): match domain (subdomains allowed, `evilsalesforce.com` does not match `salesforce.com`) narrowed by `account`; several matches reply `ambiguous` with choices, none `no_match`. Then approval:
  - Default: high-priority notification on its own channel, "Fill code for <issuer> (<account>) on <Mac>?", Approve (needs the device unlocked, `setAuthenticationRequired`, Android 12+) and Deny, 30 s timeout. The lock-screen version shows no account. Never contains the code. On Android 10 and 11 there is no per-action unlock, so Approve is ignored while the device is locked.
  - Optional "Approve automatically" (off by default, 1 to 30 min): only when the device is unlocked and was unlocked within N minutes **and** BLE presence says the Mac is here ("Your Mac nearby" must be set up). Never while locked. Otherwise it asks.
  - If notifications are blocked the request is answered `denied` at once rather than timing out; at most 3 pending.
  - If under 5 s remain in the period, the next period's code is sent.
- Backup: JSON vault, scrypt (N=2^15, r=8, p=1, own implementation, checked against RFC 7914), AES-256-GCM, header (magic, version, KDF params, salt, IV) is the AAD. SAF `CreateDocument`/`OpenDocument`. A wrong passphrase and a tampered file look the same. The file asks for at most ~64 MiB of scrypt memory. A one-time nudge appears when there is an account and no backup.
- Delete all (Settings) needs two confirmations and removes the file and the Keystore key.

**Google Authenticator import guidance.** Google Authenticator's export screen blocks screen capture, so this phone can't scan its own export. The empty state and the Add sheet (`ImportPaths` in `ui/Authenticator.kt`) say so and offer two ways: (1) "Use your Mac's camera" (Mac Settings › Authenticator › Import with this Mac's camera, then hold the export code to the Mac), (2) "Scan from another device's screen" (in-app scan of the export shown on another phone or tablet). The plain "Scan QR code" row stays for `otpauth://` setup codes on a computer screen.

**Import through the Mac's camera** (PROTOCOL.md 14.4, `auth/AuthImporter.kt`, `auth/AuthImportSurface.kt`, `ui/AuthImportReview.kt`, parsing in `:protocol` `auth/AuthImport.kt`). The Mac sends `auth.import {req, uris}`:
- All URIs are parsed (`otpauth://` and `otpauth-migration://`, several batches). Duplicates are skipped by secret (the vault's own rule, so a shown count is what gets added), including repeats inside the batch. Limits: 64 URIs, 20 000 chars each, 500 accounts.
- If nothing parses, the reply is `invalid`. If everything is already here, it replies `ok, added 0, skipped N` without asking. If the vault is unreadable: `locked`.
- Otherwise a high-priority notification on the code-request channel (heads-up, full-screen intent; the app is also opened directly when it is in front) says "<Mac> wants to add N accounts" and opens `AuthImportActivity`, which lists issuer and account (never secrets), with Add and Cancel. The window is `FLAG_SECURE`; it is not shown over the lock screen, so the device must be unlocked to review. The lock-screen notification says only "Account import from your Mac".
- **Add** always asks the biometric or screen lock afresh (`AuthGate.prompt(unlockGate=false)`, so it doesn't also open the Authenticator list). A phone with no screen lock has nothing to ask. Backing out of the prompt leaves the review open; a biometric lockout ends the import with `locked`. After Add the reply is `auth.import.result {ok:true, added, skipped}`, the Activity list gets "Added N accounts from <Mac>" (a count, no names), and when no backup exists the Done screen and the Authenticator list nudge a backup.
- **Cancel**, the notification's Cancel, a 2 minute timeout, a second import while one is open, or notifications being blocked reply `cancelled`. A lost connection drops the import without a reply.
- The parsed secrets live only in `AuthImporter` (memory) until Add or Cancel, then the references are dropped (a Kotlin `String` can't be zeroed). Nothing is written before Add. Nothing logs a URI, secret, issuer or account (`MydroidAuth` logs counts).
- Tests: `:protocol` `auth/AuthImportTest` (parsing, dedupe, limits, wire, cleaned display text), `:app` `AuthImporterTest` (Robolectric; review/Add/Cancel/timeout/invalid/locked/busy/disconnect/write failure, and that no log line contains a secret or name). Renders: `auth-import-review*`, `auth-import-done*`, `auth-import-notification`, `auth-add-sheet-import`, `auth-empty`. Not tried against a real Google export, by design.

Limits: the 30 s clipboard wipe needs the process alive (it is while paired, via the connection service) and skips the wipe if another clip arrived. Steam Guard and other non-RFC schemes are not supported. Not exercised with real accounts, by design; verified with JVM tests, fakes and renders.

Tests: `:protocol` `auth/OtpTest` (RFC 6238 Appendix B for SHA1/256/512, RFC 4226 Appendix D, RFC 4648, RFC 7914) and `auth/OtpAuthTest` (URIs, migration payloads built by a test encoder, multi-part batches, issuer map, matching, wire messages, approval policy, backup round-trip and failures). Renders: `AuthScreenshotTest` writes `auth-*.png` (list, 4 s left, locked, empty, add sheet, manual entry, import progress, backup passphrase, restore, approval notification mock, Home row, Settings).

## Notifications: names, messages, OTPs

- App names: `appLabel()` needs package visibility, so the manifest has a `MAIN/LAUNCHER` `<queries>` intent and `QUERY_ALL_PACKAGES`. Verified on the phone with a real third-party package (label, not package id).
- `category:"message"` for `MessagingStyle`, `CATEGORY_MESSAGE` and the default SMS app; `conversation` carries the last 5 messages, group flag, title and a <=128 px avatar (group/large icon or last sender's person icon). Avatars are cached per package + conversation, app icons per package.
- OTPs: `protocol/OtpParser.kt` (JVM-tested, ~60 cases incl. Indian bank formats and negatives for amounts, dates, phones, order numbers, `a/c XX1234`). `G-482196` yields `482196` (single-letter prefix dropped).
- Android 15+ can redact notifications containing codes. After the user approves the companion association, Mydroid rebinds its already-enabled notification listener so Android can reevaluate access. If a notification still arrives redacted, its code stays hidden. The `RECEIVE_SMS` receiver can recover codes for the default SMS app or send a separate SMS notification, with the user's SMS permission.

## Opening notifications from the Mac (PROTOCOL.md 13)

**Extra fields on `notif.posted` and snapshot items** (`NotifBridge.describe`; the pure logic is in `:protocol/NotifFields.kt`, JVM-tested):
- `person {name, phone?}`: `NotifPeople`. Source is the last incoming `MessagingStyle` message's `Person`, else a single-entry `EXTRA_PEOPLE_LIST`, else (message notifications) the title. `phone` is only ever set when sure: a `tel:` `Person.uri`, or a contact found by `mailto:`, contact URI, `Person.key` or exact display name that is exactly one contact with exactly one number. Normalised to E.164 by `PhoneE164` (a small region table: calling code, trunk prefix and national length, instead of libphonenumber). National numbers need the phone's network country (SIM country when there's no network; **no answer while roaming**, when the two differ). Group chats get a name but never a phone, so a group link can't become a DM. Lookups are cached 10 min, hits and misses.
- `links`: `NotifLinks` finds `http(s)://` and `www.` URLs in the text, big text, the last 5 messages (newest first) and the title: deduplicated, at most 3, trailing punctuation and unbalanced brackets trimmed, credentials and over-2048-char URLs dropped. A custom regex rather than `Patterns.WEB_URL` so it is unit-testable and doesn't match bare domains or file names.
- `media {title, artist, album?, mediaId?}`: from the `MediaSession` token in `EXTRA_MEDIA_SESSION`. `mediaId` is `METADATA_KEY_MEDIA_ID`, else `METADATA_KEY_MEDIA_URI`, and only if it matches `spotify:track:<22 base62>`, `spotify:episode:<22 base62>` or is an http(s) URL. **Limit:** media-session and ongoing notifications are still not mirrored (existing rule), so today `media` appears only if that rule is relaxed. The id in `media.state` is separate (next section).
- Nothing logs text, names, numbers or links.

**The Spotify check** (`notif/MediaIdProbe.kt`). Does Spotify's session expose a track id? Whenever `com.spotify.music` posts or updates a media notification, or its session's metadata changes (its own session listener, independent of the Now playing setting), one line goes to logcat under tag `Mydroid`:
`spotify-mediaid present=<bool> scheme=<spotify:track|spotify:episode|http|other|none> field=<MEDIA_ID|MEDIA_URI|none>`
`present` means an id the Mac may use. `scheme`/`field` describe what Spotify gave even when it isn't usable (`present=false scheme=other` means an id exists but not in a public form). Never the id, title or artist. To run it: play a song in Spotify and `adb logcat -s Mydroid`. Debug builds: `am broadcast -n com.whiteboxxai.mydroid/com.mydroid.android.debug.DebugReceiver -a com.mydroid.android.debug.SPOTIFY_CHECK` probes the live Spotify session now and logs the last result.

**`notif.open {key}`** (`NotifBridge.open`, `NotifOpener`, on the notification worker). Sends the active notification's `contentIntent` with the `ActivityOptions` background-start mode `ALLOWED` on Android 14+ (the companion association is what permits it). The `PendingIntent.OnFinished` result tells a started activity (0..3) from an aborted or failed one; no verdict in 4 s counts as sent. On `CanceledException` or a refused start it posts a high-priority "Tap to open in <App>" (channel *Opening from your Mac*) carrying the same `PendingIntent`, removed after 2 minutes, and replies `ok:false`. If the notification is gone it launches the app (`getLaunchIntentForPackage`) and replies `ok:true, note:"launched app"`. A notification with no `contentIntent` takes the same launch path. Reply: `notif.result {key, ok, error?, note?}`. Logs the outcome only (`notif.open ok= via= why= code=`).
- Debug builds: `DebugReceiver` actions `NOTIF_OPEN` (`--es key <sbn key>` or `--es tag <t> [--es pkg <p>]`) and `NOTIF_OPEN_TEST [--ez cancel true]`, which posts Mydroid's own test notification (tap target `OpenTestActivity`, or a cancelled PendingIntent to exercise the fallback) and runs the same handler. Results go to `MydroidDebug`/`MydroidNotif` logs.

## Clipboard (phone to Mac)

**Why it is tiered.** Android 10+ lets only the focused app or the default keyboard read the clipboard, so there is no permission-free *automatic* path. The one automatic path (an accessibility service) makes some UPI and banking apps, Paytm among them, show a security warning or refuse to run on a phone with a sideloaded app's accessibility service enabled. KDE Connect hit the same wall and settled on a notification button. So the default has no accessibility service and no Developer options, and the automatic path is an explicit opt-in.

| Tier | How | Needs |
|---|---|---|
| 1. Select text | Select text, tap **Send to Mac** in the selection toolbar (beside Copy and Share). `clip/ProcessTextActivity` (`ACTION_PROCESS_TEXT`, `text/plain`). A single http/https/mailto URL becomes `link.open`, anything else `clip.set`. Explicit, so it works even while the Mac has clipboard sharing off. No UI: a toast ("Sent to <Mac>", or "Your Mac isn't connected. It'll send when it's back.", with a 1-item queue that goes out on reconnect, dropped after 10 min). Editable fields get their own text back unchanged. Logs only the length. | nothing |
| 2. Already copied | **Send clipboard** button on the ongoing connection notification (shown while connected and the Mac has clipboard on), the Quick Settings tile, and the Home button. All open the transparent `ClipSendActivity`, which reads the clipboard once it has window focus (the only moment Android allows it), sends, and finishes. The Share sheet's **Send to Mac** is the same idea for apps with a Share button. | nothing |
| 3. Instant copy (advanced) | Home, Clipboard row: the **Instant copy (advanced)** switch. It first shows: "Instant copy uses Android's accessibility permission to notice when you tap Copy. Some banking and UPI apps (like Paytm) show a security warning while it's on. You can turn it off anytime." then opens Accessibility settings. Off by default and removed from the Permissions onboarding. | accessibility service |

Clips flagged `IS_SENSITIVE` (password managers) are never sent by any tier, and non-text clips are skipped.

**Opt-in is stored** (`Store.instantCopy`) and `ClipAccessibilityService` does nothing unless it is true: the service's event mask is set to 0 and `onAccessibilityEvent` returns first thing unless clipboard sharing is on, the Mac is connected, the user opted in and the service is enabled. The app never turns the service on or off itself. If it is enabled in Android settings while the user is opted out (for example from an older build), Home shows "Instant copy is on in Accessibility settings. Turn it off there if a banking app complains." with an Open settings button.

**`feature.status`.** `clipboard` is `"on"` whenever the Mac enabled it, whatever the accessibility state, never `needs_permission`. New optional field `clipboardMode`: `"instant"` (opted in and the service is enabled) or `"tap"`.

### Instant copy: how it works

`ClipAccessibilityService`:

1. Signals: click/long-click on a view whose text or contentDescription is Copy / Copy link / Copy text / Copy code / Copied (<= 28 chars), a "Copied" toast, or a systemui clipboard window naming the clipboard.
2. After 250 ms it adds a 1x1 transparent `TYPE_ACCESSIBILITY_OVERLAY` window (no overlay permission needed) that is focusable but `FLAG_ALT_FOCUSABLE_IM` and not touchable, reads `primaryClip` in its focus callback, and removes it on the next loop turn.
3. `ConnectionManager.onClipboardObserved` sends `clip.set` only if clipboard is on, the Mac is connected and the text differs from the last text synced either way (so Mac writes don't echo). Logs only lengths.
- Config is minimal: four event types, `notificationTimeout=100`, no `canRetrieveWindowContent` (events already carry the label text; we never read screen content).
- Typing focus: with the keyboard up and the overlay read, the debug test (`ClipTestActivity --ez auto true`) logged `ime before=true`, `ime after=true`, window focus returned. `ALT_FOCUSABLE_IM` is why. Not verified visually (no screenshots on the user's phone).
- Limits: (a) the Android 12+ "pasted from clipboard" toast for a clip written by another app can't be suppressed; it appears per read. (b) The Android 13+ clipboard preview reports a bare `FrameLayout` from systemui with no clipboard marker, so it is not used as a signal; copy buttons, selection-toolbar "Copy" and toasts are. Keyboard shortcut copies (Ctrl+C) and apps with icon-only copy buttons are missed; tiers 1 and 2 cover them. (c) `primaryClipDescription` is only readable with focus, so a repeated signal for an unchanged clip costs one overlay flash (rate limited to 1 per 1.2 s, then dropped by the text compare).
- Enabling: Home switch, then Accessibility settings. Sideloaded builds: app info, menu, "Allow restricted settings" first.

## Battery

Audit of the original code and what changed:

| Finding | Change |
|---|---|
| Discovery (NSD + MulticastLock) ran for the whole 15 s dial window every attempt, forever | Known addresses (last good, QR) are dialled first for 2.5 s; Bonjour starts only if they fail, and the whole attempt is capped at 10 s. Wi-Fi multicast acquire count moved +2 across ~8 reconnects during testing |
| Retry loop never stopped (1..30 s backoff forever, including on cellular) | 5 attempts (1,2,4,8 s backoff), then the supervisor parks with no timer until: network change to Wi-Fi/ethernet, `SCREEN_ON`/`USER_PRESENT`, app open, or the photo worker. No dialling and no discovery without a Wi-Fi/ethernet default network. Unpaired state also waits with no 60 s tick |
| Ping 20 s, 60 s idle drop | 25 s screen on / 90 s screen off, 240 s idle drop, TCP keepalive (idle 120 s, interval 30 s, 4 probes) via `Handshake.connect(tuneSocket)`. Screen-on pings immediately to detect a dead link |
| WorkManager catch-up every 15 min, any network | Every 6 h (flex 1 h), unmetered + battery-not-low, replaced via `UPDATE` |
| Notification work on the main thread, re-encoding icons | Per-key 300 ms debounce on a background thread; icon, label, avatar caches; unchanged payloads dropped by hash |
| `Thread.sleep(500)` parked the photo uploader thread | Handler delay |
| Home screen 30 s ticker ran while stopped | `repeatOnLifecycle(STARTED)` |
| Accessibility events while feature unused | Event mask set to 0 unless instant copy is opted in, clipboard is on and the Mac is connected |

Already fine: no wake locks anywhere (`dumpsys power` shows none held, only WorkManager's short job lock), no AlarmManager use (`dumpsys alarm`: none), `collectBlocking` is a parked suspending collect, battery status already only on >=1%/charging/network change, the legacy NSD resolve loop (API < 34 only) polls inside the 10 s window.

Measured on the CPH2691 (Android 16): after the change `dumpsys power` shows 0 Mydroid wake locks held, `dumpsys jobscheduler` shows one job (`CONNECTIVITY`, `NOT_METERED`, `BATTERY_NOT_LOW`, ~6 h), `dumpsys alarm` has no Mydroid alarms. A before/after `batterystats` energy comparison wasn't possible: the history is hours of mixed use and an A/B needs an overnight unplugged run. The dormant state itself was verified by code, not by cutting Wi-Fi (that would drop the adb link).

### Bluetooth presence (PROTOCOL.md 7.1)

The big battery and reliability win: the connection service no longer runs all day. Code: `presence/` (association, scan, receiver), `:protocol/Presence.kt` (UUID derivation, `PresenceMachine`, JVM-tested), wiring in `ConnectionManager`.

- **UUID**: `HKDF(LTK, "mydroid v1 ble uuid")`, RFC 4122 v4 bits; checked against the `bleUuid` test vector.
- **Setup**: Permissions step and Home "Fix" row "Find your Mac nearby" ask for Nearby devices, then show Android's companion dialog (`BluetoothLeDeviceFilter` on the UUID). The Mac must be awake and advertising when the user taps. Android 12+ only; older phones, no permission or no association keep the old always-on behaviour. Unpairing removes the association and the scan.
- **Presence scan**: one hardware-filtered `SCAN_MODE_LOW_POWER` scan delivered to `PresenceReceiver` by `PendingIntent`, `FIRST_MATCH | MATCH_LOST` (falls back to `ALL_MATCHES` plus a 90 s silence timer if the chip refuses). Re-registered on app start, boot, app update (`BootReceiver`) and Bluetooth turning on. Verified in `dumpsys bluetooth_manager`: PI scan, `LOW_POWER`, `[FIRST_MATCH | LOST]`, service-UUID filter, hardware ("Back") filtering. Bluetooth off counts as presence off (always-on behaviour).
- **Lifecycle**: Mac found: service up, connect now. Mac lost and no TCP session for 2 min: `ConnectionService` stops, the supervisor sleeps with no timer, no retries, no NSD. Back on when the Mac is found, a Wi-Fi network appears, the phone is unlocked or the app opens (each gives another 2 min window). Connected means never parked.
- **Association privileges**: background service start, background data, and `link.open` straight to the browser (screen on and unlocked; otherwise a "Link from your Mac" notification).
- **Caveat**: a Mac advertises with a rotating private BLE address, so the association's stored MAC goes stale. We never use it (our own UUID scan does the detecting); it only carries the privileges.
- **One approval:** Android 13 and later use the watch profile for the companion association. The same association supports nearby detection and can let the notification listener see codes that Android would otherwise hide. Mydroid refreshes the listener after the association is created.
- **Debug builds only**: `DebugReceiver` (mute list, a synthetic silent media session, media on/off, remove shell test notifications) for testing without the Mac.

## v1.2 features (PROTOCOL.md 7.2, 7.3, 7.4, 7.9)

- Settings v2 are stored in `Settings`: `mutedApps` (filtered in `NotifBridge`, already-mirrored ones get `notif.removed`; the mute check also covers snapshots and the synthetic SMS-OTP notification), `screenshots` (photo scan skips `Screenshot*`), `pauseBelowBattery` (photo drain pauses below the level unless charging, resumes on the next battery change), `smsHistory` (stored only), `media`. Clips flagged `IS_SENSITIVE` (both the SDK constant and the literal key) are never sent, from every path.
- Now playing: `media/MediaBridge` (needs notification access): all active sessions watched, playing first then paused; `MediaTracker` sends on change only, position-only changes only when they look like a seek, art (JPEG <= 256 px) once per track. `media.cmd` goes to `transportControls` (`MediaAction` in `:protocol`; `pause` always pauses, `toggle` follows the playing state).
- **`mediaId` in `media.state`** (PROTOCOL.md 15, Continue on Mac): `MediaBridge` fills `MediaSnapshot.mediaId` from `MediaIds.pick(METADATA_KEY_MEDIA_ID, METADATA_KEY_MEDIA_URI)` and `toMessage` re-filters, so only `spotify:track:<22 base62>`, `spotify:episode:<22 base62>` or http(s) is ever sent (the filter's id length was tightened from 10-40 to exactly 22, which also applies to `notif.posted.media`). It is part of the track key, so a new id counts as a track change and is sent; it rides on every active `media.state` so a pause update doesn't drop it. Logs say only `id=true/false`, never the id. Tests in `PresenceTest` and `MediaIdsTest`.
- Links: the share target sends a single http/https/mailto URL as `link.open`; incoming `link.open` is opened or offered via `link/LinkOpener` (any other scheme is refused).
- `device.status.lowPowerMode` follows battery saver and is re-sent on `ACTION_POWER_SAVE_MODE_CHANGED`.

## v1.3 features (PROTOCOL.md 7.5 to 7.8)

All four are request/response: the Mac asks, a worker thread answers. `net/RequestRouter` receives `sms.*`, `photos.*`, `calls.list` and `call.dial` from the socket reader and hands each to a worker (query, send, thumbnails and downloads have separate single-thread pools that hold no thread while idle), so a slow provider query never blocks the reader or heartbeat. `notif.read` runs on the notification worker. Logs carry counts, byte sizes and timings only.

- **SMS (7.5)** `sms/SmsRepository` (read-only: `Telephony.Threads` with `simple=true`, `Telephony.Sms`, `Telephony.Mms`, `canonical-addresses`), `sms/SmsBridge`, `contacts/ContactLookup` (`PhoneLookup`, 10-minute cache, <=128 px PNG avatars).
  - `sms.threads`: newest first, `before` pages by thread date, unread counted from `read=0` received rows. `sms.messages`: SMS and MMS merged, oldest first, `before` pages by `date < before` (MMS seconds are converted). A page never splits a run of equal timestamps, so paging by `before` can't skip messages.
  - Message `id` is the SMS `_id`, or the **negated MMS `_id`** (the two tables number rows independently). `from` is the sender for received messages and `""` for sent ones. MMS body is its text part, else `[Photo]`, `[Video]`, `[Audio]` or `[Attachment]`; `mms:true`.
  - Frames stay under 1 MiB (`FrameBudget`): too many contact photos are shed from the oldest threads first, then trailing threads/oldest messages are dropped and the Mac pages on.
  - `sms.send`: `SmsManager.sendMultipartTextMessage` per recipient (the system sends one text each), explicit immutable sentIntents to `SmsSentReceiver`, one `sms.sent` when the last part reports (first error wins, 90 s timeout). We do not insert a sent row: since Android 4.4 the platform records texts sent by a non-default app through `SmsManager` itself, so inserting would duplicate it. This is the documented platform behaviour; it was not exercised on the real phone (nothing may be sent there).
  - `sms.changed`: a `ContentObserver` on `content://mms-sms/` (registered only while connected, enabled and permitted) diffs a cheap snapshot of the thread table and announces each changed or deleted thread at most once per second.
  - `sms.error` `{error:"permission"}` when `settings.smsHistory` is off or READ_SMS/SEND_SMS is missing (`"failed"` for an unexpected provider error; `req` names the request). `feature.status.sms` is `on` / `needs_permission` / `off`.
- **Read sync (7.6)** `notif.posted.markRead` is true for `SEMANTIC_ACTION_MARK_AS_READ` or a "Mark as read" title (case-insensitive, ~30 localized variants). `notif.read {key}` fires that PendingIntent (never an activity PendingIntent, so no UI), else cancels; if the notification is still up 2 s after a fired action it is cancelled too. `notif.removed` follows as usual.
- **Photo library (7.7)** `photos/PhotoLibrary`. `photos.list`: DATE_TAKEN, falling back to DATE_ADDED (two queries merged, since one provider sort can't do both), `IS_PENDING=0`, albums `camera` (`DCIM/Camera`), `screenshots`, `all`; item `album` is `camera`, `screenshots` or `other`; w/h follow EXIF orientation. `photos.thumbs.get` (<=30): `ContentResolver.loadThumbnail`, JPEG q80, long edge <= 256 px, one `photos.thumb` per id (header `id`, JPEG payload; `ok:false` and no payload if it can't be made), cached in memory (6 MB). `photos.get`: `xfer.offer kind:"photo" xid:"lib:<id>"` through the existing `TransferEngine` (`setRequireOriginal` when permitted); not in the auto-sync queue or ledger. `xfer.cancel` is sent if the photo is gone. Needs photo access, not `settings.photos`; `photos.page` carries `error:"permission"` and no items without it.
- **Calls (7.8)** `calls/CallHistory`. `calls.list`: `CallLog.Calls`, type mapped (voicemail and answered-elsewhere are `in`, blocked is `rejected`), name from `CACHED_NAME`, else contacts, else the formatted number. Without READ_CALL_LOG, `calls.page` is empty with `error:"permission"`. `call.dial`: `TelecomManager.placeCall` with CALL_PHONE. Only digits and a leading `+` are accepted (no `*` or `#`, so no USSD codes); without permission it posts a "Call from your Mac" notification that opens the permission prompt.
- **Setup UI** new Permissions steps and Home rows: "Text from your Mac" (reuses the Allow-restricted-settings note) and "Call from your Mac". The "Camera roll" step now mentions browsing.
- **Debug only:** `DebugReceiver ... -a com.mydroid.android.debug.LIB_TEST` runs the same handlers locally and logs counts, sizes and timings (`adb logcat -s MydroidDebug`). It never runs `sms.send`, `call.dial` or `photos.get`.

## Your Mac in Files (PROTOCOL.md section 9)

The Mac's shared folders show up in Android's own Files app and in every system file picker, as one root named after the Mac ("via Mydroid", laptop icon). Code: `:protocol/Fs.kt` (codec, request client, browser cache, file cache, JVM-tested in `FsTest.kt`), `files/MacFiles.kt` (service owned by `ConnectionManager`), `files/MacDocumentsProvider.kt` (thin `DocumentsProvider`, authority `com.whiteboxxai.mydroid.macfiles`, permission `MANAGE_DOCUMENTS`, so only the system can bind it).

- **Roots.** One row while paired: flags `SUPPORTS_SEARCH | SUPPORTS_RECENTS | SUPPORTS_IS_CHILD`, plus `SUPPORTS_CREATE` when any share is writable (last answer kept in `Store.fsWritable`, so the flags don't flicker offline). The root is **not** hidden when the Mac is away, only when the Mac answered `fs.roots` with an empty list (sharing off). `notifyChange` on the roots URI fires on connect, disconnect, unpair and every `fs.roots` answer.
- **Document ids** (`FsDocId`): `<macId>` is the root, `<macId>:<share>` a shared folder, `<macId>:<share>/a/b` anything inside. `/` and `%` in a share id are escaped; ids with empty, `.` or `..` segments are refused.
- **Children, the async pattern.** `queryChildDocuments` returns at once with the cached rows (none the first time) and `EXTRA_LOADING`, starts one `fs.list` per folder (single-flight), and when the answer lands `notifyChange`s the children URI; the next query has the rows. Listings are fresh for 20 s, then served stale while refreshing. A failure shows `EXTRA_ERROR` for 5 s (no retry storm): `not_found` "That isn't on your Mac anymore.", `denied` "Your Mac didn't allow that.", `off` "File sharing is off on your Mac.", timeout "Your Mac didn't answer. Try again in a moment.".
- **Mac not connected.** An empty cursor with `EXTRA_ERROR` "Your Mac is asleep or out of range. It'll show up when it's back." and no request. The root stays; the folders come back with a `notifyChange` when the session is ready.
- **Thumbnails.** Only for image, video and PDF rows (`FLAG_SUPPORTS_THUMBNAIL`), via `fs.thumb`, at most 3 in flight, cached as JPEG in `cache/macfiles/thumbs` (keyed by path and mtime, 64 MB LRU, failures remembered for 10 min).
- **Opening.** `openDocument` read: `fs.get`, then the Mac offers `xfer.offer xid "fs:<req>"` and the normal `TransferEngine` receives it. `FsStore`/`FsLedger` route `fs:` xids into the provider cache (`cache/macfiles/files`) instead of `Download/Mydroid`, never record them in the ledger, and answer `xfer.skip` to an `fs:` offer nobody asked for. The call blocks the binder thread, honours the `CancellationSignal` (sends `xfer.cancel`, closes the receive), waits 30 s for the first byte and then 45 s of no progress, 30 min overall. Transfers over 1 MiB show one quiet progress notification (channel "Files from your Mac"), updated at most every 0.8 s. Size and sha256 are checked by the engine. Concurrent opens of one file share one download.
- **File cache.** Up to 1 GB, least recently used first. A copy is reused only while the Mac still reports the same size and mtime; offline, an older copy is served rather than failing.
- **Saving.** `createDocument` (needs a writable share; folders aren't supported, the protocol has no mkdir) makes a placeholder row with `FLAG_SUPPORTS_WRITE`. The app writes into a temp file; closing the descriptor triggers `fs.put`, then `fs.put.ready`, then `xfer.offer xid "fsput:<req>"` through the same engine, then the folder is re-listed and the placeholder dropped. The Mac adds ` (2)` if the name is taken. Existing files can't be edited in place (the protocol has no overwrite), so they get no write flag. A failed save posts a notification.
- **Search and recents.** `querySearchDocuments` (`fs.search`, up to 50) and `queryRecentDocuments` (`fs.recent`, up to 30), same loading/notify pattern. Result `path` is read as the item's full path inside its root; if a peer sends the parent folder instead, the name is appended.
- **Threads.** Provider calls arrive on binder threads. Replies to the phone's own `fs.*` requests go through `RequestRouter` (its own worker), so the socket reader only parses frames. Large payloads (thumbnails, lists) are never handled on the main thread. Logs (`MydroidFs`) carry counts, sizes and timings only.
- **Home.** A quiet row "Your Mac in Files: Open the Files app and look for <Mac name>" with an **Open** button: `ACTION_VIEW` on `DocumentsContract.buildRootUri` (`vnd.android.document/root`), then `android.provider.action.BROWSE`, then the root document as a directory, then the Files app's launcher, then the system picker.
- **Limits.** No rename, delete, move, copy-within-Mac or folder creation; no overwrite of existing files; thumbnails for image/video/PDF only. Provider cursors can't be tested without a device, so the async logic is tested in JVM with a fake Mac (`FsTest`), including a real `TransferEngine` on both ends for the `fs:` path.

## Mac call audio (PROTOCOL.md section 8)

Optional, never part of onboarding. The phone side has three small pieces; pairing and `adb` are driven by the Mac.

**Helper `com.mydroid.callbridge.Main`** (`app/.../callbridge/`, logic in `:protocol/CallBridge.kt`). A plain class compiled into the APK; the Mac runs it as the shell user:

```
adb shell 'CLASSPATH=$(pm path com.whiteboxxai.mydroid | cut -d: -f2) app_process / com.mydroid.callbridge.Main'
```

- stdin/stdout are JSON lines and nothing else goes to stdout (`System.out` is pointed at stderr). Exits on `quit` or stdin EOF after releasing everything; any other failure becomes an event, not an exit. The Mac should use adb's shell protocol v2 so stderr stays separate (and ignore non-JSON lines).
- Mac to helper: `{"cmd":"hello","macHost":"192.168.1.5","udpPort":47900,"key":"<b64 32>"}`, `{"cmd":"route","to":"mac"|"phone"}`, `{"cmd":"quit"}`. Bad lines are ignored (logged to stderr). `hello` is only accepted while not routed.
- Helper to Mac: `{"ev":"tier","tier":"full|listen|none"}` (first line, then again if it changes), `{"ev":"call","inCall":true}` (initial state, then on change; leaving a call needs two 250 ms polls so a blip can't drop a routed call), `{"ev":"routed","to":"mac"}`, `{"ev":"routed","to":"mac","error":"not in a call"}`, `{"ev":"routed","to":"phone","reason":"call ended"}`, `{"ev":"routed","to":"phone","error":"audio stopped: ..."}`, and once a second while routed `{"ev":"stats","rxRms":812,"txRms":240,"lost":0,"sent":50,"recv":49,"underruns":0}`. `rxRms` = level of call audio going to the Mac, `txRms` = level of Mac audio going into the call, `lost` = uplink frames missing or late. Levels and counts only; **call audio is never recorded or stored**, frames live in memory for at most ~160 ms.
- Tier probe at start: `isPstnCallAudioInterceptable()` plus a dry construction (outside a call the factories throw `IllegalStateException`, which counts as "not in a call, plausible") gives **provisional `full`**; else a dry `VOICE_DOWNLINK` (then `VOICE_CALL`) `AudioRecord` gives `listen`; else `none`. `route mac` is the real test: if full can't make the downlink it falls back to `VOICE_DOWNLINK`, if it can't make the uplink it keeps the downlink, and either way emits `tier` `listen` first; if nothing works it emits `tier` `none` and a `routed` error. A `none` phone is re-probed when a call starts, since the dry check outside a call can be pessimistic. `route mac` outside a call waits up to 1.5 s for the mode (it can lag the Mac's tap) before refusing.
- Call mode: `AudioManager.getMode() == MODE_IN_CALL`, polled every 250 ms (VoIP uses `MODE_IN_COMMUNICATION` and is ignored). The helper builds its own `AudioManager` the way the spike did: `ActivityThread` system context wrapped with `com.android.shell` / uid 2000 attribution, reflective calls to the hidden `getCallDownlinkExtractionAudioRecord` / `getCallUplinkInjectionAudioTrack`.
- UDP (`:protocol/CallAudio.kt`): 20 ms PCM16 mono 16 kHz frames (640 B), packet `u32 seq (big-endian) || AES-256-GCM(key, nonce = 00000000 || u64 BE seq, frame)` = 660 B, no AAD. Keys `HKDF-SHA256(key, salt = empty, info = "mydroid audio down"|"mydroid audio up", 32)`. The helper sends from one socket and the Mac's uplink comes back to that socket's address. Receive side drops anything not exactly 660 B, failing GCM, or already seen / more than 64 behind (`ReplayWindow`). **Nonce rule for the Mac:** use a fresh random `key` for every helper process; the helper keeps `seq` counting across route changes while the key is unchanged, but a new process restarts at 0. Test vectors for the key derivation and one sealed packet (checked against CryptoKit) are in `CallAudioTest`.
- Uplink smoothing: `PlayoutQueue` (reorders by seq, pre-buffers 2 frames, holds at most 8, drops the oldest on overflow, resyncs after a >500 ms jump) feeds a write thread that writes exactly one frame per 20 ms deadline (after a 40 ms silence cushion) and writes silence when starved or when a slot never arrived. Writing faster than real time would only grow latency.

**Keep-alive and status** (`callaudio/CallAudioSetup.kt`). `settings.callAudio` (new optional bool from the Mac) turns the feature on. When it is on and `WRITE_SECURE_SETTINGS` is granted, `adb_wifi_enabled` is set to 1 on boot (`BootReceiver`), on every Wi-Fi connect, and whenever something switches it off while the Mac is connected (a `ContentObserver`, rate limited to one write per 5 s). It writes nothing otherwise. `feature.status` gains `callAudio` (`"on"` = enabled and granted, `"needs_setup"` = enabled, not granted, `"off"`), `devOptions` (`DEVELOPMENT_SETTINGS_ENABLED`) and `adbWifi`, re-sent when either global setting changes.

**Setup messages.** `fix.open` `what:"devoptions"` posts a notification that opens `ACTION_APPLICATION_DEVELOPMENT_SETTINGS`, or, with Developer options still locked, `ACTION_DEVICE_INFO_SETTINGS` with "Tap Build number 7 times to unlock Developer options". `"wireless_debugging"` opens the same Developer options screen with "Turn on Wireless debugging, then tap Pair device with QR code" (same locked fallback). With the companion association, an unlocked screen and the screen on, the activity is also opened directly. `adb.verify {nonce}` writes the nonce (<= 128 chars of `A-Za-z0-9+/=_.-`, anything else is refused) to `getExternalFilesDir(null)/adb-verify` and deletes it after 2 minutes (a stale one is also removed at app start). The Home screen has a quiet "Calls on your Mac" row: *Set up on your Mac* / *On* / *Off*, never a warning and no button.

**Verified without the phone:** JVM tests for framing, crypto vectors, replay window, playout queue, control parsing, and the whole bridge against a fake AudioRecord/AudioTrack and a loopback fake Mac (full, listen, downgrade, errors, call end, quit, EOF, reroute nonce continuity). `Main` itself was run on a plain JVM with android.jar stubs and a fake stdin: tier `none`, `route mac` refused with an error, clean exit on `quit` and on EOF. The APK contains `com.mydroid.callbridge.Main` (`classes9.dex`).

**Pending a real device (wireless debugging was unreachable when this was written):** that the helper starts under `app_process` from the APK path and reports a tier outside a call; confirmation of `full` (both factories succeeding in a call, which the spike showed for the downlink and a `STATE_INITIALIZED` uplink track); whether the remote party actually **hears** injected uplink audio (still unconfirmed, so the Mac labels talk "Experimental"); what the phone's own speaker and mic do while routed; `VOICE_DOWNLINK` vs `VOICE_CALL` for `listen`; keep-alive after `pm grant`; the `fix.open` screens on OxygenOS; `adb.verify` read by `adb shell cat`.

## Remote, quick actions and walk-away lock (PROTOCOL.md sections 10 to 12)

Code: `:protocol` has the wire and all the logic that can be wrong (`Remote.kt` messages, parsing and kind error text; `Trackpad.kt` gesture engine; `Laser.kt` orientation mapping; `Keyboard.kt` soft-keyboard diff), each with JVM tests. `:app` has `remote/` (sensor, volume keys), `mac/` (`MacControl`, the Lock tile, the presenting notification), `walkaway/` and `ui/Remote.kt`, `ui/MacCard.kt`. Pair with `Ble.phoneServiceUuid` (vector `phoneBleUuid`). TCP_NODELAY is set on the client socket in `Handshake.connect`.

**Remote** (Your Mac card, "Remote"). Segmented Trackpad / Presenter / Media. The screen stays on while it is open.
- *Trackpad:* one finger moves the cursor with velocity-based acceleration (about 1.25 Mac points per dp when slow, rising to 5.5 when fast); a quick tap clicks, a second quick tap double-clicks; two-finger tap right-clicks; hold still then move drags (`in.down` ... `in.up`, released on lift, on pause and on leaving the screen); two-finger scroll sends `began`/`changed`/`ended`, and a flick continues as `momentum` (exp decay, tau 320 ms). Moves go out at most every 9 ms (111/s) and scroll every 17 ms (58/s); movement in between is summed, never dropped. Click and drag start give a haptic. `in.scroll` deltas are finger movement in pixels (down = positive, content follows the fingers); the Mac decides how to post it.
- *Keyboard:* a hidden one-character-sentinel text field brings up Android's keyboard. Each change is diffed: removed characters are `in.key backspace` (works on an empty field), new lines `in.key enter`, the rest `in.text`. The special-key row has esc, tab, arrows, a one-shot ⌘ toggle (applies to the next key or character), ⌘C, ⌘V, ⌘Tab and Mission Control (⌃↑).
- *Presenter:* big Back and Next (`in.key left/right`, firing on touch-down), elapsed timer (tap to restart) and the time, laser pointer, and the volume buttons: down is Next, up is Back, while the screen is open (`onKeyDown`, no repeat). The laser uses the game rotation vector sensor (no magnetometer), registered only while the button is held. The pointing direction is the phone's top edge, measured from where it pointed when you pressed, mapped over a 36 by 22 degree field and smoothed with a One Euro filter, sent at most 60/s. Without that sensor the button says so.
- *Media:* play/pause, prev, next, volume up/down (hold to repeat) and mute through `in.media`. No Now Playing from the Mac: the protocol has none.
- When `remote.state.accessibility` is false, or the Mac is away, a calm overlay covers the pane ("Allow Mydroid on your Mac. A prompt is open there."), `remote.ask` is sent, and the overlay clears by itself when the state flips.
- When `remote.state.presenting` goes non-null while the app isn't in front, a quiet notification ("Presenting on your Mac? Tap for clicker") opens Presenter mode. It is cancelled when presenting ends, when the app comes to the front and when the session ends.
- Input has its own writer thread. If the socket stalls, moves, scrolls and laser updates are dropped after 40 are queued, so the cursor never replays old movement.

**Not built: Presenter with the screen off.** An active `MediaSession` with a `VolumeProviderCompat` would route the volume keys to the app with the screen off, but whether Android keeps routing to it depends on the OEM (it needs a playing-looking session, often a silent audio track), and it would also take over the phone's own volume keys. It couldn't be verified here without sending input to the Mac, so it is not shipped. Keep the screen on instead.

**Quick actions.** The Your Mac card shows `mac.status` (battery, Locked or Display asleep) and Lock, Sleep, Ring (toggle, clears after the Mac's 60 s) and Shortcuts (sheet listing `mac.shortcuts`; the star keeps a Shortcut as a chip on the card, stored on the phone). Errors from `mac.result` become one kind line in the Home snackbar; the raw error text is never shown. The Mac's lock fallback (`ok:true`, `note:"displaysleep"`) shows "Screen turned off. It locks if your Mac asks for a password after sleep." Actions need a live connection and say so when there isn't one (nothing is queued, since a lock that arrives an hour late is a surprise). The "Lock Mac" Quick Settings tile does the same and is unavailable while the Mac is away.

**Walk-away lock.** While `settings.walkAway` is true, the phone is paired and connected, and the foreground service is up, it advertises the phone UUID (low power, medium TX, non-connectable, UUID only, no timeout, no GATT server, no wakelock). It stops on disconnect, when the service stops, when Bluetooth turns off and when unpaired. Settings > Connection shows a row ("Walk-away lock is set on your Mac. It needs Nearby devices here.") with an Allow button, and Home shows it in the attention banner until it is granted.

## v1.10: Remote, rethought

`ui/Remote.kt` is the shell (four tabs, the permission panel), with `RemotePad.kt`, `RemotePresent.kt`, `RemotePlaying.kt` and `RemoteOpen.kt` for the tabs. `TrackpadEngine` gained three-finger swipes, pointer speed, reverse scroll and tap-to-click (`PadSettings` saves them). `RemoteInput` holds any one-shot modifier and mirrors what was typed. `MacControl` carries `MacUi.apps`, `present` and `media`; `RemoteApi` exposes them to the screens. Cover colours come from `ArtPalette`, tested on plain pixel arrays. The app's colours are the teal scheme by default (`MydroidTheme(dynamic = false)`).
