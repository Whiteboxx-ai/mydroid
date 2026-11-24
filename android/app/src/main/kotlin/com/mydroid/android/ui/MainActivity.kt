package com.mydroid.android.ui

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.mydroid.android.BuildConfig
import com.mydroid.android.Perms
import com.mydroid.android.presence.Presence
import androidx.activity.result.IntentSenderRequest
import com.mydroid.android.clip.ClipAccessibilityService
import com.mydroid.android.fix.Fixer
import com.mydroid.android.fix.Oem
import com.mydroid.android.manager
import com.mydroid.android.net.ConnectionService
import com.mydroid.android.notif.MydroidNotificationListener
import com.mydroid.protocol.PairingUrl
import com.mydroid.android.mac.PresenterNotice
import com.mydroid.android.remote.RemoteApi
import com.mydroid.android.remote.VolumeKeys
import com.mydroid.android.walkaway.WalkAway

class Actions(
    val scan: () -> Unit = {},
    val cancelPairing: () -> Unit = {},
    val allowNotificationAccess: () -> Unit = {},
    val allowPhotos: () -> Unit = {},
    val allowSms: () -> Unit = {},
    val allowCalls: () -> Unit = {},
    val allowSmsHistory: () -> Unit = {},
    val allowDial: () -> Unit = {},
    val allowAlerts: () -> Unit = {},
    val openBackgroundSettings: () -> Unit = {},
    val openOem: () -> Unit = {},
    /** Opens Mydroid in Android's Accessibility settings (Instant copy, or to turn a leftover service off). */
    val allowClipboard: () -> Unit = {},
    val setInstantCopy: (Boolean) -> Unit = {},
    val allowPresence: () -> Unit = {},
    val enableWatchMode: () -> Unit = {},
    /** Opens the system Files app at the Mac's root (PROTOCOL.md 9). */
    val openMacFiles: () -> Unit = {},
    /** Photo picker (images and videos, no permission needed). Results go to the transfer outbox. */
    val pickMedia: () -> Unit = {},
    /** System document picker, any type, several at once. */
    val pickFiles: () -> Unit = {},
    /** Reads the clipboard now (the app is in front) and sends a link, text or image. */
    val paste: () -> Unit = {},
    val sendText: (String) -> Unit = {},
    val consumeNotice: () -> Unit = {},
    /** Walk-away lock needs Nearby devices (BLUETOOTH_ADVERTISE): asked in context, from Settings or the Home banner. */
    val allowWalkAway: () -> Unit = {},
    /** Quick actions, Shortcuts and favourites (PROTOCOL.md 11). */
    val mac: MacActions = MacActions(),
    /** The notification asked for a Remote mode; the UI has now opened it. */
    val consumeOpenRemote: () -> Unit = {},
    val remote: RemoteApi = RemoteApi.None,
    /** Authenticator vault, backup and Mac code requests (PROTOCOL.md 14). */
    val auth: com.mydroid.android.auth.AuthApi = com.mydroid.android.auth.AuthApi.None,
    val unpair: () -> Unit = {},
    val finishSetup: () -> Unit = {},
)

class MainActivity : ComponentActivity() {
    private val photoLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { manager().refreshFeatures() }
    private val callLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { manager().refreshFeatures() }
    private val smsLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { manager().refreshFeatures() }
    private val smsHistoryLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { manager().refreshFeatures() }
    private val dialLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { manager().refreshFeatures() }
    private val alertLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { manager().refreshFeatures() }
    /** Which association the Bluetooth permission prompt was for, so granting it continues the same flow. */
    private var pendingWatch = false
    private val btLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        manager().refreshFeatures()
        val watch = pendingWatch
        pendingWatch = false
        if (Presence.hasPermissions(this)) { if (watch) enableWatchMode() else startAssociation() }
    }
    private val assocLauncher = registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) {
        // The system dialog has closed; whether or not the user said yes, re-read the truth from CompanionDeviceManager.
        Presence.dropPlainSoon(this)
        manager().refreshPresence(force = true)
        manager().refreshFeatures()
    }

    private val walkAwayLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { manager().refreshFeatures() }

    private val mediaPicker = registerForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris ->
        if (uris.isNotEmpty()) manager().postNotice(manager().sendUris(uris))
    }
    private val filePicker = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        // Keep read access in case the Mac is away and the send has to wait; not every provider allows it.
        uris.forEach { runCatching { contentResolver.takePersistableUriPermission(it, Intent.FLAG_GRANT_READ_URI_PERMISSION) } }
        if (uris.isNotEmpty()) manager().postNotice(manager().sendUris(uris))
    }

    private val backupLauncher = registerForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { manager().auth.onBackupUri(it) }
    private val restoreLauncher = registerForActivityResult(ActivityResultContracts.OpenDocument()) { manager().auth.onRestoreUri(it) }
    private var qrResult: ((String?) -> Unit)? = null

    /** What the Authenticator needs an Activity for. */
    private val authHost = object : com.mydroid.android.auth.AuthHost {
        override fun prompt(onResult: (Boolean) -> Unit) {
            manager().auth.gate.prompt(this@MainActivity, "Unlock Authenticator", "Confirm it's you to see your codes", onResult = onResult)
        }
        override fun scanQr(onResult: (String?) -> Unit) {
            // Google's scanner returns any QR; otpauth:// and otpauth-migration:// are told apart by the controller.
            val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
            GmsBarcodeScanning.getClient(this@MainActivity, options).startScan()
                .addOnSuccessListener { onResult(it.rawValue ?: "") }
                .addOnCanceledListener { }
                .addOnFailureListener { onResult(null) }
        }
        override fun createDocument(name: String) { backupLauncher.launch(name) }
        override fun openDocument() { restoreLauncher.launch(arrayOf("*/*")) }
        override fun secure(on: Boolean) {
            if (on) window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE) else window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val m = manager()
        m.auth.host = authHost
        if (m.store.isPaired) {
            m.start()
            m.unpark("app open", force = true)
            ConnectionService.start(this)
        }
        val actions = Actions(
            scan = ::scan,
            cancelPairing = { m.cancelPairing() },
            allowNotificationAccess = ::openNotificationAccess,
            allowPhotos = { photoLauncher.launch(Perms.photoPermissions()) },
            allowSms = { smsLauncher.launch(Manifest.permission.RECEIVE_SMS) },
            allowCalls = { callLauncher.launch(Perms.callPermissions) },
            allowSmsHistory = { smsHistoryLauncher.launch(Perms.smsHistoryPermissions) },
            allowDial = { dialLauncher.launch(Manifest.permission.CALL_PHONE) },
            allowAlerts = { if (Build.VERSION.SDK_INT >= 33) alertLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) },
            openBackgroundSettings = ::openBackgroundSettings,
            openOem = { m.markOemOpened(); Oem.openAutoStart(this) },
            allowClipboard = ::openAccessibilitySettings,
            setInstantCopy = { m.setInstantCopy(it) },
            allowPresence = ::allowPresence,
            enableWatchMode = ::enableWatchMode,
            openMacFiles = {
                if (!com.mydroid.android.files.MacFiles.openInFiles(this, m.store.macId)) Toast.makeText(this, "Couldn't open Files", Toast.LENGTH_LONG).show()
            },
            pickMedia = { mediaPicker.launch(androidx.activity.result.PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) },
            pickFiles = { filePicker.launch(arrayOf("*/*")) },
            paste = { m.postNotice(m.pasteFromClipboard(this)) },
            sendText = { m.postNotice(m.sendText(it, "app")) },
            consumeNotice = { m.consumeNotice() },
            allowWalkAway = { if (WalkAway.permissions.isNotEmpty()) walkAwayLauncher.launch(WalkAway.permissions) },
            mac = MacActions(
                lock = { m.mac.lock() }, sleep = { m.mac.sleep() }, ring = { m.mac.toggleRing() },
                loadShortcuts = { m.mac.loadShortcuts() }, runShortcut = { m.mac.runShortcut(it) }, toggleFavorite = { m.mac.toggleFavorite(it) },
            ),
            consumeOpenRemote = { m.consumeOpenRemote() },
            auth = m.auth,
            remote = m.remoteApi,
            unpair = { m.unpair() },
            finishSetup = { m.markSetupDone() },
        )
        setContent {
            MydroidTheme {
                val state by m.state.collectAsStateWithLifecycle()
                MydroidApp(state, actions)
            }
        }
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    override fun onStart() {
        super.onStart()
        manager().setVisible(true)
        manager().auth.onAppForeground()
    }

    override fun onStop() {
        manager().setVisible(false)
        manager().auth.onAppBackground()
        super.onStop()
    }

    override fun onDestroy() {
        manager().auth.gate.cancelPrompt()
        if (manager().auth.host === authHost) manager().auth.host = null
        super.onDestroy()
    }

    /** Presenter mode: the volume buttons are Next and Back while it's on screen. Held keys don't repeat. */
    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent): Boolean {
        val h = VolumeKeys.handler
        if (h != null && (keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP || keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN)) {
            if (event.repeatCount == 0) h(keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP)
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: android.view.KeyEvent): Boolean {
        if (VolumeKeys.handler != null && (keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP || keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN)) return true
        return super.onKeyUp(keyCode, event)
    }

    override fun onResume() {
        super.onResume()
        Presence.dropPlainSoon(this)
        manager().refreshPresence(force = false)
        manager().unpark("app open", force = true)
        manager().refreshFeatures()
        manager().wakeUp("app open")
    }

    private fun handleIntent(i: Intent?) {
        i ?: return
        val data = i.data
        if (i.action == Intent.ACTION_VIEW && data != null && data.scheme == "mydroid") {
            i.data = null // consume so a rotation doesn't re-pair
            startPairingFrom(data.toString())
            return
        }
        if (i.getBooleanExtra(EXTRA_BACKUP, false)) { i.removeExtra(EXTRA_BACKUP); manager().auth.beginBackup() }
        i.getStringExtra(PresenterNotice.EXTRA_OPEN_REMOTE)?.let { manager().requestRemote(it); i.removeExtra(PresenterNotice.EXTRA_OPEN_REMOTE) }
        when (i.getStringExtra(Fixer.EXTRA_FIX)) {
            "photos" -> photoLauncher.launch(Perms.photoPermissions())
            "calls" -> callLauncher.launch(Perms.callPermissions)
            "sms" -> smsHistoryLauncher.launch(Perms.smsHistoryPermissions)
            "dial" -> dialLauncher.launch(Manifest.permission.CALL_PHONE)
        }
        i.removeExtra(Fixer.EXTRA_FIX)
    }

    private fun scan() {
        val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { startPairingFrom(it.rawValue ?: "") }
            .addOnFailureListener {
                manager().postMessage("The scanner isn't available right now. Open the code with your camera app instead, and tap the link.")
            }
    }

    private fun startPairingFrom(raw: String) {
        val m = manager()
        val url = PairingUrl.parse(raw)
        if (url == null) {
            m.postMessage("That isn't a Mydroid code. Open Mydroid on your Mac and scan the code it shows.")
            return
        }
        m.start()
        ConnectionService.start(this)
        m.startPairing(url)
    }

    private fun openNotificationAccess() {
        val cn = ComponentName(this, MydroidNotificationListener::class.java)
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                    .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, cn.flattenToString()))
            } else {
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            }
        } catch (e: Exception) {
            runCatching { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }
        }
    }

    /** Opens the Mydroid entry in Accessibility settings where the OS supports it, else the list. */
    private fun openAccessibilitySettings() {
        val cn = ComponentName(this, ClipAccessibilityService::class.java)
        try {
            startActivity(Intent("android.settings.ACCESSIBILITY_DETAIL_SETTINGS")
                .putExtra("android.provider.extra.ACCESSIBILITY_SERVICE_COMPONENT_NAME", cn.flattenToString()))
        } catch (e: Exception) {
            runCatching { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
        }
    }

    /** Bluetooth permission first (in context, with the why on screen), then the one-tap system association dialog. */
    private fun allowPresence() {
        if (!Presence.supported(this)) return
        // One Bluetooth approval for everything: on Android 13+ the watch-profile association covers both
        // "Mac nearby" (battery) and unhidden codes from apps, so never ask the user twice.
        if (Build.VERSION.SDK_INT >= 33) { enableWatchMode(); return }
        if (!Presence.hasPermissions(this)) btLauncher.launch(Presence.permissions) else startAssociation()
    }

    /** Re-pair with the watch profile so Android stops hiding one-time codes from Mydroid. */
    private fun enableWatchMode() {
        if (Build.VERSION.SDK_INT < 33) return
        if (!Presence.hasPermissions(this)) { pendingWatch = true; btLauncher.launch(Presence.permissions); return }
        if (Presence.isWatch(this)) {
            Toast.makeText(this, "Already set up", Toast.LENGTH_SHORT).show()
            manager().refreshFeatures(); return
        }
        // One dialog: the watch association also does everything the nearby one did. The old plain
        // association is removed only after the new one exists, so cancelling loses nothing.
        startAssociation(watch = true)
    }

    private fun startAssociation(watch: Boolean = false) {
        if (Build.VERSION.SDK_INT < 31) return
        if (!Presence.bluetoothOn(this)) {
            Toast.makeText(this, "Turn on Bluetooth, then try again", Toast.LENGTH_LONG).show()
            runCatching { startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)) }
            return
        }
        if (!watch && Presence.hasAssociation(this)) { manager().refreshPresence(force = true); return }
        Presence.associate(this,
            launch = { sender -> runCatching { assocLauncher.launch(IntentSenderRequest.Builder(sender).build()) } },
            failed = { Toast.makeText(this, it, Toast.LENGTH_LONG).show() },
            watch = watch,
            created = { manager().refreshPresence(force = true) })
    }

    companion object {
        /** The account-import "Done" screen asks to start a backup (PROTOCOL.md 14.4). */
        const val EXTRA_BACKUP = "com.mydroid.android.EXTRA_BACKUP"
    }

    private fun openBackgroundSettings() {
        manager().watchFeaturesAfterFix()
        startActivity(Oem.appDetails(this))
    }
}

