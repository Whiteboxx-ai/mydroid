package com.mydroid.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.captureRoboImage
import com.mydroid.android.Feature
import com.mydroid.android.FeatureReport
import com.mydroid.android.FeatureState
import com.mydroid.android.auth.*
import com.mydroid.android.callaudio.CallAudioState
import com.mydroid.android.callaudio.CallAudioStatus
import com.mydroid.android.data.Settings
import com.mydroid.android.net.Link
import com.mydroid.android.net.UiState
import com.mydroid.android.presence.PresenceStatus
import com.mydroid.android.transfers.*
import com.mydroid.protocol.auth.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/** Authenticator renders (light and dark) with fake data. No real secrets: these keys are made up. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w360dp-h900dp-xxhdpi")
@OptIn(ExperimentalMaterial3Api::class)
class AuthScreenshotTest(private val dark: Boolean) {
    companion object {
        @JvmStatic @Parameters(name = "dark={0}") fun modes() = listOf(arrayOf<Any>(false), arrayOf<Any>(true))
    }

    @get:Rule val rule = createComposeRule()

    private fun render(name: String, heightDp: Int = 900, fontScale: Float = 1f, content: @Composable () -> Unit) {
        RuntimeEnvironment.setQualifiers("+w360dp-h${heightDp}dp-xxhdpi")
        rule.mainClock.autoAdvance = false
        rule.setContent {
            val d = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(d.density, fontScale)) {
                MydroidTheme(dark = dark, dynamic = false) {
                    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) { Box(Modifier.fillMaxSize()) { content() } }
                }
            }
        }
        rule.mainClock.advanceTimeBy(1000)
        val dir = File(System.getProperty("render.dir")!!).apply { mkdirs() }
        rule.onRoot().captureRoboImage(File(dir, "$name-${if (dark) "dark" else "light"}.png").path)
    }

    // ---------------------------------------------------------------- fake data

    private val t0 = 1_800_000_000_000L // a multiple of 30 s
    private val ok = t0 + 13_000          // 17 s left in a 30 s period
    private val low = t0 + 26_000         // 4 s left

    private val fake = listOf(
        AuthEntry("1", "Salesforce", "me@work.com", "JBSWY3DPEHPK3PXP", domains = listOf("salesforce.com", "force.com")),
        AuthEntry("2", "GitHub", "octocat", "GEZDGNBVGY3TQOJQGEZDGNBVGY", domains = listOf("github.com")),
        AuthEntry("3", "Google", "maya.tan@gmail.com", "MFRGGZDFMZTWQ2LKNNWG23TP", domains = listOf("google.com")),
        AuthEntry("4", "Amazon Web Services", "admin-prod", "NBSWY3DPFQQHO33SNRSCCCQ", algorithm = OtpAlgorithm.SHA256, digits = 8, domains = listOf("aws.amazon.com")),
        AuthEntry("5", "Zerodha", "AB1234", "ONSWG4TFOQQGC3THEB2GQZJAMFWWK", period = 60, domains = listOf("zerodha.com")),
        AuthEntry("6", "", "legacy-vpn", "KRSXG5CTMVRXEZLUKN2XGZLS", type = OtpType.HOTP, counter = 12),
    )

    private val set = Settings(notifications = true, photos = true, calls = true, clipboard = true, smsHistory = true)
    private val allOn = FeatureReport(
        states = Feature.entries.associateWith { FeatureState.On }, otp = FeatureState.On, dial = true, presence = PresenceStatus.Ready, codesFromApps = true,
        callAudio = CallAudioStatus(CallAudioState.On), callAudioEver = true,
    )

    private fun ui(count: Int = fake.size, nudge: Boolean = false, auto: Boolean = false, last: Long = 0, report: FeatureReport = allOn) = UiState(
        link = Link.Connected, macName = "Gautamm’s MacBook Air", lastSeen = t0, settings = set, report = report, setupDone = true,
        transfers = TransfersState(recent = listOf(
            ActivityEntry("a", Direction.ToMac, Kind.Auth, "Code sent to Gautamm’s MacBook Air for Salesforce", null, t0 - 120_000),
            ActivityEntry("b", Direction.ToMac, Kind.Auth, "Code request for GitHub", "Timed out", t0 - 3_600_000, ok = false),
        )),
        auth = AuthUi(count = count, nudge = nudge, lastBackupAt = last, approveMode = if (auto) ApprovalPolicy.Mode.Auto else ApprovalPolicy.Mode.Ask),
    )

    private fun content(s: UiState, entries: List<AuthEntry> = fake, now: Long = ok, unlocked: Boolean = true, progress: ImportProgress? = null, sheet: Boolean = false) =
        @Composable { AuthenticatorContent(s, entries, now, unlocked, progress, AuthApi.None, {}, initialAddSheet = sheet) }

    // ---------------------------------------------------------------- list

    @Test fun list() = render("auth-list", heightDp = 1000) { content(ui())() }

    @Test fun listLowTime() = render("auth-list-4s-left", heightDp = 1000) { content(ui(), now = low)() }

    @Test fun listBackupNudge() = render("auth-list-backup-nudge", heightDp = 1100) { content(ui(nudge = true))() }

    @Test fun listLargeFont() = render("auth-list-fontscale1.3", heightDp = 1500, fontScale = 1.3f) { content(ui(nudge = true))() }

    @Test fun locked() = render("auth-locked") { content(ui(), unlocked = false)() }

    @Test fun empty() = render("auth-empty", heightDp = 1000) { content(ui(count = 0), entries = emptyList())() }

    @Test fun unreadable() = render("auth-unreadable") {
        content(ui(count = 0).copy(auth = AuthUi(unreadable = true)), entries = emptyList())()
    }

    // ---------------------------------------------------------------- adding

    @Test fun addSheet() = render("auth-add-sheet", heightDp = 760) {
        BottomSheetMock { AddSheetContent({}, {}, {}, {}) }
    }

    @Test fun addSheetImportExpanded() = render("auth-add-sheet-import", heightDp = 1100) {
        BottomSheetMock { AddSheetContent({}, {}, {}, {}, initialExpanded = true) }
    }

    @Test fun manualEntry() = render("auth-manual-entry", heightDp = 1000) {
        Column { PageHeaderMock("Enter manually"); ManualEntryContent(onSave = { null }, onClose = {}, initialSecret = "JBSW Y3DP EHPK 3PXP", initialIssuer = "Salesforce") }
    }

    @Test fun manualEntryAdvanced() = render("auth-manual-entry-advanced", heightDp = 1500) {
        Column { PageHeaderMock("Enter manually"); ManualEntryContent(onSave = { null }, onClose = {}, initialSecret = "JBSWY3DPEHPK3PXP", initialIssuer = "Salesforce", initialAdvanced = true) }
    }

    @Test fun importProgressList() = render("auth-import-progress", heightDp = 1000) {
        content(ui(count = 2), entries = fake.take(2), progress = ImportProgress(2, 3, listOf(3)))()
    }

    @Test fun importProgressFirstPart() = render("auth-import-progress-empty", heightDp = 700) {
        content(ui(count = 0), entries = emptyList(), progress = ImportProgress(1, 3, listOf(2, 3)))()
    }

    // ---------------------------------------------------------------- import from the Mac's camera (PROTOCOL.md 14.4)

    private val reviewItems = listOf(
        ImportItem("Salesforce", "me@work.com"), ImportItem("GitHub", "octocat"), ImportItem("Google", "maya.tan@gmail.com"),
        ImportItem("Amazon Web Services", "admin-prod"), ImportItem("Zerodha", "AB1234"), ImportItem("", "legacy-vpn"),
        ImportItem("Dropbox", "maya.tan@gmail.com"), ImportItem("Cloudflare", "ops@example.org"),
    )

    @Test fun importReview() = render("auth-import-review", heightDp = 900) {
        ImportReviewContent(ImportReview("r1", "Gautamm’s MacBook Air", reviewItems, skipped = 2), onAdd = {}, onCancel = {})
    }

    @Test fun importReviewOne() = render("auth-import-review-one", heightDp = 700) {
        ImportReviewContent(ImportReview("r1", "Gautamm’s MacBook Air", reviewItems.take(1), skipped = 0), hint = "Nothing was added. Tap Add to try again, or Cancel.", onAdd = {}, onCancel = {})
    }

    @Test fun importReviewLargeFont() = render("auth-import-review-fontscale1.3", heightDp = 1100, fontScale = 1.3f) {
        ImportReviewContent(ImportReview("r1", "Gautamm’s MacBook Air", reviewItems, skipped = 0), onAdd = {}, onCancel = {})
    }

    @Test fun importDone() = render("auth-import-done", heightDp = 760) { ImportDoneContent(ImportDone(added = 8, skipped = 2, needsBackup = true), {}, {}) }

    @Test fun importDoneBackedUp() = render("auth-import-done-backed-up", heightDp = 560) { ImportDoneContent(ImportDone(added = 1, skipped = 0, needsBackup = false), {}, {}) }

    @Test fun importNotification() = render("auth-import-notification", heightDp = 380) {
        Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ApprovalNotificationMock("Add 8 accounts?", "From Gautamm’s MacBook Air. Review before adding.", actions = false)
            ApprovalNotificationMock("Account import", "Unlock to review", actions = false)
        }
    }

    // ---------------------------------------------------------------- backup

    @Test fun backupPassphraseStrong() = render("auth-backup-passphrase", heightDp = 760) {
        DialogMock { BackupPassphraseContent({}, {}, initialPass = "correct horse battery staple", initialConfirm = "correct horse battery staple") }
    }

    @Test fun backupPassphraseWeak() = render("auth-backup-passphrase-weak", heightDp = 760) {
        DialogMock { BackupPassphraseContent({}, {}, initialPass = "hunter22", initialConfirm = "hunter2") }
    }

    @Test fun restorePassphrase() = render("auth-restore-passphrase-wrong", heightDp = 560) {
        DialogMock { RestorePassphraseContent(wrong = true, {}, {}) }
    }

    // ---------------------------------------------------------------- approval notification (mock of what Android draws)

    @Test fun approvalNotification() = render("auth-approval-notification", heightDp = 420) {
        Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ApprovalNotificationMock("Fill code for Salesforce?", "Asked by Chrome. Approve only if that was you.")
            ApprovalNotificationMock("Code request", "Unlock to see details", actions = false)
        }
    }

    // ---------------------------------------------------------------- Home and Settings

    @Test fun homeRow() = render("auth-home-row", heightDp = 1300) {
        HomeScreen(ui(nudge = true), Actions(), t0, {}, animate = false)
    }

    @Test fun settingsSection() = render("auth-settings", heightDp = 2300) {
        SettingsScreen(ui(nudge = true), Actions(), t0, "0.1.0", {})
    }

    @Test fun settingsSectionAutoBacked() = render("auth-settings-auto-backed-up", heightDp = 2300) {
        SettingsScreen(ui(auto = true, last = t0 - 86_400_000L * 3), Actions(), t0, "0.1.0", {})
    }

    @Test fun approveDialog() = render("auth-approve-mode-dialog", heightDp = 700) {
        ApproveModeDialog(AuthUi(approveMode = ApprovalPolicy.Mode.Auto, autoMinutes = 5), { _, _ -> }, {})
    }

    // ---------------------------------------------------------------- mocks

    @Composable private fun BottomSheetMock(body: @Composable () -> Unit) {
        Box(Modifier.fillMaxSize()) {
            Column(Modifier.align(Alignment.BottomCenter)) {
                Surface(shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp), color = MaterialTheme.colorScheme.surfaceContainerLow, tonalElevation = 1.dp) {
                    Column { Box(Modifier.align(Alignment.CenterHorizontally)) { BottomSheetDefaults.DragHandle() }; body() }
                }
            }
        }
    }

    @Composable private fun DialogMock(body: @Composable () -> Unit) {
        Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.scrim.copy(alpha = 0.32f)), contentAlignment = Alignment.Center) {
            Surface(Modifier.padding(24.dp), shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh, tonalElevation = 3.dp) { body() }
        }
    }

    @Composable private fun PageHeaderMock(title: String) {
        Text(title, Modifier.padding(start = 70.dp, top = 16.dp, bottom = 8.dp), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
    }

    @Composable private fun ApprovalNotificationMock(title: String, text: String, actions: Boolean = true) {
        val cs = MaterialTheme.colorScheme
        Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp), color = cs.surfaceContainerHigh, tonalElevation = 3.dp, shadowElevation = 4.dp) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(20.dp).background(cs.primary, RoundedCornerShape(50)))
                    Spacer(Modifier.width(8.dp))
                    Text("Mydroid · now", style = MaterialTheme.typography.labelMedium, color = cs.onSurfaceVariant)
                }
                Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                Text(text, style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
                if (actions) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton({}) { Text("Approve") }
                    TextButton({}) { Text("Deny") }
                }
            }
        }
    }
}
