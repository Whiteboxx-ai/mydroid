package com.mydroid.android.auth

import android.app.Activity
import android.content.Context
import android.net.Uri
import com.mydroid.android.transfers.ActivityEntry
import com.mydroid.protocol.Message
import com.mydroid.protocol.auth.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/** Progress of a multi-QR Google Authenticator export. */
data class ImportProgress(val scanned: Int, val size: Int, val missing: List<Int>)

/** Which sheet or dialog the Authenticator is showing over the current screen. */
sealed interface AuthFlow {
    object None : AuthFlow
    /** Choose a passphrase for a new backup. */
    object BackupForm : AuthFlow
    /** A backup file was picked; ask its passphrase. [wrong] after a failed try. */
    class RestorePassphrase(val wrong: Boolean = false) : AuthFlow
    class Busy(val what: String) : AuthFlow
}

/** What the screens use. [AuthApi.None] renders them without the app. */
interface AuthApi {
    val entries: StateFlow<List<AuthEntry>>
    val gateOpen: StateFlow<Boolean>
    val importProgress: StateFlow<ImportProgress?>
    val flow: StateFlow<AuthFlow>
    val notice: StateFlow<String?>

    fun unlock() {}
    fun lock() {}
    fun scan() {}
    fun scanNextPart() {}
    fun cancelImport() {}
    /** Null when saved, else what is wrong with the input. */
    fun addManual(entry: AuthEntry): String? = null
    fun save(entry: AuthEntry) {}
    fun delete(id: String) {}
    fun copyCode(entry: AuthEntry) {}
    fun nextHotp(id: String) {}
    fun dismissNudge() {}
    fun beginBackup() {}
    fun cancelFlow() {}
    fun confirmBackup(passphrase: CharArray) {}
    fun beginRestore() {}
    fun confirmRestore(passphrase: CharArray) {}
    fun consumeNotice() {}
    fun setRequireBiometric(on: Boolean) {}
    fun setApproveMode(mode: ApprovalPolicy.Mode, minutes: Int) {}
    fun deleteAll() {}
    /** Keep the window off screenshots and Recents while codes or secrets are on screen. */
    fun secure(on: Boolean) {}

    object None : AuthApi {
        override val entries = MutableStateFlow<List<AuthEntry>>(emptyList())
        override val gateOpen = MutableStateFlow(true)
        override val importProgress = MutableStateFlow<ImportProgress?>(null)
        override val flow = MutableStateFlow<AuthFlow>(AuthFlow.None)
        override val notice = MutableStateFlow<String?>(null)
    }
}

/** What MainActivity provides: the things that need an Activity. */
interface AuthHost {
    fun prompt(onResult: (Boolean) -> Unit)
    fun scanQr(onResult: (String?) -> Unit)
    fun createDocument(name: String)
    fun openDocument()
    fun secure(on: Boolean)
}

class AuthController(
    private val ctx: Context,
    send: (Message) -> Boolean,
    macName: () -> String,
    macPresent: () -> Boolean,
    record: (ActivityEntry) -> Unit,
    appVisible: () -> Boolean = { false },
) : AuthApi {
    val vault = AuthVault(File(ctx.filesDir, "auth_vault.bin"), KeystoreVaultBox)
    val prefs = AuthPrefs(ctx)
    val gate = AuthGate()
    @Volatile var host: AuthHost? = null

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /** PROTOCOL.md 14.4: accounts the Mac's camera read, held in memory until the user reviews and adds them. */
    val importer = AuthImporter(
        vault, send, macName, AuthImportSurface(ctx, appVisible), record,
        onAdded = {
            // Nudge a backup if there is none: bring the card back even if it was dismissed when there was one account.
            if (prefs.lastBackupAt == 0L) prefs.nudgeDismissed = false
            refreshUi()
            prefs.lastBackupAt == 0L
        },
        schedule = { ms, task -> val r = Runnable(task); mainHandler.postDelayed(r, ms); { mainHandler.removeCallbacks(r) } },
    )

    val bridge = AuthBridge(ctx, vault, prefs, send, macName, macPresent, record, onChanged = { refreshUi() }, importer = importer)

    private val io = Executors.newSingleThreadExecutor { Thread(it, "mydroid-auth-io").apply { isDaemon = true } }

    private val _ui = MutableStateFlow(AuthUi())
    val ui: StateFlow<AuthUi> get() = _ui

    override val entries: StateFlow<List<AuthEntry>> get() = vault.entries
    override val gateOpen: StateFlow<Boolean> get() = gate.open
    private val _import = MutableStateFlow<ImportProgress?>(null)
    override val importProgress: StateFlow<ImportProgress?> get() = _import
    private val _flow = MutableStateFlow<AuthFlow>(AuthFlow.None)
    override val flow: StateFlow<AuthFlow> get() = _flow
    private val _notice = MutableStateFlow<String?>(null)
    override val notice: StateFlow<String?> get() = _notice

    private val batch = MigrationBatch()
    private var passphrase: CharArray? = null
    private var restoreUri: Uri? = null

    init {
        io.execute { vault.all(); refreshUi() }
        refreshUi()
    }

    fun refreshUi() {
        val n = if (vault.health == AuthVault.Health.Ok) vault.count else 0
        _ui.value = AuthUi(
            count = n, unreadable = vault.health == AuthVault.Health.Unreadable, requireBiometric = prefs.requireBiometric,
            approveMode = prefs.approveMode, autoMinutes = prefs.autoMinutes, lastBackupAt = prefs.lastBackupAt,
            nudge = n > 0 && prefs.lastBackupAt == 0L && !prefs.nudgeDismissed, canGate = AuthGate.canGate(ctx),
        )
    }

    fun onUserPresent() { prefs.lastUnlockedAt = System.currentTimeMillis() }
    fun onAppBackground() = gate.onBackground()
    fun onAppForeground() = gate.onForeground()
    fun onDisconnected() { bridge.onDisconnected(); importer.onDisconnected() }

    // ---------------------------------------------------------------- gate

    override fun unlock() {
        if (!prefs.requireBiometric) { gate.unlock(); return }
        host?.prompt { /* the gate flow updates itself */ }
    }

    override fun lock() = gate.lock()

    override fun secure(on: Boolean) { host?.secure(on) }

    // ---------------------------------------------------------------- adding

    override fun scan() {
        host?.scanQr { raw -> if (raw != null) onScanned(raw) else say("Scanner unavailable. Enter the key instead") }
    }

    override fun scanNextPart() = scan()

    override fun cancelImport() { batch.reset(); _import.value = null }

    private fun onScanned(raw: String) {
        when {
            OtpAuthUri.isOtpAuth(raw) -> {
                val e = OtpAuthUri.parse(raw)
                if (e == null) say("Not a valid authenticator code")
                else { val n = vault.add(listOf(e)); refreshUi(); say(if (n == 1) "Added ${e.title}" else "${e.title} is already here") }
            }
            Migration.isMigration(raw) -> {
                val p = Migration.parse(raw)
                if (p == null) { say("Couldn't read that code. Export again"); return }
                if (batch.add(p) == MigrationBatch.Result.Duplicate) say("Already scanned")
                if (batch.isComplete) finishImport() else _import.value = ImportProgress(batch.scanned, batch.size, batch.missing)
            }
            else -> say("Not an authenticator code")
        }
    }

    private fun finishImport() {
        val all = batch.entries; val skipped = batch.skipped
        batch.reset(); _import.value = null
        val added = vault.add(all); refreshUi()
        val dup = all.size - added
        say(buildString {
            append(if (added == 1) "Added 1 account" else "Added $added accounts")
            if (dup > 0) append(". $dup already here")
            if (skipped > 0) append(". $skipped couldn't be imported")
        })
    }

    override fun addManual(entry: AuthEntry): String? {
        val secret = Base32.normalize(entry.secret)
        if (!Base32.isValidSecret(secret)) return "That key doesn't look right"
        if (entry.issuer.isBlank() && entry.account.isBlank()) return "Add a name"
        val e = entry.copy(secret = secret, domains = Domains.clean(entry.domains))
        if (vault.add(listOf(e)) == 0) return "Already added"
        refreshUi(); return null
    }

    override fun save(entry: AuthEntry) { vault.update(entry.copy(domains = Domains.clean(entry.domains))); refreshUi() }
    override fun delete(id: String) { vault.delete(id); refreshUi() }
    override fun nextHotp(id: String) { vault.advanceCounter(id) }

    override fun copyCode(entry: AuthEntry) {
        val code = entry.code(System.currentTimeMillis() / 1000) ?: return
        CodeClipboard.copy(ctx, code)
        if (entry.type == OtpType.HOTP) vault.advanceCounter(entry.id)
        say("Code copied")
    }

    override fun dismissNudge() { prefs.nudgeDismissed = true; refreshUi() }

    // ---------------------------------------------------------------- backup

    override fun beginBackup() { _flow.value = AuthFlow.BackupForm }
    override fun cancelFlow() { passphrase?.fill(' '); passphrase = null; restoreUri = null; _flow.value = AuthFlow.None }

    override fun confirmBackup(passphrase: CharArray) {
        if (!PassphraseStrength.acceptable(String(passphrase))) return
        this.passphrase = passphrase
        _flow.value = AuthFlow.None
        host?.createDocument("mydroid-authenticator-" + SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date()) + ".mydroidauth")
    }

    /** SAF result for the export. */
    fun onBackupUri(uri: Uri?) {
        val pass = passphrase; passphrase = null
        if (uri == null || pass == null) { pass?.fill(' '); return }
        _flow.value = AuthFlow.Busy("Encrypting…")
        io.execute {
            try {
                val bytes = AuthBackup.encrypt(vault.all(), pass, System.currentTimeMillis())
                ctx.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) }
                prefs.lastBackupAt = System.currentTimeMillis(); refreshUi()
                say("Backup saved")
            } catch (e: Exception) {
                say("Couldn't save. Try another location")
            } finally { pass.fill(' '); _flow.value = AuthFlow.None }
        }
    }

    override fun beginRestore() { host?.openDocument() }

    /** SAF result for the import. */
    fun onRestoreUri(uri: Uri?) {
        if (uri == null) return
        restoreUri = uri
        _flow.value = AuthFlow.RestorePassphrase()
    }

    override fun confirmRestore(passphrase: CharArray) {
        val uri = restoreUri ?: return
        _flow.value = AuthFlow.Busy("Decrypting…")
        io.execute {
            try {
                val bytes = ctx.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
                if (bytes.size > 8_000_000) throw AuthBackup.BackupException(AuthBackup.Failure.NotABackup)
                val entries = AuthBackup.decrypt(bytes, passphrase)
                val added = vault.add(entries); refreshUi()
                restoreUri = null; _flow.value = AuthFlow.None
                say(if (entries.isEmpty()) "Backup is empty" else if (added < entries.size) "Restored $added of ${entries.size}" else "Restored ${if (added == 1) "1 account" else "$added accounts"}")
            } catch (e: AuthBackup.BackupException) {
                when (e.failure) {
                    AuthBackup.Failure.WrongPassphrase -> _flow.value = AuthFlow.RestorePassphrase(wrong = true)
                    AuthBackup.Failure.UnsupportedVersion -> { restoreUri = null; _flow.value = AuthFlow.None; say("Backup is from a newer Mydroid") }
                    else -> { restoreUri = null; _flow.value = AuthFlow.None; say("Not a Mydroid backup") }
                }
            } catch (e: Exception) {
                restoreUri = null; _flow.value = AuthFlow.None; say("Couldn't read that file.")
            } finally { passphrase.fill(' ') }
        }
    }

    // ---------------------------------------------------------------- settings

    override fun setRequireBiometric(on: Boolean) {
        prefs.requireBiometric = on
        if (!on) gate.unlock() else gate.lock()
        refreshUi()
    }

    override fun setApproveMode(mode: ApprovalPolicy.Mode, minutes: Int) { prefs.approveMode = mode; prefs.autoMinutes = minutes; refreshUi() }

    override fun deleteAll() {
        vault.deleteAll(); prefs.lastBackupAt = 0; prefs.nudgeDismissed = false; cancelImport(); gate.lock(); refreshUi()
        say("All accounts deleted")
    }

    override fun consumeNotice() { _notice.value = null }
    private fun say(s: String) { _notice.value = s }
}
