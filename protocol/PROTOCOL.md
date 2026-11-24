# Mydroid wire protocol v1

The Mac app is the **server**. The Android phone is the **client** and always dials the Mac.
One Mac pairs with one phone in v1 (pairing again replaces the old phone).

Both implementations MUST pass `protocol/test-vectors.json`. If this document and the vectors disagree, the vectors win.

## 1. Discovery and transport

- TCP. Mac listens on port **47820**; if taken, any free port.
- Mac advertises Bonjour `_mydroid._tcp` with TXT records `id=<macId>` and `v=1`.
- Phone finds the Mac by, in order, Bonjour discovery (Android `NsdManager`) matched on `id`, then the last address that worked, then every address from the QR code. Try candidates in parallel and keep the first that completes the handshake.
- Reconnect backoff on the phone is 1s, 2s, 4s … capped at 30s. Reset it and retry right away when the network changes (`ConnectivityManager.NetworkCallback`).
- Heartbeat: the phone sends `ping` every 20s. Either side drops the connection after 60s with no frames received.
- Reconnect replaces an existing connection from the same phone: the Mac closes the old socket.

## 2. Pairing QR

The Mac generates a fresh 32-byte random pairing secret `S` and shows a QR code that encodes:

```
mydroid://pair?v=1&mac=<macId>&n=<url-encoded Mac name>&s=<base64url(S), no padding>&a=<ip:port>,<ip:port>
```

- `macId` is a UUID string the Mac generates once and stores.
- `a` lists IPv4 addresses (and optionally IPv6 in brackets, `[fe80::1%en0]:47820`) of active non-loopback interfaces.
- The QR expires after 10 minutes or after one successful pairing, whichever comes first. The Mac then shows a new one.

## 3. Keys

All key derivation is HKDF-SHA256 (RFC 5869). Info strings are UTF-8, without terminators.

| Key | Derivation |
|---|---|
| `LTK` (32 bytes, long-term, stored in Keychain or Android Keystore-wrapped storage) | HKDF(ikm=`S`, salt=empty, info=`"mydroid v1 ltk"`, L=32) |
| Session keys (64 bytes) | HKDF(ikm=`LTK`, salt=`nonceC ‖ nonceS`, info=`"mydroid v1 session"`, L=64). `c2sKey` = bytes 0–31, `s2cKey` = bytes 32–63 |
| Confirm code | HKDF(ikm=`LTK`, salt=`nonceC ‖ nonceS`, info=`"mydroid v1 confirm"`, L=4) read as a big-endian u32, mod 1 000 000, zero-padded to 6 digits. Display it as `"181 734"`. |

The secret `S` is discarded once `LTK` is derived. Only `LTK` is stored.

## 4. Framing

Every frame on the wire is `u32 big-endian length` followed by that many bytes. Frames larger than 1 MiB are a protocol error that closes the connection.

### 4.1 Handshake (plaintext frames)

1. Client → server: UTF-8 JSON
   `{"t":"hello","v":1,"phone":"<phoneId>","mac":"<macId>","nonce":"<base64 16 bytes>","pairing":true|false}`
   - `phoneId` is a UUID the phone generates once.
   - `pairing:true` is used only right after scanning the QR. The server then uses the `LTK` derived from the QR currently on screen.
   - `pairing:false` requires that `phoneId` is the paired phone. Otherwise the server closes the connection.
2. Server → client: `{"t":"hello","v":1,"mac":"<macId>","nonce":"<base64 16 bytes>"}`
3. Both sides derive the session keys. Every frame after this point is encrypted.

### 4.2 Encrypted frames

Frame body = `nonce (12 bytes) ‖ AES-256-GCM ciphertext ‖ tag (16 bytes)`. There is no AAD.

- nonce = 4 zero bytes ‖ u64 big-endian counter. Each direction has its own counter, starting at 0 and incrementing by 1 per frame.
- Client → server uses `c2sKey`. Server → client uses `s2cKey`.
- The receiver requires the counter to equal the next expected value. A decryption failure or counter mismatch closes the connection.
- In `test-vectors.json`, `frame` is the frame body without the u32 length prefix.

### 4.3 Message encoding (the plaintext inside an encrypted frame)

`u32 big-endian H` ‖ `H bytes of UTF-8 JSON header` ‖ optional binary payload (the rest of the plaintext).

Every header has `"t"`, the message type. Receivers ignore unknown fields and log and ignore unknown types, so newer versions can add messages.

### 4.4 Session start

1. Client → `auth` `{"t":"auth","name":"Pixel 9","model":"Pixel 9","android":35}`. A frame that decrypts proves the client holds `LTK`.
2. Server → `welcome` `{"t":"welcome","name":"<Mac name>"}`
3. When `pairing:true`, both sides show the confirm code. When the user clicks **Codes match** on the Mac, the server sends `pair.confirmed {}` and stores `phoneId` and `LTK`. The phone stores `macId`, `LTK`, the Mac name and the addresses only after it receives `pair.confirmed`. When the user clicks **Scan again**, the server sends `pair.rejected {}` and closes the connection.
4. After `welcome` on a normal reconnect, or after `pair.confirmed`, the client sends `device.status`, `feature.status` and `notif.snapshot`. The server sends `settings`.

## 5. Messages

**P→M** is phone to Mac. **M→P** is Mac to phone. **↔** goes both ways.

### Liveness and device

| type | dir | fields |
|---|---|---|
| `ping` | ↔ | `{}`. Answer with `pong {}`. |
| `pong` | ↔ | `{}` |
| `device.status` | P→M | `battery` int 0–100, `charging` bool, `network` `"wifi"`/`"cellular"`/`"none"`, `name`, `model`. Send on connect and whenever battery changes by 1% or more, or charging or network changes. |
| `settings` | M→P | `notifications`, `photos`, `calls`, `clipboard`, all bool. These are the features the user chose on the Mac. The phone prompts for the matching Android permission in context. |
| `feature.status` | P→M | For each feature `notifications`, `photos`, `calls`, `clipboard`: `"on"`, `"off"` or `"needs_permission"`. Also `backgroundRestricted` bool (true when battery optimization applies to Mydroid). Send on connect and whenever any value changes. |
| `fix.open` | M→P | `{"what":"notifications"\|"photos"\|"calls"\|"background"}`. The phone posts a notification that opens the right Android settings screen. |
| `find.ring` | M→P | `{}`. The phone rings at full volume, even on silent, until the user taps Stop or the Mac sends `find.stop {}`. |
| `bye` | ↔ | `{}`. Graceful close, for example when the Mac quits. |
| `unpair` | ↔ | `{}`. Forget the pairing. The receiver deletes its stored keys and closes the connection. |

### Notifications

| type | dir | fields |
|---|---|---|
| `notif.posted` | P→M | `key` (the Android `StatusBarNotification.key`), `pkg`, `app` (display name), `title`, `text`, `when` (ms epoch), `canReply` bool, `actions` `[{"index":int,"title":string}]` (not including the reply action), `icon` (optional base64 PNG, ≤ 96 px). Posting the same `key` again updates the notification. |
| `notif.removed` | P→M | `key` |
| `notif.snapshot` | P→M | `items`: an array of `notif.posted` bodies (without `t`). The Mac replaces its whole list with it. |
| `notif.reply` | M→P | `key`, `text`. The phone fires the RemoteInput and replies `notif.result {key, ok, error?}`. |
| `notif.action` | M→P | `key`, `index`. The phone fires that action's PendingIntent and replies `notif.result`. |
| `notif.dismiss` | M→P | `key`. The phone cancels the notification on Android. |
| `notif.result` | P→M | `key`, `ok` bool, `error` optional string |

The phone skips ongoing, group-summary, media-session and its own notifications.

#### 5.1 Rich notification fields (added in v1.1, all optional, older peers ignore them)

`notif.posted` (and each `notif.snapshot` item) may also carry:

| field | meaning |
|---|---|
| `app` | MUST be the human app label ("WhatsApp", "Messages"), never the package name. Fall back to the package name only if the label truly can't be read. |
| `category` | `"message"` for person-to-person messages: `Notification.MessagingStyle`, `CATEGORY_MESSAGE`, or any notification from the default SMS app. `"other"` for everything else. |
| `conversation` | Only for `category:"message"`: `{"title": string, "isGroup": bool, "messages": [{"sender": string, "text": string, "when": ms}], "avatar": optional base64 PNG ≤ 128 px}`. `title` is the person or group name. `messages` holds the last ≤ 5 messages, oldest first. `sender` is `""` for messages the user sent. `avatar` is the sender's person icon or large icon, and the group icon for groups. |
| `otp` | Present when the notification contains a one-time code: `{"code": "482196", "source": "HDFC Bank"}`. `code` keeps the original characters with spaces and dashes removed. `source` is the sender, the conversation title or the app label. |

The Mac shows `category:"message"` notifications as conversations in a **Messages** section, separate from app notifications. It shows `otp` as a prominent code card with a one-click **Copy** action.

#### 5.2 Heartbeat (v1.1, replaces the §1 timings)

The phone sends `ping` every **25s while the screen is on** and every **90s while it is off**. Either side drops the connection after **240s** with no frames received. The phone also enables TCP keepalive.

### Calls

| type | dir | fields |
|---|---|---|
| `call.state` | P→M | `callId` string, `state` `"ringing"`/`"active"`/`"ended"`, `incoming` bool, `number` optional, `name` optional (contact name) |
| `call.action` | M→P | `callId`, `action` `"answer"`/`"decline"`/`"end"`/`"mute"`/`"unmute"`. v1 answers on the phone and the audio stays on the phone. The Mac UI must say so. |

### Clipboard

| type | dir | fields |
|---|---|---|
| `clip.set` | ↔ | `text` (≤ 1 MiB UTF-8). Sent only when the clipboard feature is on. The receiver writes it to its clipboard. |

### Transfers (photos and files, both directions)

The sender offers a file, the receiver accepts or skips it, the sender streams chunks, and the receiver acknowledges.

| type | dir | fields |
|---|---|---|
| `xfer.offer` | sender → receiver | `xid`, `kind` `"photo"`/`"file"`, `name`, `size` (bytes), `mime`, `taken` (ms epoch, photos only, optional) |
| `xfer.accept` | receiver → sender | `xid`, `offset`. Start (or resume) at this byte. The receiver keeps partial files as `<name>.part` and sets offset to the partial size. |
| `xfer.skip` | receiver → sender | `xid`. The receiver already has this file (dedupe ledger), so the sender marks it done. |
| `xfer.chunk` | sender → receiver | `xid`, `offset`, with the payload bytes (≤ 256 KiB) |
| `xfer.end` | sender → receiver | `xid`, `sha256` (lowercase hex of the whole file) |
| `xfer.done` | receiver → sender | `xid`, `ok` bool, `error` optional. On success the receiver records `xid` in its ledger. |
| `xfer.cancel` | ↔ | `xid` |

- Photo `xid` = `"photo:<MediaStore _ID>:<DATE_MODIFIED seconds>"`. It is stable across reconnects, so the Mac's ledger prevents duplicates.
- File `xid` = `"file:<uuid>"`.
- The phone keeps a durable queue of photos not yet marked done (`xfer.done ok` or `xfer.skip`) and offers them one at a time after every connect. The phone sends original bytes (`MediaStore.setRequireOriginal` when it has `ACCESS_MEDIA_LOCATION`).
- The Mac saves photos to `~/Pictures/Mydroid/` and files to `~/Downloads/`. If a name already exists, it adds ` (2)`, ` (3)` and so on. The phone saves files to `Download/Mydroid/` through MediaStore.

## 6. Interop smoke scenario

Both sides ship a headless test driver: the Mac `mydroid-test-server` (Swift) and the phone `simulator` (Kotlin/JVM, sharing the Android `:protocol` module). Running them against each other MUST end with both printing `SMOKE OK` and exiting with status 0 within 60s. Each driver prints one line per step, for example `STEP 3 ok`. A driver that fails prints `SMOKE FAIL <reason>` and exits with status 1.

```
server: mydroid-test-server --data <dir> [--port 47820]
        prints  PAIR_URL <url>        (one line, as soon as it is listening)
sim:    simulator smoke --url <url> --state <dir> --photo <file> --photo2 <file>
```

1. The server starts, prints `PAIR_URL`, and waits.
2. The sim connects with `pairing:true`. Both print `CONFIRM <6 digits>`. The server auto-sends `pair.confirmed`. The sim stores its state, sends `bye`, and closes.
3. The sim reconnects with `pairing:false` and the stored LTK, then sends `auth`, `device.status` (battery 78, wifi), `feature.status` (all `"on"`, `backgroundRestricted:false`) and `notif.snapshot` (empty). The server sends `settings` with every feature true.
4. The sim sends `notif.posted` with `key:"k1"`, app `"Messages"`, title `"Maya Tan"`, text `"Are we still on for coffee?"` and `canReply:true`. The server answers `notif.reply {key:"k1", text:"On my way"}`. The sim checks the text and sends `notif.result ok` and `notif.removed k1`.
5. The sim offers `--photo` as `xid "photo:1:100"`. The server accepts at offset 0. The sim streams it in 256 KiB chunks and sends `xfer.end` with the sha256. The server checks it, writes the file to `<data>/Pictures/` and sends `xfer.done ok`.
6. The sim offers `--photo2` as `xid "photo:2:100"`, sends exactly one 256 KiB chunk, then drops the TCP connection without sending `bye`. It reconnects with `pairing:false` and offers `photo:2:100` again. The server MUST answer `xfer.accept` with `offset` = 262144. The sim finishes and gets `xfer.done ok`.
7. The sim offers `photo:1:100` again. The server MUST answer `xfer.skip`.
8. The server sends a file transfer: `xid "file:<uuid>"`, name `hello.txt`, content `"hello from mac\n"`. The sim accepts, verifies the sha256, and sends `xfer.done ok`.
9. The sim sends `clip.set "hello from phone"`. The server checks it and sends `clip.set "hello from mac"`. The sim checks it.
10. The server sends `ping`. The sim answers `pong`. The sim sends `bye`. Both print `SMOKE OK` and exit 0.

The photo files can be any binary files of at least 600 KB. The integration run generates them with `head -c 1500000 /dev/urandom`.

## 7. v1.2 additions

All of these are optional and additive. A peer that doesn't know a type logs it and ignores it (§4.3).

### 7.1 Bluetooth LE presence

The Mac advertises a BLE service so the phone knows, at almost no battery cost, when the Mac is nearby and awake. BLE carries **no data** in v1.2. It is only a presence signal. Wi‑Fi TCP stays the only data channel.

- **Service UUID**, unique per pairing: `raw = HKDF-SHA256(ikm=LTK, salt=empty, info="mydroid v1 ble uuid", L=16)`. Set `raw[6] = (raw[6] & 0x0f) | 0x40` and `raw[8] = (raw[8] & 0x3f) | 0x80` (RFC 4122 v4 bits), then format it as a UUID. See `bleUuid` in `test-vectors.json`.
- **Mac:** a `CBPeripheralManager` advertises only that service UUID (macOS allows only the local name and service UUIDs in an advertisement), whenever a phone is paired and Bluetooth is on. It needs no characteristics. It stops advertising when unpaired. When the Mac sleeps, advertising stops, which is the right "Mac went away" signal.
- **Phone:**
  - Creates a `CompanionDeviceManager` association using a BLE filter on that UUID. The user makes one tap in the system dialog during setup.
  - Registers a hardware-filtered, low-power, `PendingIntent`-based `BluetoothLeScanner` scan on the UUID, with `CALLBACK_TYPE_FIRST_MATCH | CALLBACK_TYPE_MATCH_LOST`.
  - **Mac found** → connect over Wi‑Fi now.
  - **Mac lost**, and the TCP session is gone for 2 min or more → stop the foreground service and stop every retry until the Mac is found again, a Wi‑Fi network appears, the user unlocks the phone, or the app opens.

### 7.2 Settings v2 (M→P `settings`, extra fields)

| field | meaning |
|---|---|
| `mutedApps` | An array of package names. The phone does **not** forward notifications from them at all, which saves battery. |
| `screenshots` | bool, default true. Sync screenshots along with camera photos. |
| `pauseBelowBattery` | int or null. While the phone's battery is below this percentage and not charging, pause photo sync. Notifications, calls and codes keep flowing. |
| `smsHistory` | bool. Allows the `sms.*` requests (§7.5). |
| `media` | bool. Send `media.state` (§7.3). |

`feature.status` may carry `clipboardMode`: `"tap"` (the default) or `"instant"`. In `"tap"` mode, phone→Mac clips are sent when the user taps **Send to Mac** in the text-selection menu, the notification button, the tile or the share sheet. `"instant"` is the opt-in accessibility mode. Android 10+ lets only the focused app or the default keyboard read the clipboard, so there is no automatic path without accessibility.

A phone that receives a `clip.set`-worthy clip marked sensitive (`ClipDescription.EXTRA_IS_SENSITIVE`) never sends it. The Mac never sends pasteboard items of type `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType`.

### 7.3 Now playing

| type | dir | fields |
|---|---|---|
| `media.state` | P→M | `active` bool. When true: `pkg`, `app`, `title`, `artist`, `album`, `art` (optional base64 JPEG ≤ 256 px, sent only when the track changes), `playing` bool, `position` ms, `duration` ms, `ts` ms epoch (the moment `position` was sampled), `canSeek`, `canNext`, `canPrev`. Send it on change only, never on a timer. The Mac extrapolates the position. |
| `media.cmd` | M→P | `action`: `"play"`, `"pause"`, `"toggle"`, `"next"`, `"prev"` or `"seek"`, plus `position` ms for seek. |

### 7.4 Links and "send to phone"

| type | dir | fields |
|---|---|---|
| `link.open` | ↔ | `url` (http, https or mailto only). The Mac opens it in the default browser, or shows a banner, depending on its setting. The phone opens it with `ACTION_VIEW`. A CDM-associated app may start activities from the background; otherwise the phone posts a tap-to-open notification. |

Files and text from the Mac's Services menu or URL scheme reuse `xfer.*` and `clip.set`.

### 7.5 SMS history and sending (requires `settings.smsHistory`)

| type | dir | fields |
|---|---|---|
| `sms.threads.get` | M→P | `limit` (default 50), `before` (optional ms; for paging by date) |
| `sms.threads` | P→M | `threads`: `[{threadId, addresses:[string], name, snippet, date, unread:int, avatar?}]`, newest first. `name` is the contact name or the formatted number. `avatar` is a base64 PNG ≤ 128 px contact photo. |
| `sms.messages.get` | M→P | `threadId`, `limit` (default 50), `before` (optional ms) |
| `sms.messages` | P→M | `threadId`, `messages`: `[{id, from, body, date, out:bool, status:"received"/"sent"/"pending"/"failed", mms?:bool}]`, oldest first. For MMS in v1.2, `body` may be `"[Photo]"`. |
| `sms.send` | M→P | `clientId`, `to:[string]`, `text`, `threadId` (optional) |
| `sms.sent` | P→M | `clientId`, `ok`, `error` (optional), `threadId` |
| `sms.changed` | P→M | `threadId`. A thread changed (a new incoming or outgoing message). The Mac refetches if it's showing that thread. Debounce to 1 per second per thread. |

The phone answers `sms.*` with `{"t":"sms.error","error":"permission"}` when it lacks `READ_SMS` or `SEND_SMS`.

### 7.6 Read sync

- `notif.posted` gains `markRead: bool`. It is true when the notification has an action with `SEMANTIC_ACTION_MARK_AS_READ`, or a title matching "Mark as read".
- M→P `notif.read {key}`. When the user reads a conversation on the Mac (opens it in the app, expands it in the popover, or replies), the phone fires the mark-as-read action if there is one. Otherwise it cancels the notification. The phone then sends `notif.removed` as usual.
- Read on the phone → the notification disappears → `notif.removed` → the Mac removes it. This already works.

### 7.7 Photo library browsing

| type | dir | fields |
|---|---|---|
| `photos.list` | M→P | `limit` (default 60), `before` (optional ms `DATE_TAKEN`/`DATE_ADDED`), `album` (optional: `"camera"`, `"screenshots"` or `"all"`; default `"all"`) |
| `photos.page` | P→M | `items`: `[{id, name, taken, w, h, size, mime, album}]` newest first, plus `more` bool. Metadata only. |
| `photos.thumbs.get` | M→P | `ids`: up to 30 |
| `photos.thumb` | P→M | `id`. The payload is a JPEG of about 256 px on the long edge. One message per id. |
| `photos.get` | M→P | `id`. The phone sends the original with `xfer.offer` `kind:"photo"`, `xid:"lib:<id>"`. The Mac stores library downloads in its cache, not in the auto-sync folder, unless the user saves them. |

### 7.8 Calls history and dialing

| type | dir | fields |
|---|---|---|
| `calls.list` | M→P | `limit` (default 100) |
| `calls.page` | P→M | `items`: `[{number, name, kind:"in"/"out"/"missed"/"rejected", date, duration}]` newest first |
| `call.dial` | M→P | `number`. The phone places the call (`CALL_PHONE`), and the audio is on the phone. |

### 7.9 Phone health

`device.status` gains `lowPowerMode` bool (Android battery saver). On its first report below 20% and not charging, the Mac shows a single "Pixel 9 battery is low (18%)" banner.

## 8. Mac call audio (v1.3)

This is an optional feature, never part of the main setup. After setup, the Mac shows a dismissible **"Hear calls on your Mac"** card in the popover. It is always available in Settings › Calls.

### 8.1 Capability tiers (probed on the phone, shown honestly on the Mac)

| tier | condition | the Mac offers |
|---|---|---|
| `full` | `AudioManager.isPstnCallAudioInterceptable()` is true, and the helper can create both the downlink-extraction `AudioRecord` and the uplink-injection `AudioTrack` during a call | Audio switch **Phone · Mac**: hear and talk on the Mac. Talk is labelled "Experimental" until the user confirms it once. |
| `listen` | interception is not supported, but `AudioSource.VOICE_CALL` / `VOICE_DOWNLINK` capture works for the shell | **Listen on Mac** (the user still talks into the phone) |
| `none` | neither works, or wireless debugging is unavailable | Controls only (answer, decline, end, mute). The card explains why, in one sentence. |

### 8.2 Setup (Mac-driven, one time)

1. The Mac uses an existing `adb` installation.
2. **Developer options:** the Mac sends `fix.open {what:"devoptions"}`. The phone opens Developer options, or About phone with "Tap Build number 7 times" when they're locked.
3. **QR pairing:** the Mac shows an ADB pairing QR, `WIFI:T:ADB;S:<service>;P:<password>;;`. The user picks **Wireless debugging › Pair device with QR code** and scans it. The Mac finds `_adb-tls-pairing._tcp` with name `<service>`, then runs `adb pair` and `adb connect` (`_adb-tls-connect._tcp`).
4. **Verify it's the paired phone:** the Mac sends `adb.verify {nonce}` over the Mydroid link. The phone writes the nonce to `/sdcard/Android/data/<package>/files/adb-verify`, and the Mac reads it with `adb shell cat`. The Mac checks `com.whiteboxxai.mydroid` and the legacy `com.mydroid.android` and uses the package that returns the matching nonce.
5. **Keep-alive grant:** `adb shell pm grant <package> android.permission.WRITE_SECURE_SETTINGS` targets the verified package. The phone then keeps `Settings.Global "adb_wifi_enabled"=1` on boot and on Wi‑Fi connect, while call audio is enabled. On a network Android hasn't trusted yet, Android may ask once.
6. **Disable:** `adb disconnect`, revoke the grant, and the phone stops the keep-alive. The card explains that Developer options can now be turned off again.

### 8.3 The helper

The helper is a class inside the installed APK (`com.mydroid.callbridge.Main`). The Mac starts it as the shell user:
`adb shell CLASSPATH=$(pm path <package> | cut -d: -f2) app_process / com.mydroid.callbridge.Main`, using the package verified in §8.2.
It needs no separate push, and its version always matches the app.

- **Control:** JSON lines over the adb shell's stdin and stdout.
  - Mac → helper: `{"cmd":"hello","macHost":...,"udpPort":...,"key":"<b64 32>"}`, `{"cmd":"route","to":"mac"|"phone"}`, `{"cmd":"quit"}`
  - Helper → Mac: `{"ev":"tier","tier":"full|listen|none"}`, `{"ev":"call","inCall":bool}`, `{"ev":"routed","to":...,"error"?}`, `{"ev":"stats","rxRms":..,"txRms":..,"lost":..}`
  - Stats carry levels only. Never record or store call audio.
- **Audio:** UDP, 20 ms frames, PCM16 mono at 16 kHz (640 bytes per frame).
  - Packet layout: `u32 seq ‖ AES-256-GCM(key, nonce = 4 zero bytes ‖ u64 seq, frame)`. Each direction has its own key, derived as `HKDF(key, info="mydroid audio down"|"mydroid audio up")`.
  - The helper sends downlink from its UDP socket to `macHost:udpPort`. The Mac sends uplink back to the source address of the downlink packets.
- **Mac:** a jitter buffer of about 60 ms that drops late frames and conceals losses with silence or repetition. Playback and capture use `AVAudioEngine` with `inputNode.setVoiceProcessingEnabled(true)` for echo cancellation, on the default devices or the user's choice.
- **Routing back to the phone or ending the call:** the helper releases both tracks immediately.

## 9. Mac files on the phone (v1.4)

The Mac shares folders the user picks (by default Desktop, Documents and Downloads). The phone exposes them through an Android `DocumentsProvider`, so the Mac shows up in Android's own Files app and in every system file picker. Shares are read-only unless the user turns on "Allow saving to this Mac".

| type | dir | fields |
|---|---|---|
| `fs.roots` | P→M | `req` |
| `fs.roots.result` | M→P | `req`, `roots`: `[{id, name, writable:bool}]`, `macName`. An empty `roots` list means file sharing is off. |
| `fs.list` | P→M | `req`, `root`, `path` (relative, `""` = the root itself) |
| `fs.list.result` | M→P | `req`, `items`: `[{name, dir:bool, size, mtime (ms), mime}]` or `error` (`"not_found"`, `"denied"`, `"off"`). Hidden files are excluded. |
| `fs.thumb` | P→M | `req`, `root`, `path` |
| `fs.thumb.result` | M→P | `req`, `ok`. The payload is a JPEG of about 256 px (QuickLook), present only when `ok`. |
| `fs.get` | P→M | `req`, `root`, `path`. The Mac replies by sending the file with `xfer.offer kind:"file" xid:"fs:<req>"`, or with `fs.error {req, error}` if it can't. |
| `fs.put` | P→M | `req`, `root`, `path` (the target folder), `name`, `size`. Allowed only when `writable` is true. The Mac answers `fs.put.ready {req}` or `fs.error`, and the phone then sends `xfer.offer xid:"fsput:<req>"`. The Mac saves into that folder, adding ` (2)` and so on when a name is taken. |
| `fs.search` | P→M | `req`, `query`. Spotlight search across the shared roots, at most 50 results. |
| `fs.recent` | P→M | `req`. Recently used files in the shared roots (Spotlight `kMDItemLastUsedDate`), at most 30. |
| `fs.search.result` | M→P | `req`, `items`: `[{root, path, name, dir, size, mtime, mime}]`. Used for both search and recent. |
| `fs.error` | M→P | `req`, `error` |

**Security:**
- The Mac resolves `root + path` and rejects any result outside the root: `..`, absolute paths, and symlinks that point outside the root are all rejected.
- Every request is checked against the current share settings. Writes happen only when the root is writable.
- Requests from the phone are served only over the authenticated Mydroid session.

## 10. Remote: trackpad, keyboard, presenter, media (v1.5)

Input travels over the normal session. Both sides MUST set TCP_NODELAY. The phone coalesces pointer moves to at most 120 messages per second, and scroll to at most 60. The Mac posts events with `CGEvent`, which needs macOS **Accessibility** permission. The Mac asks for it the first time Remote is used, never during setup.

| type | dir | fields |
|---|---|---|
| `in.move` | P→M | `dx`, `dy`: floats in points, already accelerated by the phone |
| `in.scroll` | P→M | `dx`, `dy`: floats in pixels (two-finger scroll), plus optional `phase`: `"began"`, `"changed"`, `"ended"` or `"momentum"` |
| `in.click` | P→M | `button`: `"left"`, `"right"` or `"middle"`, plus `count` (1 or 2) |
| `in.down` / `in.up` | P→M | `button`, used for drag (tap-and-hold, then move) |
| `in.key` | P→M | `key`: `left right up down enter escape space tab backspace delete home end pageup pagedown f1`…`f12`, or a single character. `mods`: an array of `"cmd"`, `"shift"`, `"option"`, `"ctrl"`. |
| `in.text` | P→M | `text`, typed as Unicode (CGEvent unicode string, in chunks of ≤ 20 characters) |
| `in.media` | P→M | `action`: `playpause`, `next`, `prev`, `volup`, `voldown` or `mute` (system media keys) |
| `in.laser` | P→M | `on` bool, plus `x` and `y` (0…1, normalised over the main display). The Mac draws a soft red spotlight overlay that ignores mouse events. |
| `remote.state` | M→P | `accessibility` bool, `presenting`: `{app}` or null. Sent on connect and on change. |
| `remote.ask` | P→M | `{}`. The phone opened Remote and the Mac lacks Accessibility, so the Mac shows its prompt to allow it. |

**Presenting:**
- The Mac detects a slideshow: Keynote playing, PowerPoint in slide show, Preview or any app full-screen with "Slideshow" or "Slide Show" in its window title, or Google Slides / PowerPoint Online presenting full-screen in a browser.
- The Mac sends `remote.state.presenting`. The phone posts a quiet notification, "Presenting on your Mac? Tap for clicker".
- Next and Previous are `in.key right` and `in.key left`.

## 11. Quick actions and Mac status (v1.5)

| type | dir | fields |
|---|---|---|
| `mac.action` | P→M | `req`, `action`: `"lock"`, `"sleep"`, `"displaysleep"`, `"ring"`, `"ringstop"` or `"shortcut"`, plus `name` (for shortcut) |
| `mac.result` | M→P | `req`, `ok`, `error` (optional) |
| `mac.shortcuts.get` | P→M | `req` |
| `mac.shortcuts` | M→P | `req`, `items`: `[name]` from `/usr/bin/shortcuts list`, or `error` |
| `mac.status` | M→P | `name`, `model`, `battery` (int or null on desktops), `charging`, `locked`, `displayAsleep`. Sent on connect and on change, never on a timer. |

- **Lock:** post ⌃⌘Q via CGEvent (needs Accessibility). Without Accessibility, fall back to `pmset displaysleepnow`, which locks when "require password after sleep" is immediate, and report that.
- **Sleep:** `pmset sleepnow`.
- **Ring:** play a loud repeating sound and show a floating "Your phone is looking for this Mac" panel with Stop, until stopped or 60 s.

## 12. Walk-away lock (v1.5, off by default)

- **The phone advertises BLE** while paired, connected and `settings.walkAway` is true. The service UUID is derived as in §7.1, but with info `"mydroid v1 phone ble uuid"` (vector `phoneBleUuid`). It uses `ADVERTISE_MODE_LOW_POWER` and `TX_POWER_MEDIUM`, is non-connectable, and advertises only while the foreground service runs.
- **The Mac scans** for that UUID with duplicates allowed and smooths RSSI with an exponential moving average.
  - **Away:** smoothed RSSI below the threshold for 8 s, or not seen for 12 s. Threshold by sensitivity: Near −65, Medium −75 (default), Far −85 dBm.
  - **On away:** lock the Mac and sleep the display, **unless the Mac is in use** (HID idle time under 20 s, read via IOKit `HIDIdleTime`), because someone is clearly there. In that case, check again later.
  - **Back:** RSSI above threshold + 8 dB for 3 s. If "Wake display when I return" is on (the default), wake the display with `IOPMAssertionDeclareUserActivity`. The lock screen then waits for Touch ID or the password. **Mydroid never unlocks the Mac.**
- **Settings › Walk-away lock:** the toggle, the sensitivity, "Wake display when I return", and a live signal meter for calibration ("Phone signal: strong / medium / weak").

## 13. Opening notifications from the Mac (v1.6)

A notification's tap action (its `PendingIntent`) can't be read by other apps, so the Mac picks the best destination from what *is* visible. Clicking does the default for that app. Right-clicking offers **Open on phone**, **Open on web** (when there's a rule) and **Search the web**. Settings › Notifications has a per-app choice: Default / Open on phone / Open on web / Do nothing.

### 13.1 Extra fields on `notif.posted` (optional)

| field | meaning |
|---|---|
| `person` | `{name, phone?}`. `phone` is in E.164 format when the sender's `Person.uri` is `tel:…` or the conversation maps to a contact with a single number. Used for WhatsApp and Telegram chat links. |
| `links` | An array of http(s) URLs found in title, text, big text or messages, deduplicated, at most 3 |
| `media` | For media-style notifications: `{title, artist, album?, mediaId?}`. `mediaId` is sent **only** when it looks like a public content URI (`spotify:track:…`, `spotify:episode:…`, or an http(s) URL). |

### 13.2 Open on phone

M→P `notif.open {key}`. The phone sends that notification's `contentIntent`.
- On Android 14+, it passes `ActivityOptions.setPendingIntentBackgroundActivityStartMode(MODE_BACKGROUND_ACTIVITY_START_ALLOWED)`. A companion-device association lets Mydroid start activities from the background.
- If launching fails, the phone posts its own notification, "Tap to open in <App>".
- It replies with `notif.result`.

### 13.3 Default rules (Mac side; data-driven table, easy to extend)

| app | default | target |
|---|---|---|
| Gmail | web | `https://mail.google.com/mail/u/0/#search/` + `subject:"<subject>"` (the subject is the first line of the text) |
| WhatsApp | Mac app if installed, else web | `whatsapp://send?phone=<phone>` / `https://web.whatsapp.com/send?phone=<phone>`. With no phone (for example a group), open the app or web home. |
| Telegram | Mac app if installed, else web | `tg://resolve?phone=<phone>` / `https://web.telegram.org/` |
| X | web | message → `https://x.com/messages`, otherwise `https://x.com/notifications` |
| Instagram | web | message → `https://www.instagram.com/direct/inbox/`, otherwise `https://www.instagram.com/` |
| LinkedIn | web | message → `https://www.linkedin.com/messaging/`, otherwise `https://www.linkedin.com/notifications/` |
| YouTube | web | `https://www.youtube.com/results?search_query=<channel + video title>` |
| Spotify | Mac app if installed, else web | when `media.mediaId` is `spotify:track:<id>`: `spotify:track:<id>` / `https://open.spotify.com/track/<id>`. Otherwise open on phone. |
| Amazon, Swiggy, Zomato, Uber | web | that service's orders or trips page |
| any app whose `links` is non-empty | web | the first link |
| everything else | phone | `notif.open` |

## 14. Authenticator: 2FA codes from the phone (v1.7)

The phone is the only place secrets exist. The Mac receives only current codes, and only with the phone's approval policy.

### 14.1 Phone vault
- **Entries:** `{id (uuid), issuer, account, secret (base32), algorithm SHA1|SHA256|SHA512, digits 6|8, period (default 30), type totp|hotp, counter, domains: [string]}`.
- **Storage:** encrypted at rest (an Android Keystore AES-GCM key), never synced anywhere. Viewing codes on the phone can require biometrics (a setting, on by default).
- **Adding:**
  - Scan an `otpauth://` QR code.
  - Import Google Authenticator's export (`otpauth-migration://offline?data=…`, a protobuf `MigrationPayload` of `OtpParameters{secret, name, issuer, algorithm, digits, type, counter}`; multi-batch QR codes supported).
  - Manual entry.
  - Domains are pre-filled from a built-in issuer→domain map (for example Salesforce → salesforce.com, force.com) and taught by the Mac (`auth.domain.set`).
- **Backup:** export to a file encrypted with a user passphrase (scrypt or PBKDF2 into AES-256-GCM), and restore. The app nudges the user to make a backup once they have accounts.
- **TOTP/HOTP** per RFC 6238 / RFC 4226. Implementations MUST pass the RFC 6238 Appendix B vectors.

### 14.2 Messages
| type | dir | fields |
|---|---|---|
| `auth.list.get` | M→P | `req` |
| `auth.list` | P→M | `req`, `items`: `[{id, issuer, account, domains, digits}]`. **Never secrets.** The Mac keeps this in memory only. |
| `auth.code.get` | M→P | `req`, `domain` (the eTLD+1 plus the full host), `account?` (the username seen on the login page), `entryId?` (when the user already picked one), `client` (for example "Chrome", "Safari via shortcut") |
| `auth.code` | P→M | `req`, `ok`, `code?`, `validFor` (seconds), `entryId?`, `error?`: `"denied"`, `"timeout"`, `"no_match"`, `"ambiguous"` (with `choices: [{id, issuer, account}]`), or `"locked"` |
| `auth.domain.set` | M→P | `entryId`, `domain`. The user linked this site to the entry; the phone persists it. |

**Phone policy for `auth.code.get`:**
1. **Match** an entry whose `domains` contain the request's domain (subdomains allowed), narrowing by `account` when given.
   - Several matches → `ambiguous` with choices.
   - None → `no_match`.
2. **Approve.** The default is a high-priority notification, "Fill code for Salesforce (me@work.com) on MacBook Air?", with **Approve** and **Deny** actions (plus biometric if the user turned that on), timing out after 30 s. The optional mode auto-approves when the phone was unlocked within the last N minutes (default 5) **and** the Mac is present over BLE (§7.1).
3. **Reply** with the code. If fewer than 5 s remain in the period, send the next period's code with its `validFor`.
4. **Log** only "code sent to <Mac> for <issuer>" in the phone's Activity list. Never the code.

### 14.4 Import through the Mac's camera (one-time migration)

Google Authenticator's export shows QR codes on the phone and blocks screenshots, so the same phone can't scan them. The Mac's camera can.

- **On the Mac:** Settings › Authenticator → **Import with this Mac's camera** opens a camera window. Vision (`VNDetectBarcodesRequest`) reads `otpauth-migration://` and `otpauth://` QR codes, tracking multi-part batches ("2 of 3 scanned"), and does nothing with any other QR.
- **Sending:** when a batch is complete (or a single `otpauth://` QR is read), the Mac sends M→P `auth.import {req, uris:[string]}` over the encrypted session, then **immediately wipes** the strings from memory. Nothing is written to disk or logged. Swift `String` can't be zeroed reliably, so the Mac holds only the minimum, drops references at once, and keeps the camera session's buffers out of any cache.
- **On the phone:** it parses the URIs and shows an in-app confirmation: "Add 12 accounts from <Mac>?", listing issuer and account, with **Add** and **Cancel**. The device must be unlocked; this is the same biometric gate as viewing codes. Duplicates of existing secrets are skipped. The phone replies P→M `auth.import.result {req, ok, added, skipped, error?}` (`"cancelled"`, `"locked"`, `"invalid"`).
- **Copy:** the Mac shows "Accounts added on your phone. Nothing was saved on this Mac."

### 14.3 Mac surfaces
- **Browser extension** (Chrome, Edge, Brave, Arc, Chromium; MV3).
  - **Detecting a code field:** `autocomplete="one-time-code"`, OTP-like inputs (name/id/aria/label matching otp, totp, mfa, 2fa, code, verification, authenticator; `inputmode=numeric`; maxlength 6–8), or split single-digit inputs.
  - **Usernames:** remembers the username typed earlier in the same tab (session only).
  - **UI:** shows a small "Fill from phone" chip; it can auto-fill once the user allows that per site.
  - **Filling:** sets the value or the split boxes and dispatches `input` and `change` events.
  - **Native messaging:** talks to the host `com.mydroid.otp`, a small helper binary inside `Mydroid.app`. Its manifest is installed into each browser's `NativeMessagingHosts` folder. The manifest and helper allow the fixed unpacked ID derived from the extension manifest's `key` and the Chrome Web Store ID. The helper relays over a 0600 Unix socket to the running Mydroid app.
- **Global shortcut (⌃⌥C), any browser including Safari:** reads the front browser's URL via AppleScript (Automation permission), requests the code, and types it with CGEvent (Accessibility).
- **Phishing protection:** a code is filled only when the page's domain is in the entry's `domains`. To link an unknown site, the user must confirm explicitly, with a warning when the domain looks like a known issuer's (lookalike).
- **Later, with Developer ID signing:** an AuthenticationServices credential provider extension (one-time codes, macOS 15+) for native Safari and app AutoFill.

## 15. Continue on Mac: media handoff (v1.8)

- `media.state` (§7.3) gains an optional `mediaId`. It follows the same filter as §13.1: only `spotify:track:…`, `spotify:episode:…` or http(s). It's sent when the track changes.
- **Mac:** the Now Playing row shows **Continue on Mac** when `mediaId` is present.
  - **Spotify for Mac installed** (`com.spotify.client`): AppleScript `tell application "Spotify" to play track "<uri>"`, then `set player position to <seconds>`. The position is extrapolated from `position`, `ts` and `playing`. This needs Automation permission for Spotify; explain it once.
  - **Otherwise:** open `https://open.spotify.com/track/<id>` (or `/episode/<id>`).
  - **Then:** send `media.cmd {action:"pause"}` to the phone, unless the user turned off "Pause my phone when continuing on Mac" (default on).
- **Without a `mediaId`:** the row offers **Search on web**, a web search for "<title> <artist>".

## 16. Remote, rethought: apps, opening files, presenting, Mac media (v1.10)

Four additions to Remote (section 10). All of them are phone-to-Mac requests over the normal session; nothing here is sent until the phone asks.

### 16.1 Apps and opening files

| type | dir | fields |
|---|---|---|
| `mac.apps.get` | P→M | `req` |
| `mac.apps` | M→P | `req`, `running`: `[{id, name, icon?}]` (at most 16, most recently used first; `icon` is a base64 PNG of about 96 px), `apps`: `[{id, name}]` (installed apps, at most 300, from `/Applications`, `/System/Applications` and `~/Applications`, top level only). `id` is the bundle identifier. |
| `mac.launch` | P→M | `req`, `id`. Activates the app if it is running, else launches it. |
| `mac.open` | P→M | `req`, `root`, `path`. Opens the file with its default app. The path is resolved and confined exactly like `fs.get` (section 9), so only files in the folders the user shares can be opened. |
| `mac.result` | M→P | `req`, `ok`, `error?` (section 11). The answer to `mac.launch`, `mac.open` and `present.start`. |

### 16.2 Presenting

| type | dir | fields |
|---|---|---|
| `present.start` | P→M | `req`, `root`, `path`, `play` bool. Opens the file (confined like `mac.open`). With `play`, the Mac waits up to 10 s for the app to show the document, then starts the slideshow: Keynote `start`, PowerPoint ⇧⌘↩, Preview ⇧⌘F, Keynote and PowerPoint through the keyboard when scripting is not allowed. Answered with `mac.result`. |
| `present.watch` | P→M | `on` bool. While on, the Mac sends `present.state` on change (it may poll the app at most once a second). The phone turns it off when the Present screen closes. |
| `present.state` | M→P | `active` bool. When true: `app`, `index` (1-based slide), `count`, `notes` (presenter notes of the current slide, at most 4 KB, optional), `title` (optional). Fields the app can't report are left out. |

`remote.state.presenting` (section 10) still says that a slideshow is running at all; `present.state` adds where it is. When macOS has not let Mydroid control the app, `present.state` carries `active:true`, `app` and `error:"automation"` and nothing else.

### 16.3 Mac media

| type | dir | fields |
|---|---|---|
| `mac.media.watch` | P→M | `on` bool. While on, the Mac sends `mac.media` on change. |
| `mac.media` | M→P | `active` bool. When true: `app` (`"Music"` or `"Spotify"`), `title`, `artist`, `album`, `playing` bool, `position` ms, `duration` ms, `ts` ms epoch (when `position` was sampled), `canSeek`, `art` (optional base64 JPEG of at most 400 px, sent only when the track changes). Always: `volume` (0..1, the system output volume). `error`: `"automation"` when macOS has not let Mydroid control the player yet. |
| `mac.media.cmd` | P→M | `action`: `"toggle"`, `"next"`, `"prev"`, `"seek"` (plus `position` ms) or `"volume"` (plus `value` 0..1). |

- Song details come from Music and Spotify only (their own scripting). Other apps still answer the media keys of section 10, and the phone says so.
- The Mac never starts Music or Spotify to look at them: it reads them only while they are running.
- The first request makes macOS ask whether Mydroid may control the player; until then `mac.media` carries `error:"automation"`.
