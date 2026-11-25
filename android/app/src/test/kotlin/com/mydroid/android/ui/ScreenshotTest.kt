package com.mydroid.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.unit.dp
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.Density
import com.github.takahirom.roborazzi.captureRoboImage
import com.mydroid.android.Feature
import com.mydroid.android.FeatureReport
import com.mydroid.android.FeatureState
import com.mydroid.android.callaudio.CallAudioState
import com.mydroid.android.callaudio.CallAudioStatus
import com.mydroid.android.data.Settings
import com.mydroid.android.net.Link
import com.mydroid.android.net.UiState
import com.mydroid.android.mac.MacUi
import com.mydroid.android.presence.PresenceStatus
import com.mydroid.android.remote.RemoteApi
import com.mydroid.android.walkaway.WalkAwayStatus
import com.mydroid.android.mac.AppsUi
import com.mydroid.protocol.FsEntry
import com.mydroid.protocol.FsHit
import com.mydroid.protocol.MacApp
import com.mydroid.protocol.MacMediaState
import com.mydroid.protocol.MacStatus
import com.mydroid.protocol.PresentInfo
import com.mydroid.protocol.Presenting
import com.mydroid.protocol.RemoteState
import com.mydroid.android.transfers.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowBuild
import java.io.File

/** JVM screenshots of the real screens with fake state. Output: `render.dir` (see app/build.gradle.kts). */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w360dp-h900dp-xxhdpi")
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
class ScreenshotTest(private val dark: Boolean) {
    companion object {
        @JvmStatic @Parameters(name = "dark={0}") fun modes() = listOf(arrayOf<Any>(false), arrayOf<Any>(true))
    }

    @get:Rule val rule = createComposeRule()

    private val now = 1_800_000_000_000L
    private val min = 60_000L

    /** Renders [content] with the theme for this run's mode (light or dark). */
    private fun render(name: String, heightDp: Int = 900, fontScale: Float = 1f, dynamic: Boolean = true, content: @Composable () -> Unit) {
        RuntimeEnvironment.setQualifiers("+w360dp-h${heightDp}dp-xxhdpi")
        rule.mainClock.autoAdvance = false
        rule.setContent {
            val d = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(d.density, fontScale)) {
                MydroidTheme(dark = dark, dynamic = dynamic) {
                    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) { Box(Modifier.fillMaxSize()) { content() } }
                }
            }
        }
        rule.mainClock.advanceTimeBy(1000)
        val dir = File(System.getProperty("render.dir")!!).apply { mkdirs() }
        rule.onRoot().captureRoboImage(File(dir, "$name-${if (dark) "dark" else "light"}.png").path)
    }

    private fun both(name: String, heightDp: Int = 900, fontScale: Float = 1f, content: @Composable () -> Unit) =
        render(name, heightDp, fontScale, content = content)

    // ---------------------------------------------------------------- fake state

    private val allOn = FeatureReport(
        states = Feature.entries.associateWith { FeatureState.On },
        otp = FeatureState.On, dial = true, presence = PresenceStatus.Ready, codesFromApps = true,
        callAudio = CallAudioStatus(CallAudioState.On), callAudioEver = true,
    )
    private val settings = Settings(notifications = true, photos = true, calls = true, clipboard = true, smsHistory = true)

    private val recent = listOf(
        ActivityEntry("1", Direction.ToMac, Kind.File, "IMG_4821.jpg", "3.2 MB", now - 2 * min),
        ActivityEntry("2", Direction.ToMac, Kind.Link, "github.com", null, now - 14 * min),
        ActivityEntry("3", Direction.FromMac, Kind.File, "Boarding pass.pdf", "184 KB", now - 52 * min),
        ActivityEntry("4", Direction.ToMac, Kind.Text, "Text", "142 characters", now - 3 * 60 * min),
        ActivityEntry("5", Direction.ToMac, Kind.File, "Trip video.mov", "Your Mac couldn't save it", now - 5 * 60 * min, ok = false),
    )
    private val photoTimes = List(12) { now - 40_000L * it - 5 * min }.reversed()

    private fun connected(report: FeatureReport = allOn, t: TransfersState = TransfersState(recent = recent, photoTimes = photoTimes)) = UiState(
        link = Link.Connected, macName = "Gautamm’s MacBook Air", lastSeen = now, settings = settings, report = report,
        setupDone = true, transfers = t, photosWaiting = 0,
    )

    private val macUi = MacUi(
        remote = RemoteState(accessibility = true, presenting = null),
        status = MacStatus("Gautamm’s MacBook Air", "Mac14,2", battery = 82, charging = true, locked = false, displayAsleep = false),
        shortcuts = listOf("Night mode", "Start focus", "Resize windows", "Send to Notes", "Tidy desktop", "Morning routine", "Quiet the Mac"),
        favorites = listOf("Night mode", "Start focus"),
    )

    // ---------------------------------------------------------------- Home

    @Test fun homeAllWell() = both("home-connected-ok") { HomeScreen(connected(), Actions(), now, {}, animate = false) }

    @Test fun homeAttention() = both("home-attention-2") {
        val r = allOn.copy(states = allOn.states + (Feature.Photos to FeatureState.NeedsPermission), backgroundRestricted = true)
        HomeScreen(connected(r), Actions(), now, {}, animate = false)
    }

    @Test fun homeAttentionOne() = both("home-attention-1") {
        HomeScreen(connected(allOn.copy(photosPartial = true)), Actions(), now, {}, animate = false)
    }

    @Test fun homeDisconnected() = both("home-disconnected") {
        HomeScreen(connected().copy(link = Link.Searching, lastSeen = now - 25 * min), Actions(), now, {}, animate = false)
    }

    @Test fun homeTransfers() = both("home-transfers", heightDp = 1100) {
        val t = TransfersState(
            live = listOf(LiveTransfer("a", "IMG_20261122_184501.jpg", 12_400_000, 48_000_000), LiveTransfer("b", "Quarterly report FY26 final v3.pdf", 1_000_000, 18_000_000)),
            queued = listOf(QueuedItem("c", Kind.File, "Holiday.mov", 210_000_000)),
            recent = recent.take(3), photoTimes = photoTimes,
        )
        HomeScreen(connected(t = t).copy(photosWaiting = 3), Actions(), now, {}, animate = false)
    }

    @Test fun homeOfflineQueued() = both("home-offline-queued", heightDp = 1100) {
        val t = TransfersState(queued = listOf(QueuedItem("c", Kind.File, "Holiday.mov", 210_000_000), QueuedItem("text", Kind.Link, "github.com")), recent = recent.take(2))
        HomeScreen(connected(t = t).copy(link = Link.Searching, lastSeen = now - 8 * min), Actions(), now, {}, animate = false)
    }

    @Test fun homeEmpty() = both("home-empty-activity", heightDp = 1250) {
        HomeScreen(connected(t = TransfersState()), Actions(), now, {}, animate = false)
    }

    @Test fun homeLargeFont() = both("home-attention-fontscale1.3", heightDp = 1500, fontScale = 1.3f) {
        val r = allOn.copy(states = allOn.states + (Feature.Photos to FeatureState.NeedsPermission), backgroundRestricted = true)
        HomeScreen(connected(r, TransfersState(
            live = listOf(LiveTransfer("a", "IMG_20261122_184501.jpg", 12_400_000, 48_000_000)), recent = recent, photoTimes = photoTimes)), Actions(), now, {}, animate = false)
    }

    // ---------------------------------------------------------------- Your Mac card (quick actions)

    @Test fun macCardActions() = both("mac-card-actions", heightDp = 1250) {
        HomeScreen(connected().copy(mac = macUi), Actions(), now, {}, animate = false)
    }

    @Test fun macCardLockedRinging() = both("mac-card-locked-ringing", heightDp = 1250) {
        val m = macUi.copy(status = macUi.status!!.copy(locked = true, charging = false, battery = 14), ringing = true, favorites = listOf("Night mode", "Start focus", "Resize windows", "Quiet the Mac"))
        HomeScreen(connected().copy(mac = m), Actions(), now, {}, animate = false)
    }

    @Test fun macCardAway() = both("mac-card-away", heightDp = 1250) {
        HomeScreen(connected().copy(link = Link.Searching, lastSeen = now - 8 * min, mac = MacUi(favorites = macUi.favorites)), Actions(), now, {}, animate = false)
    }

    @Test fun shortcutsSheet() = both("shortcuts-sheet", heightDp = 760) {
        Box(Modifier.fillMaxSize()) {
            androidx.compose.foundation.layout.Column(Modifier.align(androidx.compose.ui.Alignment.BottomCenter)) {
                Surface(shape = androidx.compose.foundation.shape.RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp), color = MaterialTheme.colorScheme.surfaceContainerLow, tonalElevation = 1.dp) {
                    androidx.compose.foundation.layout.Column {
                        androidx.compose.foundation.layout.Box(Modifier.align(androidx.compose.ui.Alignment.CenterHorizontally)) { androidx.compose.material3.BottomSheetDefaults.DragHandle() }
                        ShortcutsContent(macUi, {}, {}, {})
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- Remote

    private val timerStart = now - (12 * 60 + 34) * 1000L

    private fun remote(tab: RemoteTab, mac: MacUi = macUi, s: UiState = connected().copy(mac = mac), hits: List<FsHit>? = null) =
        @Composable { RemoteScreen(s, object : RemoteApi by RemoteApi.None { override val laserPreview = true }, tab, {}, {}, timerStart, {}, now, hits) }

    private fun hit(name: String, path: String, ageDays: Int) = FsHit("docs", path, FsEntry(name, false, 1000, now - ageDays * 86_400_000L, "application/octet-stream"))
    private val sampleHits = listOf(
        hit("Q3 Review.key", "Work/Q3 Review.key", 0), hit("Product Launch.pptx", "Downloads/Product Launch.pptx", 1), hit("Team Offsite.key", "Documents/Team Offsite.key", 3),
        hit("Investor Update.pdf", "Documents/Investor Update.pdf", 11), hit("Flight itinerary.pdf", "Downloads/Flight itinerary.pdf", 0), hit("Screenshot 9.41.png", "Desktop/Screenshot 9.41.png", 1),
    )
    private fun app(id: String, name: String) = MacApp(id, name)

    /** A cover with a few clear colours, as PNG bytes, so the wash has something to pick from. */
    private fun sampleCover(): ByteArray {
        val bmp = android.graphics.Bitmap.createBitmap(120, 120, android.graphics.Bitmap.Config.ARGB_8888)
        val c = android.graphics.Canvas(bmp)
        val p = android.graphics.Paint()
        p.color = 0xFF3A2D7C.toInt(); c.drawRect(0f, 0f, 120f, 120f, p)
        p.color = 0xFFC4577F.toInt(); c.drawCircle(40f, 46f, 52f, p)
        p.color = 0xFF31748F.toInt(); c.drawCircle(88f, 90f, 40f, p)
        p.color = 0xFFF6C177.toInt(); c.drawCircle(34f, 34f, 14f, p)
        val out = java.io.ByteArrayOutputStream()
        bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    @Test fun remoteTrackpad() = both("remote-trackpad") { remote(RemoteTab.Pad)() }

    @Test fun remotePresentStart() = both("remote-present-start") { remote(RemoteTab.Present, hits = sampleHits)() }

    @Test fun remotePresentLive() = both("remote-present-live") {
        remote(RemoteTab.Present, macUi.copy(
            remote = RemoteState(true, Presenting("Keynote")),
            present = PresentInfo(true, "Keynote", 7, 24, "Pause here and let the chart land. Then walk left to right, ending on the dark bar. Ask if anyone wants the breakdown before moving on.", "Revenue by region"),
        ))()
    }

    @Test fun remotePresentLiveNeedsAutomation() = both("remote-present-live-automation") {
        remote(RemoteTab.Present, macUi.copy(remote = RemoteState(true, Presenting("Keynote")), present = PresentInfo(true, "Keynote", error = "automation")))()
    }

    @Test fun remotePlaying() = both("remote-playing") {
        remote(RemoteTab.Playing, macUi.copy(media = MacMediaState(true, "Music", "Slow Tide", "Northern Lights", "Blue Hour", true, 102_000, 238_000, now, true, sampleCover(), 0.58)))()
    }

    @Test fun remotePlayingNothing() = both("remote-playing-empty") { remote(RemoteTab.Playing, macUi.copy(media = MacMediaState(active = false, volume = 0.4)))() }

    @Test fun remotePlayingNeedsAutomation() = both("remote-playing-automation") { remote(RemoteTab.Playing, macUi.copy(media = MacMediaState(active = false, error = "automation")))() }

    @Test fun remoteOpen() = both("remote-open") {
        remote(RemoteTab.Open, macUi.copy(apps = AppsUi(
            running = listOf(app("com.apple.Keynote", "Keynote"), app("com.apple.Safari", "Safari"), app("com.apple.Music", "Music"), app("com.apple.finder", "Finder"), app("com.apple.Terminal", "Terminal")),
            installed = emptyList(),
        )), hits = sampleHits)()
    }

    @Test fun remotePresenter() = both("remote-presenter") {
        remote(RemoteTab.Present, macUi.copy(remote = RemoteState(true, Presenting("Keynote"))))()
    }

    @Test fun remoteMedia() = both("remote-media") { remote(RemoteTab.Playing)() }

    @Test fun remoteNeedsAccessibility() = both("remote-needs-accessibility") {
        remote(RemoteTab.Pad, macUi.copy(remote = RemoteState(accessibility = false, presenting = null)))()
    }

    @Test fun remoteNeedsAccessibilityPresenter() = both("remote-needs-accessibility-presenter") {
        remote(RemoteTab.Present, macUi.copy(remote = RemoteState(accessibility = false, presenting = null)))()
    }

    @Test fun remoteMacAway() = both("remote-mac-away") {
        remote(RemoteTab.Playing, MacUi(), connected().copy(link = Link.Searching))()
    }

    @Test fun remotePresenterLargeFont() = both("remote-presenter-fontscale1.3", heightDp = 740, fontScale = 1.3f) {
        remote(RemoteTab.Present, macUi.copy(remote = RemoteState(true, Presenting("Keynote"))))()
    }

    // ---------------------------------------------------------------- text sheet

    @Test fun textSheet() = both("send-text-sheet", heightDp = 560) {
        Box(Modifier.fillMaxSize()) {
            androidx.compose.foundation.layout.Column(Modifier.align(androidx.compose.ui.Alignment.BottomCenter)) {
                Surface(shape = androidx.compose.foundation.shape.RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp), color = MaterialTheme.colorScheme.surfaceContainerLow, tonalElevation = 1.dp) {
                  androidx.compose.foundation.layout.Column {
                    androidx.compose.foundation.layout.Box(Modifier.align(androidx.compose.ui.Alignment.CenterHorizontally)) { androidx.compose.material3.BottomSheetDefaults.DragHandle() }
                    SendTextContent(connected = true, macName = "Gautamm’s MacBook Air", onSend = {}, initial = "https://example.com/trip-plan")
                  }
                }
            }
        }
    }

    // ---------------------------------------------------------------- Settings

    @Test fun settings() = both("settings", heightDp = 2100) { SettingsScreen(connected(), Actions(), now, "0.1.0", {}) }

    @Test fun settingsWalkAway() = both("settings-walkaway-needs-permission", heightDp = 1800) {
        val s = connected(allOn.copy(walkAway = WalkAwayStatus.NeedsPermission)).copy(settings = settings.copy(walkAway = true))
        SettingsScreen(s, Actions(), now, "0.1.0", {})
    }

    @Test fun settingsAttention() = both("settings-attention", heightDp = 2300, fontScale = 1.3f) {
        val r = allOn.copy(
            states = allOn.states + (Feature.Notifications to FeatureState.NeedsPermission) + (Feature.Photos to FeatureState.NeedsPermission),
            otp = FeatureState.NeedsPermission, backgroundRestricted = true, codesFromApps = false, presence = PresenceStatus.NeedsAssociation,
            callAudio = CallAudioStatus(CallAudioState.NeedsSetup), callAudioEver = false,
        )
        SettingsScreen(connected(r), Actions(), now, "0.1.0", {})
    }

    @Test fun settingsFeaturesOff() = both("settings-features-off", heightDp = 1100) {
        SettingsScreen(connected().copy(settings = Settings()), Actions(), now, "0.1.0", {})
    }

    @Test fun infoSheet() = both("info-sheet", heightDp = 420) {
        Box(Modifier.fillMaxSize()) {
            androidx.compose.foundation.layout.Column(Modifier.align(androidx.compose.ui.Alignment.BottomCenter)) {
                Surface(shape = androidx.compose.foundation.shape.RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp), color = MaterialTheme.colorScheme.surfaceContainerLow, tonalElevation = 1.dp) {
                    androidx.compose.foundation.layout.Column {
                        androidx.compose.foundation.layout.Box(Modifier.align(androidx.compose.ui.Alignment.CenterHorizontally)) { androidx.compose.material3.BottomSheetDefaults.DragHandle() }
                        InfoSheetContent(Info("Instant copy", "Sends text the moment you tap Copy. It uses Android's accessibility permission. Some banking and UPI apps show a security warning while it's on."))
                    }
                }
            }
        }
    }

    @Test fun shortcutsEmpty() = both("shortcuts-empty", heightDp = 520) {
        Box(Modifier.fillMaxSize()) {
            androidx.compose.foundation.layout.Column(Modifier.align(androidx.compose.ui.Alignment.BottomCenter)) {
                Surface(shape = androidx.compose.foundation.shape.RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp), color = MaterialTheme.colorScheme.surfaceContainerLow, tonalElevation = 1.dp) {
                    ShortcutsContent(macUi.copy(shortcuts = emptyList()), {}, {}, {})
                }
            }
        }
    }

    // ---------------------------------------------------------------- Onboarding

    @Test fun welcome() = both("welcome", heightDp = 740) { WelcomeScreen(UiState(link = Link.Unpaired), Actions()) }

    @Test fun welcomeError() = both("welcome-error-1.3x", heightDp = 740, fontScale = 1.3f) {
        WelcomeScreen(UiState(link = Link.Unpaired, message = "Can't reach your Mac. Use the same Wi-Fi."), Actions())
    }

    @Test fun permissions() = both("permissions", heightDp = 900) {
        val r = allOn.copy(
            states = allOn.states + (Feature.Photos to FeatureState.NeedsPermission) + (Feature.Calls to FeatureState.NeedsPermission),
            dial = false, backgroundRestricted = true, presence = PresenceStatus.NeedsPermission, codesFromApps = false,
        )
        PermissionsScreen(connected(r).copy(setupDone = false), Actions())
    }

    @Test fun permissionsLargeFont() = both("permissions-fontscale1.3", heightDp = 1300, fontScale = 1.3f) {
        val r = allOn.copy(states = allOn.states + (Feature.Photos to FeatureState.NeedsPermission), backgroundRestricted = true, presence = PresenceStatus.NeedsPermission, codesFromApps = false)
        PermissionsScreen(connected(r).copy(setupDone = false), Actions())
    }

    @Test fun setupSkipsUnsupportedPhoneFeaturesAndLetsUsersSkipIndividualSteps() {
        val report = FeatureReport(
            states = Feature.entries.associateWith { FeatureState.NeedsPermission },
            supportsCalls = false,
            supportsTexts = false,
        )
        rule.setContent {
            MydroidTheme { PermissionsScreen(connected(report).copy(setupDone = false), Actions()) }
        }
        rule.onNodeWithText("Open notification access").assertExists()
        rule.onNodeWithText("Open app info").assertDoesNotExist()
        rule.onNodeWithText("Skip this step").performClick()
        rule.onNodeWithText("Camera roll").assertExists()
        rule.onNodeWithText("Skip this step").performClick()
        rule.onNodeWithText("All set").assertExists()
        rule.onNodeWithText("Continue").assertExists()
    }

    @Test fun onePlusIdleSetupIsOptionalWhenAndroidReportsNoRestriction() {
        ShadowBuild.setManufacturer("OnePlus")
        val state = connected().copy(settings = Settings(), setupDone = false)
        rule.setContent { MydroidTheme { PermissionsScreen(state, Actions()) } }
        rule.onNodeWithText("Allow while idle").assertExists()
        rule.onNodeWithText("Skip this step").performClick()
        rule.onNodeWithText("All set").assertExists()
    }

    // ---------------------------------------------------------------- Pairing

    @Test fun confirm() = both("confirm-360dp-1.3x", heightDp = 740, fontScale = 1.3f) {
        ConfirmScreen(UiState(link = Link.Confirm, code = "482 913"), Actions())
    }
}
