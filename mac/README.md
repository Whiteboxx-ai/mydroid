# Mydroid for Mac

Menu-bar app that makes an Android phone feel like an iPhone on a Mac. This is the server half of
`protocol/PROTOCOL.md`; the Android app lives in `android/`.

## Build and run

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd mac
swift build            # debug build of everything
swift test             # vectors, codec, loopback pairing/transfer, the test-server smoke run, and the v1.5 Remote / quick actions / walk-away tests, and the v1.8 camera-import and Continue on Mac tests
MYDROID_RENDER_DIR=/some/dir swift test --filter MydroidRenderTests   # off-screen PNGs of popover, banners, Settings and the full window (fixtures, light and dark)
scripts/build-app.sh   # release build -> ../build/Mydroid.app (ad-hoc signed, adb bundled) and ../build/mydroid-test-server
OUT=/some/dir scripts/build-app.sh   # same, into /some/dir instead of ../build
open ../build/Mydroid.app
```

First launch opens the Setup window (QR, code check, choose what syncs). Launch at login is turned
on at the end of setup. Developer mode: `MYDROID_DATA_DIR=/some/dir` keeps identity, ledger,
Pictures and Downloads under that folder (no Keychain, no `~/Pictures`); `MYDROID_LOG=1` logs to stderr.

Interop with the phone simulator:

```sh
build/mydroid-test-server --data /tmp/mydroid-smoke   # prints PAIR_URL, STEP n ok, then SMOKE OK or SMOKE FAIL <reason>
```

## Layout

- `Sources/MydroidCore` has no AppKit or SwiftUI. `Crypto` (HKDF, AES-GCM frames), `Codec` (messages, framing),
  `Server` (NWListener, Bonjour, handshake), `Hub` (pairing, sessions, dispatch, actions), `Transfers` and `Ledger`
  (resume from `.part`, sha256, dedupe, unique names), `Models` (notification, call, device, clipboard guard),
  `Stores` (Keychain and file stores), `Pairing` (QR URL, interface addresses), `NetworkWatcher`, `PhoneData` (SMS, photo library and
  calls models and decoders, `WireID`, `RequestBook`) and `History` (app-conversation history store).
- `MydroidCore/QuickShare/` is the Quick Share receiver (hand-written protobuf, UKEY2, secure messages, the connection state machine and the
  listener), `FileShare.swift` serves the Mac's folders to the phone, and `HubQuickShare.swift` joins both to the Hub. See the two v1.4 sections below.
- `Sources/Mydroid` is the SwiftUI app: popover, setup, settings, call panel, notification banners, clipboard watcher, and the full window
  (`MainWindow`, `MessagesView`/`MessagesModel`, `PhotosView`/`PhotosModel`, `CallsView`/`CallsModel`, `FilesView`/`FilesModel`),
  plus `FileShareProviders.swift` (QuickLook thumbnails and Spotlight search for shared folders).
- v1.5 adds `Remote.swift` (input parsing, the keycode map, `InputInjector`, `InputPipeline`, laser smoothing), `MacActions.swift` (quick actions,
  `mac.status`), `WalkAway.swift` (the walk-away state machine) and `Presenting.swift` (slideshow rules) to Core, `HubRemote.swift` for the Hub side, and
  `RemoteSystem.swift`, `RemoteController.swift`, `RemoteOverlays.swift`, `RingController.swift`, `MacStatusMonitor.swift`, `WalkAwayController.swift` and
  `RemoteViews.swift` to the app. See "Remote, quick actions and walk-away lock" below.
- v1.7 adds `Authenticator/` to Core (`AuthBroker`, the codec, `PublicSuffix` + `PublicSuffixData`, `Lookalike`, `OTPBridge`), the `MydroidNM` library (native messaging
  framing, the Unix-socket line protocol, manifest writer), the `mydroid-nmhost` helper, and `AuthShortcut`, `AuthHUD`, `AuthSettingsView`, `OTPSocketService` in the
  app. See "Authenticator" below.
- v1.8 adds `Authenticator/MigrationBatch.swift` (the minimal migration decoder and `ImportTracker`) and `ContinueOnMac.swift` (media ids, position, AppleScript text) to Core, and
  `CameraImport.swift`, `CameraImportView.swift` and `MediaHandoff.swift` to the app. See "Import through the camera and Continue on Mac" at the end.
- `Sources/mydroid-test-server` is the headless smoke driver. It runs the same `Hub` as the app.
- `Tests/MydroidCoreTests` has the test-vector tests, codec tests, an in-process Swift phone client for loopback
  tests, and a test that runs the real `mydroid-test-server` binary against a Swift simulator.

## What is real and what is not yet

Real and tested: the whole wire protocol, pairing and the confirm code, reconnect, notifications with reply and
dismiss, photo receive with resume and dedupe, Mac-to-phone file send, clipboard both ways, call state and actions,
`fix.open`, `find.ring`, heartbeat, listener restart on wake and on network change.

Not verified against a real phone: nothing here has talked to the Android app yet. Bonjour advertising is
implemented but only exercised on this Mac.

Be aware:
- **Call audio stays on the phone unless you set up "Hear calls on your Mac"** (Settings > Calls, see "Mac call audio" below).
  Until then the panel lets you answer, decline, mute and end, and says "Answered, audio is on your phone".
- The build is ad-hoc signed. `UNUserNotificationCenter` may refuse it; the app then uses its own floating banner
  (with inline reply). The banner is always built and works without any permission.
- Re-signing ad-hoc changes the app's code identity, so macOS may ask again for Keychain access and for
  Local Network access after each rebuild.
- Launch at login uses `SMAppService.mainApp`; macOS can decline for an app that isn't in `/Applications`.
- Clipboard is off by default (privacy). Items flagged concealed or transient by password managers are never sent.
- Only IPv4 addresses go in the QR code. If the phone can't reach a Mac behind client isolation, pairing will not work.

## v1.2 features (PROTOCOL.md 7.1 to 7.4 and 7.9)

- **Bluetooth presence (7.1).** `MydroidCrypto.bleUUID(ltk:)` derives the per-pairing UUID (vector test). `BlePresence`
  (`Presence.swift`) advertises only that service UUID with `CBPeripheralManager` while paired and Bluetooth is on. It
  stops on unpair and restarts after a Bluetooth power cycle and after wake. The Bluetooth permission prompt appears the
  first time the app runs while paired. If Bluetooth is off or denied, the popover shows one hint and Settings > Phone
  shows the state. No data goes over Bluetooth.
- **Settings window (7.2).** Sidebar with General, Notifications, Photos, Clipboard, Media and Phone. Synced fields
  (`mutedApps`, `screenshots`, `pauseBelowBattery`, `smsHistory`, `media`) live in `SyncSettings` and go to the phone on
  every change and on connect. Mac-only options live in `MacPrefs` (UserDefaults). The Hub also drops notifications from
  muted apps itself, in case the phone is older. The per-app list is built from every app seen so far
  (`knownapps.json` in Application Support). "Mute app" is on each notification row, each banner and in the system
  notification's actions. Quiet hours suppress banners (and auto-copy) but the list keeps everything. "Follow Focus" uses
  `INFocusStatusCenter`; an ad-hoc signed app usually can't get that access, in which case the option is hidden.
  Photos can also be added to Apple Photos (add-only access) and screenshots (files named `Screenshot...`) can go into a
  `Screenshots` subfolder. Pasteboard items marked `ConcealedType` or `TransientType` are never sent.
- **Now playing (7.3).** Compact row in the popover with art, title, artist, app, previous, play/pause, next and a thin
  progress bar extrapolated in a `TimelineView` from `position`, `ts` and `playing`. Hidden when inactive or turned off.
- **Links and send to phone (7.4).** `link.open` from the phone opens in the default browser or shows a banner with
  **Open**, per setting (http, https and mailto only). To the phone: the Services menu entry **Send to Phone** (text and
  URLs, files; the menu title is fixed in Info.plist so it can't carry the phone's name), the URL scheme
  `mydroid://send?url=...`, `?text=...` or `?file=/absolute/path` (use "Open URL" in Shortcuts), and dropping files or
  links onto the popover. A single URL becomes `link.open`, other text becomes `clip.set` (works even when clipboard sync
  is off, because it is explicit), files use `xfer`. After a fresh install, run `/System/Library/CoreServices/pbs -flush`
  or log out and in if the Services entry doesn't show up.
- **Phone health (7.9).** Optional battery percentage next to the menu bar icon (hidden when disconnected), one
  "battery is low" banner on the first report below 20% while not charging (re-armed by charging), and a Battery saver
  badge in the popover header when `lowPowerMode` is set.

Future work: a WidgetKit widget and a Share extension (for Safari and Photos) need an Xcode-built `.appex`, which this
SwiftPM build can't produce.

Permission prompts you will see once: Bluetooth (on first run while paired), Photos add-only (when you turn on "Also add
to Apple Photos"), and Focus status (when you turn on "Follow Focus"; it may be refused for an ad-hoc build). v1.5 adds Accessibility (the first time the phone
controls the Mac) and, for walk-away lock, Bluetooth scanning; see the last section.

## v1.3: the full window (PROTOCOL.md 7.5 to 7.8)

**Open Mydroid** in the popover footer (or **Control-Option-M** from any app, or the Go menu) opens a window with a
sidebar (Messages, Photos, Calls, Files) and the phone's name, battery and connection at the bottom. While it is open Mydroid is in the
Dock and Cmd-Tab (`setActivationPolicy(.regular)`); closing it goes back to a menu-bar-only app. Cmd-1 to Cmd-4 switch sections, Cmd-N
starts a new message, Cmd-F searches, Cmd-O sends a file. Every section has its own empty, loading, disconnected and permission state.

- **Messages.** One list that merges SMS threads (`sms.threads`) with app conversations (`category:"message"` notifications, with a small
  app badge). Thread view with day separators, sender names in groups, timestamps on hover, optimistic pending bubbles (`sms.send`, then
  `sms.sent`, then a refetch until the phone's own copy shows up), retry on failure, paging of older messages on scroll, refetch on
  `sms.changed` (coalesced). App chats reply through `notif.reply`. New message resolves a number, or the name of someone you've texted.
  Texts need `settings.smsHistory`; the window offers a one-click "Turn on text messages". On `sms.error permission` it shows
  **Ask on your phone**, which sends `fix.open {what:"sms"}` (the Android side must handle `"sms"`; older builds ignore it).
- **App chat history.** Android only sends the last few messages of a conversation, so the Mac keeps what arrives: `history.json` in
  Application Support (mode 0600), at most 200 messages per conversation, de-duplicated by sender, text and time. A reply typed here
  shows at once and is replaced by the phone's echo of it. Notifications that carry a one-time code are not kept. Views explain that
  app chats show only what arrived as notifications.
- **Read sync (7.6).** Opening a conversation sends `notif.read` for its notification keys (for SMS threads: the Messages-app
  notifications whose title matches the thread). Expanding a conversation in the popover does the same, and so does replying.
  One deliberate difference: Android needs the notification to deliver a reply, and reading removes it, so for a conversation that
  `canReply` the read waits until the reply has been delivered (`notif.result ok`), or until you leave the conversation or close the
  popover/window. The unread dot clears at once either way.
- **Photos.** Album picker (All, Camera, Screenshots), month sections, an adaptive grid with a size slider, paged with `photos.list`.
  Thumbnails are requested for visible cells only (`photos.thumbs.get`, batches of up to 30, at most 60 in flight, retried) and cached
  in memory and in `Caches/Mydroid/Thumbs/<pairing>`. Click selects (Cmd and Shift extend), double-click or Space opens the preview
  (arrow keys step, Esc closes), which downloads the original with `photos.get`. **Save to Pictures** copies it into the Mydroid
  pictures folder (and to Apple Photos if that is on), skipping photos auto-sync already saved. **Copy**, **Share**
  (`NSSharingServicePicker`) and dragging a photo out to Finder or another app work; a photo that isn't downloaded yet is dragged as a
  file promise and downloads on drop. Multi-select **Save** downloads two at a time.
- **`lib:` transfers.** `photos.get` answers with `xfer.offer xid:"lib:<id>"`. Those go to `Caches/Mydroid/Library/<id>/` (cache files older
  than 3 days are removed at launch), never to the Pictures folder, never into the dedupe ledger, never skipped or resumed, and never
  counted as "latest photo" or as a sync in progress. The Hub reports them as `libraryProgress`, `libraryReady` and `libraryFailed`.
- **Calls.** Recents with in, out, missed and declined icons, name or number, time and duration, an All/Missed filter, a call-back
  button (`call.dial`, "Calling on your phone"), and a dial pad with a number field. The audio stays on the phone.
- **Files.** Photos synced automatically, files received and files sent in one list (filter: All, Photos, Files, Sent), in-flight
  transfers on top, Open, Reveal in Finder, Send Again, drag out, and drag files in (or Send File...) to send. Sent files are remembered
  in `sent.json`.
- **Plumbing.** Replies to `sms.threads.get` and `photos.list` carry no request id, so the Hub keeps a short first-in-first-out
  `RequestBook` (entries expire after 30 s) and tags the reply with the request it answers. `sms.messages`, `sms.sent` and
  `sms.changed` are matched by `threadId` and `clientId`. Thumbnails carry their own `id`. Ids can be numbers or strings on the wire;
  `WireID` sends back whichever the phone used. Call `duration` is read as seconds. A reply with `error:"permission"` (`sms.error`, `photos.page`,
  `calls.page`) becomes the "Ask on your phone" state; a thumbnail with `ok:false` is marked failed at once; a bare `xfer.cancel` for a `lib:`
  id fails that download at once. Numbers with `*` or `#` are refused on the Mac, as the phone would.

Not verified against a real phone: none of the new messages have run against the Android app yet. The off-screen renders cover
the layouts, not drag and drop, the sharing sheet, the Dock behavior or the global shortcut, which need a person at the machine.

## Opening notifications from the Mac (v1.6, PROTOCOL.md 13)

Clicking a phone notification on the Mac does something useful instead of nothing. The phone can't tell the Mac where a
notification's tap would go, so the Mac picks from what it can see.

- **Fields.** `PhoneNotification` now also holds `person` (`{name, phone?}`, normalised to E.164 or dropped), `links` (http and https
  only, deduplicated, at most 3) and `media` (`{title, artist, album?, mediaId?}`). All optional; older phones parse exactly as before.
  `Hub.openOnPhone(key:)` sends `notif.open {key}`; the phone's `notif.result` shows "Couldn't open it on your phone" on failure and, for a
  conversation, marks it read (7.6) on success. A phone open shows the toast "Opening on your phone".
- **`OpenRouter` (Core, `OpenRouter.swift`).** A data-driven table, `OpenRule.builtIn`, keyed by Android package (compared without case): Gmail, WhatsApp and
  WhatsApp Business, Telegram, X, Instagram, LinkedIn, YouTube, Spotify, Amazon (India and global, each with its own host), Swiggy, Zomato and Uber. A rule is a list of
  steps (condition, then target), first match wins. URLs are templates (`{phone}`, `{id}`, `{q}`, `{host}`), and every filled-in value is percent-encoded.
  To support another app, add a rule. The result is an `OpenAction`: `.web(URL)`, `.macApp(bundleID:url:fallback:)`, `.phone(key:)` or `.none`.
  "Message" means `category == "message"` or a conversation. Rules, in short (see section 13.3 for the full table):
  Gmail searches `subject:"<first line of text, else title>"`; WhatsApp and Telegram use the Mac app when `net.whatsapp.WhatsApp` / `ru.keepcoder.Telegram` /
  `org.telegram.desktop` is installed (`NSWorkspace.urlForApplication(withBundleIdentifier:)`, behind the `AppLocator` protocol) and the web
  otherwise, with the chat when the sender's phone number is known (never for a group); Spotify opens `spotify:track:<id>` in `com.spotify.client` or on open.spotify.com, and
  anything else on the phone; YouTube searches for the channel plus the video title, pulled apart from phrasings such as "MKBHD uploaded: ..." and falling back to
  the whole text. **A notification with `links` opens its first link, ahead of the app's rule.** Everything without a rule opens on the phone. Zomato has no verified orders URL, so it opens zomato.com.
- **Per app.** Settings > Notifications > Apps: each known app has **When clicked**: Default (the line beside it says what that does, for example "Opens x.com/notifications"),
  Open on phone, Open on web (only for apps with a web rule) or Do nothing, stored in `MacPrefs.clickBehavior` (Default is stored as no entry). It sits next to the app's on/off switch (mute); a muted app's picker is greyed out.
- **Where it applies.** A click on the text of a popover notification row, on a conversation row, on a banner, or on a system notification (its default action) does the app's
  choice. The Reply field, the Reply/Dismiss/Mute links, buttons on a banner and the OTP Copy button keep their own clicks. A conversation row now opens on click and the
  chevron at its right expands it (as before it also marks it read); with "Do nothing", a click on the row expands it. After a successful open on the Mac a conversation is marked read (`notif.read`); other notifications are left alone.
- **Right-click** on a row, conversation or banner: **Open on phone**, **Open on web** (when there is a page), **Search the web** (Google, title and text, never for a verification code), **Copy text**
  (concealed, so clipboard sync never echoes it) and **Mute <App>**. The menu entries come from `NotifUIState.menu(for:)`.
- **Nothing real is launched in tests.** All opening goes through the `MacOpener` protocol (`NSWorkspace` in the app, `RecordingOpener` in tests) and no notification text,
  number or URL is logged. A banner can disappear while its right-click menu is open; use the popover row if that gets in the way.

## Mac call audio (PROTOCOL.md section 8)

Optional, never part of the main setup. After setup the popover shows a **Hear calls on your Mac** card with **Set up** and
**Not now** (Not now hides it for good; Settings > Calls always has it). Setup is one guided window with a live checklist that
ticks off by itself:

1. **Developer options.** The Mac sends `fix.open {what:"devoptions"}`; the phone opens the right screen. The step completes when
   the phone starts advertising wireless debugging.
2. **Pair with a QR code.** The Mac shows an ADB pairing QR (`WIFI:T:ADB;S:<service>;P:<password>;;`, made with CoreImage). The
   user taps Wireless debugging > Pair device with QR code and scans it.
3. **Pairing** happens by itself: `adb mdns services` is polled for `_adb-tls-pairing` with our service name, then `adb pair`,
   then `adb connect` via `_adb-tls-connect`. The Mac then sends `adb.verify {nonce}` over the Mydroid link and reads the nonce
   back with `adb shell cat`, so it only ever works with the phone it is paired with (every reconnect checks again; a device that
   can't prove it is disconnected). Last, the keep-alive grant (`pm grant ... WRITE_SECURE_SETTINGS`).
4. **Checking what your phone supports.** The helper reports a tier, and the sheet says in plain words what that means:
   `full` (hear and talk), `listen` (listen on the Mac, talk into the phone) or `none` ("Your phone doesn't let apps reach call
   audio. You can still answer, decline and mute from your Mac."). For `none` everything is switched straight back off.

The sheet mentions once that some banking apps refuse to run while Developer options are on, and that turning call audio off later
undoes everything. **Turn off** (Settings > Calls) disconnects adb, revokes the grant and tells the phone (`settings.callAudio=false`)
to stop keeping wireless debugging on.

**What runs where**

- `Sources/MydroidCore/CallAudio.swift` (no AppKit, tested): the audio packet cipher (`u32 seq` big endian, then AES-256-GCM with
  nonce = 4 zero bytes + u64 seq, per-direction keys from HKDF), `JitterBuffer` (about 60 ms: reorders, conceals loss by repeating
  the last frame and fading, drops late and duplicate frames, trims runaway depth, resyncs when the sender restarts),
  `StreamResampler` (windowed sinc, any hardware rate to and from 16 kHz), `AudioLink` (UDP socket, authenticated packets only;
  uplink goes to the source address of the downlink), `LocalAddress.reaching(host:)` (the Mac IP that reaches the phone).
  `AdbSupport.swift` has the pure parts of adb and the helper's JSON lines (QR payload, mDNS and device parsing, tiers, backoff).
- `Sources/Mydroid/AdbClient.swift`: runs the bundled adb with its **own server** (`ADB_SERVER_SOCKET=tcp:localhost:5099`,
  `ANDROID_ADB_SERVER_PORT=5099`) and its **own key home** (`HOME` is `Application Support/Mydroid/adb-home`), so it never
  touches a developer's adb on 5037 or their `~/.android`. `MYDROID_ADB` points at another adb for development.
- `Sources/Mydroid/CallAudioController.swift`: setup, reconnects (when the phone link comes up and wireless debugging answers),
  the helper (`adb shell CLASSPATH=$(pm path ...) app_process / com.mydroid.callbridge.Main`, restarted with backoff, `hello`
  with the Mac's LAN address, a UDP port and a fresh key per session), routing, and persistence.
- `Sources/Mydroid/CallAudioEngine.swift`: `AVAudioEngine` with voice processing (echo cancellation) on the input, the downlink
  as an `AVAudioSourceNode`, the microphone through a tap, resampled to and from 16 kHz, uplink frames every 20 ms, optional
  output and input device per Settings > Calls. The microphone is only touched in the `full` tier, and macOS asks for permission
  the first time. Call audio is never recorded, written to disk or logged; only levels and counts are kept.
- `Sources/Mydroid/CallAudioViews.swift`: the pending card, setup sheet, the **Phone | Mac** switch ("Listen on Mac" for
  `listen`), the live level meter and "Talk from Mac (experimental)" note, the "Did the other person hear you?" question (asked
  once, after the first routed call; shown in the popover and in Settings), and Settings > Calls (state, tier, wireless
  debugging, last connected, Set up / Turn off, "Use Mac audio when I answer on Mac" (off by default), speaker and microphone).

**adb is bundled from Android platform-tools.** `scripts/build-app.sh` copies `$HOME/Library/Android/sdk/platform-tools/adb`
(or `$MYDROID_ADB`) into `Contents/Resources/adb`, copies any non-system library it links (none today: it is one universal
binary that links only system libraries) and signs it ad hoc inside the bundle. Without it the build still works and the app says
call audio isn't available. **Check the platform-tools licence terms before any public distribution.**

Not verified against a real phone or a real call: the helper on the phone, QR pairing and mDNS on a real network, the keep-alive
grant, the `adb.verify` file, tier detection, and the audio engine itself (voice processing, device selection, latency, echo, the
microphone permission prompt). Tests cover the packet crypto, jitter buffer, resampler, a UDP loopback with an encrypted sender
(order, loss, late drops), the adb and helper parsing, and the controller (setup, wrong device, `none` undo, restarts, routing)
with a fake adb, helper and engine.

## Quick Share receiver (v1.4)

**Share > Quick Share > your Mac** works from any Android phone on the same network. The Mac advertises itself the way Google's Quick
Share receivers do, runs the handshake and receives **files, text and links**. It is Mydroid's own Swift implementation, written from
[NearDrop](https://github.com/grishka/NearDrop)'s protocol notes ([PROTOCOL.md](https://github.com/grishka/NearDrop/blob/master/PROTOCOL.md))
and its Swift sources and protobuf definitions, which are public domain (Unlicense). No Google code and no SwiftPM dependencies: the
few protobuf messages are hand-coded.

- **Settings > Quick Share.** *Show this Mac in Quick Share*: Always, **Only when my phone is connected** (default) or Off. *Accept
  from other devices*: **Ask** (default) or Never. *Save received images in the Photos folder* (off: images go to Downloads like other files).
  Advertising and listening follow the setting and the phone's link to Mydroid; the listener restarts on a network change and after wake.
- **Who is trusted.** A share is accepted without asking only when the sender's device name matches the paired phone's name (or model) **and**
  that phone is connected to Mydroid right now **and**, when both addresses are known, the share comes from the phone's address. Anyone
  else gets a banner (**Accept** / **Decline**, the sender, what they want to send and the 4-digit PIN to check against the sender's screen),
  declined automatically after 30 seconds. At most 3 requests wait at once. The address check is stricter than "same name", because a
  device name is easy to copy.
- **Text** goes on the clipboard (marked as Mydroid's own write, so clipboard sync never sends it back) with a "Copied from <phone>"
  banner. **Links** (http, https, mailto) follow Settings > General > *When your phone sends a link*: open, or a banner with Open. Anything
  else that looks like a URL is treated as text. **Files** go to `~/Downloads` (or the Photos folder for images, if chosen) with unique names
  (`name (2).ext`), a "Saved to Downloads" banner with **Show in Finder**, and an entry in the Files list. In-flight files show in the same
  transfer list as other transfers. These banners are shown during quiet hours too, because you started the transfer.
- **Not supported**, and declined with the "unsupported attachment" status: Wi-Fi credentials, apps, streams. No Bluetooth: Android only
  finds the Mac over Wi-Fi.
- **What runs where.** `Sources/MydroidCore/QuickShare/`: `Protobuf.swift` (varint/length-delimited reader and writer), `QSMessages.swift` (offline
  frames, UKEY2, SecureMessage, Nearby Share frames), `QSCrypto.swift` (UKEY2 server side with CryptoKit P-256, key schedule, PIN, AES-256-CBC +
  HMAC-SHA256 secure channel), `QSEndpoint.swift` (mDNS name and endpoint info), `QSConnection.swift` (the receiving state machine, driven by
  frames, no sockets), `QuickShareService.swift` (NWListener + `_FC9F5ED42C8A._tcp` Bonjour record, framing, limits). `HubQuickShare.swift`
  applies the policy and turns it into `HubEvent`s (`quickShareRequest`, `quickShareText`, `quickShareLink`, `quickShareDone`, ...) and the usual
  `received` events and ledger entries. The banners are in `Panels.swift`, the settings in `SettingsView.swift`.
- **Info.plist.** `NSBonjourServices` lists `_FC9F5ED42C8A._tcp` next to `_mydroid._tcp`, and `NSLocalNetworkUsageDescription` mentions Quick Share.
  macOS asks for Local Network access the first time; re-signing ad hoc may ask again.
- **Safety limits.** Frames over 5 MiB, text over 4 MiB, more than 100 items, more than 5 connections, a silent connection (20 s in the
  handshake, 45 s afterwards) and a file bigger than the free space (plus 16 MiB) are all refused. File names are reduced to a safe last
  component. Partial files (`.part`) are removed when a transfer fails or is cancelled.
- **Tests** (`Tests/MydroidCoreTests/QuickShareTests.swift`, `FileShareTests.swift`): protobuf wire vectors, every message's round trip,
  endpoint and mDNS name vectors, the UKEY2 key schedule against vectors computed by an independent Python implementation of NearDrop's
  documented formulas (not Google vectors), PIN vectors, public-key encoding, AES padding, tampered, replayed and out-of-order secure messages, framing, the trust
  rules, a Swift Android-sender simulator driving the state machine in memory (text, link, files, several payloads, hostile names, reject,
  timeout, cancel, bad offsets, disk full, keep-alives), the same over real TCP through the service, and the Hub end to end with a paired test phone.

Not verified against a real phone: nothing here has talked to Android's Quick Share. Specifically unchecked: that Android lists this Mac
(mDNS visibility, the Local Network prompt, Android's "visibility" modes), the device-name match (the phone's Quick Share name can differ from the
name Mydroid's Android app reports; then you are asked instead), the answer to Android's *safe to disconnect* request, the Mac's own keep-alive
frames, and newer Android introductions. The key schedule follows NearDrop's notes; the ECDH secret is the 32-byte x coordinate (as in the UKEY2
reference), where NearDrop's code uses the shortest byte string.

## Mac files on the phone (PROTOCOL.md section 9)

The phone shows the Mac's folders in Android's Files app and in file pickers. The Mac serves `fs.roots`, `fs.list`, `fs.thumb`, `fs.get`,
`fs.put`, `fs.search` and `fs.recent` from `Sources/MydroidCore/FileShare.swift`, wired in `Hub.swift` and `HubQuickShare.swift`.

- **Settings > Files.** *Share Mac folders with your phone* (on by default), the folder list (Desktop, Documents and Downloads to start with;
  **Add Folder...** uses an open panel, the minus button removes one), and *Allow saving to this Mac* per folder (off by default). The page says once
  that macOS asks whether Mydroid may reach Desktop, Documents and Downloads the first time the phone opens them (`Info.plist` has the three usage
  strings). The list is stored in UserDefaults as bookmarks plus paths, so a renamed or moved folder is followed; a folder that is gone
  shows "Not found" and is not shared. In developer mode (`MYDROID_DATA_DIR`) the defaults are folders under that directory.
- **Confinement** (`SharePath`). Paths are relative to a root. Absolute paths, `..`, `.`, empty and hidden (dot) components and NUL are refused.
  The result is resolved with `realpath` and must still be inside the (also resolved) root, so symlinks that leave it are refused, and a link
  into a hidden folder too. Listings skip hidden files and links that point outside. All of it is tested against a tree with escaping links.
  Every request is checked against the current settings, and an upload offer is checked again when it arrives.
- **`fs.get`** sends the file with the existing sender as `xid` `fs:<req>` (shown in the transfer list, but not as a "Sent" entry in Files).
  **`fs.put`** is allowed only into a writable root and an existing folder, answers `fs.put.ready`, and takes the phone's `xid` `fsput:<req>` through
  the existing receiver: the folder and file name come from the request, names are made unique (`name (2).ext`), nothing is overwritten, the ledger and the
  Files history are not touched, and a dropped upload leaves no partial file. An `fsput:` offer that no `fs.put` announced is refused.
- **Thumbnails** are QuickLook (`QLThumbnailGenerator`, app target, behind `FileThumbnailProvider`), JPEG at about 256 px, six at a time,
  `ok:false` for files without a real preview. **Search and recent files** use `NSMetadataQuery` (`FileSearchProvider`, scoped to the shared roots);
  results are filtered again against the roots (hidden, outside, duplicates) and capped at 50 and 30.
- A folder listing is capped at 5000 entries or about 700 KB, because the protocol has no paging.

Not verified against a real phone or a real Spotlight index: the `QLThumbnailGenerator` and `NSMetadataQuery` providers are small and
untested here (the service around them is tested with fakes), and so is the macOS privacy prompt flow.

## Remote, quick actions and walk-away lock (v1.5, PROTOCOL.md 10 to 12)

Three features that work from the phone to the Mac. Nothing new appears in the popover except one quiet line while you are presenting ("Clicker ready on your
phone") and the Accessibility card when it is needed. Everything else is in **Settings > Remote** and **Settings > Walk-away lock**.

**Every system effect sits behind a protocol, so no test posts an input event, locks, sleeps or rings the Mac.** `SyntheticEventPoster` (posts), `AccessibilityChecking`,
`CommandRunning` (pmset, shortcuts), `RingControlling`, `BleScanning`, `IdleTimeSource` and `DisplayWaking` each have a real implementation in the app
(`RemoteSystem.swift`, `RingController.swift`, `WalkAwayController.swift`) and fakes in the tests.

### Remote: trackpad, keyboard, clicker, media (section 10)

- **Latency.** The listener sets TCP_NODELAY (`Server.listenerParameters`, asserted in a test). `in.*` messages take a fast path in the Hub: they are decoded and handed to
  `Hub.onRemoteInput` on the network queue, with no state publish, no event and no hop through the main actor. `RemoteInputRouter` passes them to `InputPipeline`, a serial
  queue with no timer in front of it: the first event is posted at once, and if events arrive faster than they can be posted, neighbouring moves (and scrolls in the same phase) are added
  together, so the pointer never falls behind. Order is always kept.
- **Injector** (`InputInjector`, Core, tested with a recording poster). Relative moves are tracked from the real pointer (read again after 0.4 s idle, so the physical trackpad still wins) and clamped to
  the union of the displays (`ScreenGeometry.clamp`, multi-display aware: a point on any display is untouched, otherwise it goes to the nearest display). Click, right click and middle click; a
  double click is two down/up pairs with click state 1 then 2; drag is down, `leftMouseDragged` moves, up. A session that ends mid-drag releases the button. Scroll is continuous
  pixel scroll with the `CGScrollPhase` and momentum phase values (began 1, changed 2, ended 4; momentum begin 1, continue 2, end 3); fractional pixels are carried so slow scrolling still moves.
  Keys: names go through the keycode map (`KeyMap`: arrows, enter, escape, space, tab, backspace, delete, home, end, page up and down, F1 to F12, tested against the Carbon values);
  a single character is typed as Unicode, except in a cmd or ctrl chord, where it uses its ANSI key position so cmd-C is the C key. `in.text` goes in chunks of at most 20 UTF-16 units
  (never splitting an emoji), with Return and Tab as real keys. Media keys are `NSEvent` `NX_SYSDEFINED` subtype 8 (play/pause 16, next 17, previous 18, volume up 0, down 1, mute 7).
  Settings > Remote has **Reverse scroll direction**, because which way the phone's two-finger scroll should go can't be checked without the phone: dy is passed through as "content follows the fingers".
- **Accessibility.** Posting events needs it. On `remote.ask`, or the first `in.*` without permission, a floating card says **Allow Mydroid to control this Mac from your phone** with
  **Open Settings** (the system prompt through `AXIsProcessTrustedWithOptions`, which also adds Mydroid to the list, then the Privacy & Security > Accessibility pane) and **Not now**. The same ask shows
  as a card in the popover while it is pending. It re-checks when the app becomes active and every 2 s while it shows, closes by itself when macOS says yes, and sends `remote.state` on
  every change (also when permission is revoked while running; the answer is cached for 1 s). While it is missing, input is dropped, never queued. **Each ad-hoc rebuild is a new app to macOS:** after
  rebuilding you may have to switch Mydroid off and on again in Accessibility (or remove it with the minus button and add it back). The card and Settings say so.
- **Laser.** `in.laser` draws a soft glow (a radial gradient and a core dot) in a transparent, click-through (`ignoresMouseEvents`), borderless, non-activating window over the main display, at
  `CGShieldingWindowLevel` so it is above full-screen slideshows, on all Spaces. The position is a latest-value mailbox read by a 60 Hz timer that smooths it (`LaserSmoother`), so it works without Accessibility
  and without touching the main actor per message. Colour is in Settings > Remote (**Show laser** previews it for two seconds).
- **Presenting.** `PresentingDetector` (Core, tested) holds the rules: Keynote playing, PowerPoint with "Slide Show" in a window title, Preview or any app that is full screen with "Slideshow" or "Slide Show" in the
  title, and Google Slides or PowerPoint Online full-screen in a browser. `PresentingMonitor` feeds it: it looks when the active app or Space changes, and polls every 2 s only while Keynote, PowerPoint, Preview
  or a browser is in front. Window titles come through Accessibility (other apps' titles otherwise need Screen Recording, which Mydroid never asks for); without it, only "covers a whole screen" is known. For Keynote it asks
  `tell application "Keynote" to return playing`, but only if Automation is already allowed (it never triggers the prompt by itself; Settings > Remote has an **Allow** button for it). The result goes to
  the phone as `remote.state.presenting`, and the popover shows "Clicker ready on your phone" while it is set and the phone is connected. Next and Previous are `in.key right` and `left`.

### Quick actions and Mac status (section 11)

- `mac.action` is always answered with `mac.result {req, ok, error?}`, echoing `req` as a number or a string. **Lock** posts control-command-Q (needs Accessibility). Without it, the Mac gets
  `pmset displaysleepnow` instead, which locks if "Require password after screen saver begins or display is turned off" is immediate, and the result is `ok:true` with an extra field `note:"displaysleep"`
  (additive; a phone that doesn't know it ignores it). **Sleep** is `pmset sleepnow`, **Display sleep** is `pmset displaysleepnow`. **Ring** raises the output volume to maximum and unmutes (the previous
  level is put back when it stops, also at quit), wakes the display, loops the Sosumi alert sound and shows a floating **Your phone is looking for this Mac** panel with **Stop**; it ends on Stop, on `ringstop`, or after 60 s.
  **Shortcut** runs `/usr/bin/shortcuts run <name>` with the name as one argument (no shell; empty, over-long, control-character and leading-dash names are refused). The phone is answered when the shortcut
  exits, or after 3 s if it is still running (a Shortcut that doesn't exist exits at once with an error). Without a handler (the headless test server) the Hub answers `ok:false, error:"unsupported"`.
- `mac.shortcuts.get` answers with the names from `shortcuts list` (deduplicated, at most 500), or `error`.
- `mac.status` has the battery (IOKit power sources; null on a desktop), charging, locked (`CGSSessionScreenIsLocked`, plus the screen locked and unlocked notifications) and display asleep (screens did sleep
  and wake notifications). It is sent on connect and when the value changes, never on a timer: the monitor reacts to change notifications only, and the Hub drops a status equal to the last one sent. `remote.state` and
  `mac.status` only go out once the app has reported a value, so the headless test server's behaviour is unchanged.

### Walk-away lock (section 12, off by default)

- The `walkAway` setting is a new `SyncSettings` bool (sent in `settings`, default false, absent in older saved settings). The Mac derives the phone's BLE service UUID from the pairing
  (`MydroidCrypto.phoneBleUUID`, checked against the `phoneBleUuid` vector) and scans for it with `CBCentralManager`, `allowDuplicates` on only while the feature is on and a phone is paired.
  Bluetooth access is asked for when the toggle is first switched on (the same permission as the presence advert).
- **`WalkAwayMachine`** (Core, tested with made-up samples and a made-up clock) holds all the decisions: an exponential moving average of RSSI (weight 0.3, started afresh after a 6 s gap); away when the average is
  below the threshold for 8 s (Near -65, Medium -75 default, Far -85 dBm) or nothing was heard for 12 s; **in use** when `HIDIdleTime` is under 20 s, in which case it looks again every second until the Mac goes
  quiet (so it can lock a minute later); one lock per absence, however long; an already-locked screen is left alone; back when the average is above threshold + 8 dB for 3 s, which wakes the display only if Mydroid
  was the one that locked it. It is reset when the feature is turned off and after the Mac wakes from sleep, so a stale "last seen" never locks a Mac you just opened. The `HIDIdleTime` read (`HIDIdleTime`) counts only keyboard and
  pointer input: watching a video without touching anything counts as idle.
- **Actions** go through the same layer as the phone's buttons: `mac.action lock`, then `displaysleep` 0.8 s later. Return wakes the display with `IOPMAssertionDeclareUserActivity` (no input event is posted), if
  "Wake display when I return" is on (default). **Mydroid never unlocks the Mac**: no code path exists for it, and the lock screen waits for Touch ID or the password. Without Accessibility only the display
  can be put to sleep (Settings says so).
- While it is on, the app holds a `userInitiatedAllowingIdleSystemSleep` activity so macOS doesn't App Nap the menu-bar app and delay the scan and the 1 s timer; it is released when the feature is turned off.
- **Settings > Walk-away lock:** the toggle, a one-time note that it needs Bluetooth on both devices, **Sensitivity** (Near, Medium, Far), **Wake display when I return**, and a live **Phone signal: strong / medium / weak**
  meter (with the threshold marked) for calibration, plus plain warnings when Bluetooth is off or refused, the phone isn't connected (it only advertises while connected), or Accessibility is missing.

### Permissions you will be asked for

- **Accessibility** (Privacy & Security > Accessibility): the first time the phone uses the trackpad, keyboard, media keys or Lock, or opens Remote while it is missing. Never during setup.
- **Bluetooth** (when you switch walk-away lock on; it is already granted if the presence advert has run).
- **Automation for Keynote** (only if you press **Allow** in Settings > Remote; without it Keynote is detected by its window).
- Shortcuts run without a prompt of their own; a Shortcut may ask for its own permissions.

### Verified and not verified

Tested with fakes and made-up data: parsing of every `in.*` message, the keycode map, the injector's event sequences (moves, clamping, clicks, double click, drag, scroll phases, keys, text, media), the coalescing pipeline, the
laser smoother, the walk-away machine and its controller, presenting rules, the action service (lock chord, fallback, pmset, shortcut arguments, list parsing), the Hub on the wire (state on connect and on change, status only on change, `mac.result`
with `req`, no state publishing for input), TCP_NODELAY, the ring (start, stop, 60 s auto-stop, volume restore), the Accessibility trust cache and re-check, and the laser window's click-through and all-Spaces attributes. Not verified: any real event
being posted or accepted by macOS, the real lock, sleep and display-sleep, the system volume change, CoreBluetooth scanning, the real RSSI of the phone, the Accessibility and Bluetooth prompts, Keynote's AppleScript, and
presenting detection in a real slideshow. All of that needs a person at the Mac with the phone.

## Authenticator (v1.7, PROTOCOL.md 14)

2FA codes from the phone's vault, filled in the browser or typed by a shortcut. Secrets stay on the phone; every fill is approved there (unless auto-approve is on).
The Mac side is only a broker and a UI. Everything is in Settings > Authenticator.

- **`AuthBroker` (Core).** Encodes `auth.code.get`, `auth.list.get`, `auth.domain.set` and decodes `auth.code`, `auth.list`. `requestCode` awaits the reply for 35 s (the phone's own
  approval gives up at 30 s); the list is kept in memory only and dropped when the phone disconnects. It ends each request once: reply, timeout, cancel or the link dropping. The Hub owns one
  (`hub.auth`) and feeds it the phone's `auth.*` replies. `AuthOutcome.description` never contains the code, and nothing in this feature logs a code, an issuer, an account or a site.
- **eTLD+1.** `PublicSuffixList.shared.registrableDomain(of:)` uses an embedded Public Suffix List (ICANN section, 2026-11-21, multi-label rules plus wildcards and exceptions, about 60 KB) and a short
  curated list of private suffixes (`github.io`, `herokuapp.com`, ...) so one person's subdomain is never another's site. `login.salesforce.com` and `foo.my.salesforce.com` become `salesforce.com`;
  `accounts.google.co.in` becomes `google.co.in`. IP addresses and `localhost` have none (the host itself is sent). To refresh the list, regenerate `PublicSuffixData.swift` from publicsuffix.org.
- **Lookalikes.** `LookalikeDetector.assess` compares an unknown site with the issuers' domains and names: confusable characters (`paypa1`, `rnicrosoft`, Cyrillic letters, `xn--` punycode), one or two
  letters off, the known name inside another name, the known domain used as a subdomain (`salesforce.com.evil.io`), and the same name under another ending. Linking such a site needs an explicit
  confirmation, in the extension chip and in the HUD.
- **Browser extension.** `extension/` (see its README). It talks to `com.mydroid.otp`, the helper `Mydroid.app/Contents/MacOS/mydroid-nmhost`, which relays to the app.
- **`mydroid-nmhost`.** Chrome's stdio framing (u32 little-endian length plus JSON), refuses any caller whose origin isn't the fixed extension ID, forwards `code`, `list`, `link`, `status`, `autofill` and `hello`
  requests (one connection each, so a slow approval never blocks another) and starts Mydroid with `open -g -b com.mydroid.mac` if nothing is listening, retrying for 8 s.
- **The socket.** `~/Library/Application Support/Mydroid/otp.sock` (`$MYDROID_DATA_DIR/otp.sock` in developer mode, so a dev run can't take over the real app's socket), mode 0600 in a 0700 folder.
  The server checks the peer's UID, reads one JSON line and writes one JSON line (`OTPSocketServer` in `MydroidNM`, the app side in `OTPSocketService`, the logic in `OTPBridge`). A live server is never replaced.
  Requests: `{op:"code",host,account?,entryId?,client?}`, `{op:"list",host?}`, `{op:"link",host,entryId,acknowledged?}`, `{op:"status",host?}`, `{op:"autofill",host,on}`. Replies are `{ok,...}` or `{ok:false,error}`
  with `denied`, `timeout`, `no_match`, `ambiguous` (+ `choices`), `locked`, `offline`, `lookalike`, `bad_request`.
- **Settings > Authenticator.** Phone state, the import-by-camera button, one row per browser (**Chrome: Ready ✓** or **Set up…**, which opens the guided sheet below), **Extension folder › Show in Finder**, the shortcut
  (on/off, change, reset) and the list of auto-fill sites (remove one). The extension is copied to `Contents/Resources/extension` by `build-app.sh`, and from there to the stable folder below.
- **Shortcut (default Control-Option-C, configurable).** Registered through the shared `HotKeyCenter` (Carbon, no permission). It reads the front browser's address (Safari, Chrome, Edge, Brave, Arc,
  Chromium) with AppleScript, after a one-time explanation and macOS's Automation prompt; asks the phone; and types the code with `CGEvent` (Accessibility, checked before the phone is asked).
  Before typing it reads the address again: if the browser or the site changed during the approval, nothing is typed. An unknown site offers **Link to an account...** with the picker and the lookalike
  warning; several matches offer a picker. A small non-activating HUD under the menu bar shows each step (Approve on your phone, Code filled, Denied, Timed out, Locked, Not connected, ...). Pressing the shortcut
  again cancels.
- **Developer notes.** Nothing here writes into your real browser profiles during tests: the manifest writer takes a home directory and the tests use a temporary one. Unit tests cover the codec, broker (reply,
  timeout, cancel, disconnect), PSL, lookalikes, the bridge, framing, the manifest writer, the socket server (mode, peer check, concurrency, launch hook) and a real `Hub` loopback of `auth.code.get`. The shortcut
  flow is tested with fake browser, typer and HUD (`AuthShortcutFlowTests`). Renders: `MYDROID_RENDER_DIR=<dir> swift test --filter AuthenticatorRenderTests` writes `auth-settings*` and `hud-*` PNGs (light and dark).

Not verified against a real phone: the Android vault was built in parallel, so no `auth.*` message has run between this Mac app and the phone yet. Not exercised here: a real browser with the extension loaded and
Mydroid running, the AppleScript read of a live browser, and typing into one (they need a person at the machine, and the Automation and Accessibility prompts).

## Import through the camera and Continue on Mac (v1.8, PROTOCOL.md 14.4 and 15)

### Import with this Mac's camera (Settings > Authenticator > Add accounts)

Google Authenticator's export screen blocks screenshots, so the phone can't scan it; this Mac's camera can. **Import with this Mac's camera...** (enabled while the phone is connected) opens the
window "Import from Google Authenticator": a live preview, a framing guide, the steps ("In Google Authenticator: more menu, Transfer accounts, Export, hold your phone up to the camera"), and batch progress
("2 of 3 scanned"). Info.plist has `NSCameraUsageDescription` ("To read the transfer QR codes from Google Authenticator. Nothing is saved.").

- **Detection.** `QRDetector` runs Vision's `VNDetectBarcodesRequest` (QR only) on about five frames a second from an `AVCaptureSession` (the built-in camera first). It reads every QR in view; the rest is
  `ImportTracker`'s job. Only `otpauth-migration://offline?data=` and `otpauth://totp|hotp/` pass. Any other QR gets a gentle hint under the preview that fades; progress is untouched.
- **Batches.** `MigrationInfo` is a hand-written reader for the `MigrationPayload` protobuf: it takes `batch_size`, `batch_index` and `batch_id` (fields 3 to 5, int32 sign-extension handled) and only *counts*
  the account entries (field 1), skipping them by length. It never builds a value from a secret. `ImportTracker` keys parts by index within one `batch_id`: repeated frames are `duplicate` (silent), parts can come
  in any order, a code from a different export starts over ("a different export"), an out-of-range part or damaged code is `unreadable`, and a lone `otpauth://` during a half-read batch asks to finish the batch first.
  A single `otpauth://` code, or a one-part export, completes at once. Payloads over 32 KB and batches over 50 parts are refused.
- **Sending.** When the batch is whole, `CameraImportController` stops the camera, shows "Approve on your phone...", and calls `AuthBroker.importAccounts(uris:)` (`auth.import {req, uris}`; waits up to 120 s for
  `auth.import.result`, because someone has to unlock and tap Add). The tracker has already cleared itself; the controller keeps no copy; the broker's waiter holds only the request id. Success reads "Added N
  accounts on your phone. Nothing was saved on this Mac." (with "N were already there" when the phone skipped some); `cancelled`, `locked`, `invalid`, a dropped link and a timeout each have their own copy and a **Scan Again**.
- **Camera lifetime.** The camera starts when the window appears and stops the moment a batch is complete, on an error, when the phone disconnects, and when the window closes (`closeCameraImport`). A closed window
  ignores a late answer. Camera permission has its own states: asking, denied (**Open Privacy Settings**), no camera.
- **Privacy.** Nothing is written to disk and nothing is logged on this path (no URIs, accounts or counts). Frames go to Vision and are dropped; no frame is kept or cached. Swift strings can't be zeroed, so the
  Mac holds the minimum for the shortest time and drops every reference.
- **Tests.** `V18Tests` (Core): synthetic migration payloads (escaped, unescaped and URL-safe base64, negative ids, unknown fields, truncated and endless varints), the tracker (out-of-order parts, repeats,
  restarts, bad indices), the broker (reply, each error, timeout, disconnect, cancel, stray replies) and a `Hub` loopback of `auth.import`. `V18AppTests`: the real Vision detector on QR images made with `CIQRCodeGenerator`
  (single, a 10-account migration code, a whole 3-part export, a non-QR picture, a non-Authenticator QR), and the controller against a fake camera and importer (permission, no camera, offline, progress,
  camera stops at completion, errors, closing). No camera is ever turned on and no `auth.import` leaves the machine.

### Continue on Mac (Now Playing row)

- **`mediaId`.** `media.state` may carry `mediaId` (sent when the track changes, so the Hub keeps it while the track is unchanged, like the art). `MediaRef` applies the 13.1 filter: only `spotify:track:<22 base62>`,
  `spotify:episode:<22 base62>` or http(s). A link to open.spotify.com is treated as the same item as its URI. Anything else is dropped, so the row falls back to Search on web.
- **The button.** The Now Playing row in the popover shows **Continue on Mac** when there is a valid `mediaId`, otherwise **Search on web** (Google, "title artist"). The full window doesn't show media today, so there is
  nothing to add there.
- **Spotify for Mac** (`com.spotify.client`, found with LaunchServices): `ContinueOnMac.spotifyScript` builds `tell application id "com.spotify.client"`, `play track "<uri>"`, then waits for the player to start and
  `set player position to <seconds>`. The position is `position` at `ts` plus the time since while playing, held when paused, clamped to the duration, to a tenth of a second and always printed with a dot. The URI
  must be exactly a canonical `spotify:track|episode:<22 base62>` or no script is built at all (nothing else can reach AppleScript); `appleScriptEscape` is a second layer. A Spotify that isn't running is launched
  first. The first time, an alert explains that macOS will ask about Automation for Spotify (**Continue** or **Open in Browser Instead**; remembered in `MacPrefs.spotifyAutomationExplained`). If Automation is off or
  Spotify fails, the item opens on open.spotify.com and the toast says how to fix it.
- **Otherwise** it opens `https://open.spotify.com/track|episode/<id>` (or the item's own link). **Then** it sends `media.cmd pause` to the phone, unless **Pause my phone when continuing on Mac** (Settings > Media,
  `MacPrefs.pausePhoneOnContinue`, default on) is off. If nothing could be opened the phone is left playing; Search on web never pauses.
- **Structure and tests.** `MediaHandoff` (app) takes `SpotifyPlaying`, `MacOpener`, the explainer and the pause as parameters, so tests use fakes and never run AppleScript or touch Spotify. Tests cover URI to URL mapping
  and rejection of injection attempts, position extrapolation, script text and escaping, the search URL, and every branch of the handoff (installed, not installed, first-time explainer accepted and declined, Automation
  refused, open failure, pause on and off, no `mediaId`).
- **Renders.** `MYDROID_RENDER_DIR=<dir> swift test --filter V18RenderTests` writes `import-*` (guide, progress, hint, approve, success, errors, offline, camera denied), `nowplaying-*` (Continue on Mac, Search on
  web), `settings-media` and `settings-auth-import` PNGs, light and dark. The preview in the import renders is a drawn still, not a camera.

Not verified: the real camera and its permission prompt, Vision on a live Google Authenticator screen (glare, moire and distance matter), and Spotify for Mac itself (the Automation prompt, `play track` right after
launch, and `set player position` timing). The Android side of `auth.import` and `mediaId` was built in parallel and hasn't talked to this Mac yet.

## v1.9: Settings you can find, a mirrored camera, a guided extension setup

- **Settings is always visible.** The popover header has a gear button (top right, next to the battery; ⌘, while the popover is key), replacing the old "⋯" menu. Its footer keeps **Open Mydroid** and a small **Quit Mydroid** (⌘Q).
  The full window has **Settings** at the bottom of the sidebar (above the phone card) and a gear in the toolbar; **⌘,** works from the main window (`CommandGroup(replacing: .appSettings)`). **Pair a different phone…** moved to
  Settings › Phone, and **Quit Mydroid** is also in Settings › General. Nothing primary is behind a hidden menu. The `MainDetailView` `minHeight: 0` guard and `fitMenuBarWindow()` are unchanged.
- **The import camera is a mirror.** `CameraPreview` sets `AVCaptureVideoPreviewLayer.connection.automaticallyAdjustsVideoMirroring = false` and `isVideoMirrored = true` (re-applied when the session starts, because the
  connection only exists then). The framing guide is mirrored with it. Only the preview is flipped: the video data output's connection is explicitly unmirrored, so Vision keeps reading raw frames
  (`testPreviewIsMirroredAndDetectionStillReadsTheRawImage`; the import renders show the mock frame mirrored).
- **Stable extension folder.** At every launch `ExtensionInstaller` copies the bundled extension to `~/Library/Application Support/Mydroid/Browser Extension/` (`ExtensionFolder.sync`): created when missing, replaced when the
  bundled `manifest.json` version is newer (or the same version with different files, which helps development builds), never downgraded; `test/` and dotfiles are left out and the manifest is written last. Browsers load
  from there, never from the app bundle or Downloads.
- **Guided setup sheet** (`ExtensionSetupView.swift`): "Set up Fill from phone in <Browser>", one browser at a time, numbered steps with one short line each. 1 **Connect Mydroid to <Browser>** runs by itself (writes the native
  messaging manifest). 2 **Open <Browser>'s Extensions page** runs `open -a "<app>" chrome://extensions` (`edge://`, `brave://`; Arc also takes `chrome://`); if that fails it brings the browser forward and copies the address,
  with "Paste in the address bar (⌘V)". 3 **Turn on "Developer mode"** shows a tiny drawing of the toggle in the page's top-right corner. 4 **Add Mydroid** offers a **draggable folder tile** (an `NSItemProvider` of the stable
  folder's file URL: drop it on the Extensions page) or, as the fallback, "click Load unpacked, press ⌘⇧G and paste" with **Copy path** and **Show in Finder**. 5 is automatic: the extension sends `hello` through native messaging
  on install and on browser start, `OTPBridge` hands it to `OTPSocketService`, and `ExtensionInstaller.markSeen` flips the sheet to "Fill from phone is ready in <Browser> ✓". Which browser said hello comes from the helper's parent process
  (`ChromiumBrowser.from(executablePath:)`, so Arc isn't taken for Chrome), then from the name the extension reports. A hello never launches Mydroid. "Ready" is remembered (`extensionSeen` in the app's defaults) and shown in Settings.
  Chrome blocks self-hosted extension installs on macOS, so a dev-mode "Load unpacked" is the best a self-distributed app can do. **The real one-click path for end users is publishing the extension to the Chrome Web Store (and Edge Add-ons);
  the fixed extension ID keeps the native messaging manifest valid there too.** Until then this guided flow stays.
- **Compact HUD.** The ⌃⌥C panel is 340 pt wide with a short title and at most one short line per state ("Approve on your phone…", "Filled ✓", "Denied", "Timed out", "No account for <site>").
- **Tests and renders.** `ExtensionSetupTests` (Core: folder sync, version order, browser detection, the `hello` op) and `SetupFlowTests` (the setup model and its steps, hello flow, mirrored preview, and renders): `MYDROID_RENDER_DIR=<dir> swift test --filter SetupFlowTests`
  writes `setup-*` (each step, the paste fallback, done), `settings-authenticator-browsers` and `popover-header-gear-*`. Every home in these tests is a temporary folder; no real browser profile is touched.
