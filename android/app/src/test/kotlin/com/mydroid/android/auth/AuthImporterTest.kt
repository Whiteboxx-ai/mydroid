package com.mydroid.android.auth

import com.mydroid.android.transfers.ActivityEntry
import com.mydroid.protocol.Message
import com.mydroid.protocol.auth.*
import kotlinx.serialization.json.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLog
import java.io.File
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** `auth.import` on the phone (PROTOCOL.md 14.4): review, biometric-gated Add, Cancel, timeout. Keys and names are made up. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AuthImporterTest {
    @get:Rule val tmp = TemporaryFolder()

    private class PlainBox(private val failSeal: Boolean = false) : SecretBox {
        private val key = SecretKeySpec(ByteArray(32) { it.toByte() }, "AES")
        override fun seal(plain: ByteArray): ByteArray {
            if (failSeal) throw IllegalStateException("keystore gone")
            val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE, key); return c.iv + c.doFinal(plain)
        }
        override fun open(sealed: ByteArray): ByteArray? = try {
            val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, sealed, 0, 12)); c.doFinal(sealed, 12, sealed.size - 12)
        } catch (e: Exception) { null }
    }

    private class FakeSurface(var canShow: Boolean = true) : ImportSurface {
        var shown = 0; var lastCount = 0; var lastMac = ""; var dismissed = 0
        override fun show(count: Int, mac: String): Boolean { shown++; lastCount = count; lastMac = mac; return canShow }
        override fun dismiss() { dismissed++ }
    }

    private val k1 = "JBSWY3DPEHPK3PXP"
    private val k2 = "GEZDGNBVGY3TQOJQGEZDGNBVGY"
    private val k3 = "MFRGGZDFMZTWQ2LKNNWG23TP"
    private fun otp(issuer: String, account: String, secret: String) = "otpauth://totp/$issuer:$account?secret=$secret&issuer=$issuer"

    private val sent = ArrayList<Message>()
    private val records = ArrayList<ActivityEntry>()
    private val surface = FakeSurface()
    private var timer: (() -> Unit)? = null
    private var timerCancelled = false
    private var nudged = 0
    private var noBackup = true
    private lateinit var vault: AuthVault
    private lateinit var importer: AuthImporter

    private fun build(box: SecretBox = PlainBox(), file: File = File(tmp.root, "vault.bin")) {
        vault = AuthVault(file, box)
        importer = AuthImporter(
            vault, { sent += it; true }, { "gautamm's macbook air" }, surface, { records += it },
            onAdded = { nudged++; noBackup },
            schedule = { _, task -> timer = task; timerCancelled = false; { timerCancelled = true } },
        )
    }

    @Before fun setUp() { ShadowLog.clear(); build() }
    @After fun noSecretsInLogs() {
        val all = ShadowLog.getLogs().joinToString("\n") { it.msg }
        for (bad in listOf(k1, k2, k3, "Salesforce", "GitHub", "octocat", "me@work.com", "otpauth")) assertFalse("logged $bad", all.contains(bad))
    }

    private fun request(req: String, vararg uris: String) = Message.of("auth.import") { put("req", req); put("uris", JsonArray(uris.map { JsonPrimitive(it) })) }
    private fun last() = sent.last().also { assertEquals("auth.import.result", it.type) }

    @Test fun reviewShowsIssuerAndAccountOnlyAndWritesNothing() {
        importer.start(request("r1", otp("Salesforce", "me@work.com", k1), otp("GitHub", "octocat", k2)))
        val r = importer.review.value!!
        assertEquals("r1", r.req); assertEquals("Gautamm's macbook air", r.mac)
        assertEquals(listOf(ImportItem("Salesforce", "me@work.com"), ImportItem("GitHub", "octocat")), r.items)
        assertFalse(r.toString().contains(k1))
        assertEquals(1, surface.shown); assertEquals(2, surface.lastCount); assertEquals("Gautamm's macbook air", surface.lastMac)
        assertTrue("no answer until the user decides", sent.isEmpty())
        assertEquals(0, vault.count)
        assertNotNull("2 minute timer armed", timer)
    }

    @Test fun addPutsAccountsInTheVaultAndReplies() {
        importer.start(request("r1", otp("Salesforce", "me@work.com", k1), otp("GitHub", "octocat", k2)))
        val done = importer.confirm("r1")!!
        assertEquals(2, done.added); assertEquals(0, done.skipped); assertTrue(done.needsBackup)
        assertEquals(setOf("Salesforce", "GitHub"), vault.all().map { it.issuer }.toSet())
        val m = last()
        assertEquals("r1", m.str("req")); assertEquals(true, m.bool("ok")); assertEquals(2, m.int("added")); assertEquals(0, m.int("skipped")); assertNull(m.str("error"))
        assertNull(importer.review.value); assertTrue(timerCancelled); assertEquals(1, nudged); assertEquals(1, surface.dismissed)
        assertEquals("Added 2 accounts from Gautamm's macbook air", records.single().title)
        assertFalse(records.joinToString { it.title + it.detail }.contains("Salesforce"))
    }

    @Test fun addOneIsSingular() {
        importer.start(request("r1", otp("A", "a", k1)))
        importer.confirm("r1")
        assertEquals("Added 1 account from Gautamm's macbook air", records.single().title)
    }

    @Test fun duplicatesAreSkippedAndCounted() {
        vault.add(listOf(AuthEntry(issuer = "Old", account = "me", secret = k1)))
        importer.start(request("r1", otp("Salesforce", "me@work.com", k1), otp("GitHub", "octocat", k2)))
        assertEquals(listOf("GitHub"), importer.review.value!!.items.map { it.issuer }); assertEquals(1, importer.review.value!!.skipped); assertEquals(1, surface.lastCount)
        importer.confirm("r1")
        assertEquals(2, vault.count)
        assertEquals(1, last().int("added")); assertEquals(1, last().int("skipped"))
    }

    @Test fun everythingAlreadyHereAnswersAtOnceWithoutAsking() {
        vault.add(listOf(AuthEntry(issuer = "Old", account = "me", secret = k1)))
        importer.start(request("r1", otp("Salesforce", "me@work.com", k1)))
        assertEquals(0, surface.shown); assertNull(importer.review.value)
        val m = last(); assertEquals(true, m.bool("ok")); assertEquals(0, m.int("added")); assertEquals(1, m.int("skipped"))
    }

    @Test fun cancelAnswersCancelledAndAddsNothing() {
        importer.start(request("r1", otp("Salesforce", "me@work.com", k1)))
        importer.cancel("r1")
        val m = last(); assertEquals(false, m.bool("ok")); assertEquals("cancelled", m.str("error")); assertEquals(0, m.int("added"))
        assertEquals(0, vault.count); assertNull(importer.review.value); assertEquals(1, surface.dismissed); assertTrue(timerCancelled)
        assertNull("Add after Cancel does nothing", importer.confirm("r1")); assertEquals(0, vault.count); assertEquals(1, sent.size)
    }

    @Test fun cancelFromTheNotificationWithoutAReq() {
        importer.start(request("r9", otp("A", "a", k1)))
        importer.cancel()
        assertEquals("cancelled", last().str("error")); assertEquals("r9", last().str("req"))
    }

    @Test fun timesOutAfterTwoMinutesAsCancelled() {
        importer.start(request("r1", otp("A", "a", k1)))
        assertEquals(120_000L, AuthImportWire.TIMEOUT_MS)
        timer!!.invoke()
        assertEquals("cancelled", last().str("error")); assertNull(importer.review.value); assertEquals(0, vault.count)
        assertNull(importer.confirm("r1"))
    }

    @Test fun timerIsArmedForTwoMinutes() {
        var delay = -1L
        importer = AuthImporter(vault, { sent += it; true }, { "mac" }, surface, { }, { false }, schedule = { ms, _ -> delay = ms; {} })
        importer.start(request("r1", otp("A", "a", k1)))
        assertEquals(120_000L, delay)
    }

    @Test fun nothingParsableIsInvalid() {
        importer.start(request("r1", "hello", "https://example.com"))
        val m = last(); assertEquals(false, m.bool("ok")); assertEquals("invalid", m.str("error")); assertEquals(0, surface.shown); assertNull(importer.review.value)
        sent.clear(); importer.start(request("r2"))
        assertEquals("invalid", last().str("error"))
    }

    @Test fun unreadableVaultIsLocked() {
        val f = File(tmp.root, "bad.bin"); f.writeBytes(ByteArray(64) { 7 })
        build(file = f)
        importer.start(request("r1", otp("A", "a", k1)))
        assertEquals("locked", last().str("error")); assertEquals(0, surface.shown)
    }

    @Test fun lockoutDuringAddIsLocked() {
        importer.start(request("r1", otp("A", "a", k1)))
        importer.fail("r1", AuthImportWire.LOCKED)
        assertEquals("locked", last().str("error")); assertEquals(0, vault.count); assertNull(importer.review.value)
        assertTrue(AuthGate.isLockout(7)); assertTrue(AuthGate.isLockout(9)); assertFalse(AuthGate.isLockout(10)); assertFalse(AuthGate.isLockout(13))
    }

    @Test fun aSecondImportWhileOneIsOpenIsCancelledAndTheFirstSurvives() {
        importer.start(request("r1", otp("A", "a", k1)))
        importer.start(request("r2", otp("B", "b", k2)))
        assertEquals("r2", last().str("req")); assertEquals("cancelled", last().str("error"))
        assertEquals("r1", importer.review.value!!.req); assertEquals(1, surface.shown)
        importer.confirm("r1")
        assertEquals(listOf("A"), vault.all().map { it.issuer })
    }

    @Test fun nothingToShowTheUserMeansCancelled() {
        surface.canShow = false
        importer.start(request("r1", otp("A", "a", k1)))
        assertEquals("cancelled", last().str("error")); assertNull(importer.review.value); assertEquals(0, vault.count)
        assertNull(importer.confirm("r1"))
    }

    @Test fun lostConnectionDropsTheSecretsQuietly() {
        importer.start(request("r1", otp("A", "a", k1)))
        importer.onDisconnected()
        assertNull(importer.review.value); assertTrue(sent.isEmpty()); assertEquals(1, surface.dismissed); assertTrue(timerCancelled)
        assertNull(importer.confirm("r1")); assertEquals(0, vault.count)
        importer.onDisconnected() // nothing open: harmless
    }

    @Test fun aVaultThatCantBeWrittenIsLockedAndNothingIsClaimedAdded() {
        build(box = PlainBox(failSeal = true))
        importer.start(request("r1", otp("A", "a", k1)))
        assertNull(importer.confirm("r1"))
        assertEquals("locked", last().str("error")); assertEquals(0, last().int("added")); assertEquals(0, nudged)
    }

    @Test fun wrongReqCantConfirmAnotherImport() {
        importer.start(request("r1", otp("A", "a", k1)))
        assertNull(importer.confirm("other")); assertEquals(0, vault.count); assertNotNull(importer.review.value)
    }

    @Test fun backupNudgeOnlyWhenThereIsNoBackup() {
        noBackup = false
        importer.start(request("r1", otp("A", "a", k1)))
        assertFalse(importer.confirm("r1")!!.needsBackup)
    }

    @Test fun repliesNeverCarrySecretsOrNames() {
        importer.start(request("r1", otp("Salesforce", "me@work.com", k1), "garbage"))
        importer.confirm("r1")
        val wire = sent.joinToString { it.header.toString() }
        for (bad in listOf(k1, "Salesforce", "me@work.com")) assertFalse(wire.contains(bad))
        assertEquals(1, last().int("skipped"))
    }
}
