package com.mydroid.protocol.auth

import com.mydroid.protocol.Message
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.Base64

/** PROTOCOL.md 14.4: `auth.import` parsing, duplicate skipping and the result message. All keys here are made up. */
class AuthImportTest {
    private val k1 = "JBSWY3DPEHPK3PXP"
    private val k2 = "GEZDGNBVGY3TQOJQGEZDGNBVGY"
    private val k3 = "MFRGGZDFMZTWQ2LKNNWG23TP"

    private fun otp(issuer: String, account: String, secret: String) = "otpauth://totp/$issuer:$account?secret=$secret&issuer=$issuer"
    private fun existing(secret: String, issuer: String = "Old", account: String = "me") = AuthEntry(issuer = issuer, account = account, secret = secret)

    // ---- migration encoder (same wire format Google writes)
    private fun varint(o: ByteArrayOutputStream, v: Long) { var x = v; while (x and 0x7F.toLong().inv() != 0L) { o.write(((x and 0x7F) or 0x80).toInt()); x = x ushr 7 }; o.write(x.toInt()) }
    private fun lenField(o: ByteArrayOutputStream, f: Int, b: ByteArray) { varint(o, (f shl 3 or 2).toLong()); varint(o, b.size.toLong()); o.write(b) }
    private fun intField(o: ByteArrayOutputStream, f: Int, v: Long) { varint(o, (f shl 3).toLong()); varint(o, v) }
    private fun params(secret: ByteArray, name: String, issuer: String, alg: Int = 1): ByteArray {
        val o = ByteArrayOutputStream()
        lenField(o, 1, secret); lenField(o, 2, name.toByteArray()); lenField(o, 3, issuer.toByteArray())
        intField(o, 4, alg.toLong()); intField(o, 5, 1); intField(o, 6, 2)
        return o.toByteArray()
    }
    private fun migration(items: List<ByteArray>, size: Int = 1, index: Int = 0): String {
        val o = ByteArrayOutputStream()
        items.forEach { lenField(o, 1, it) }
        intField(o, 2, 1); intField(o, 3, size.toLong()); intField(o, 4, index.toLong()); intField(o, 5, 7)
        return "otpauth-migration://offline?data=" + java.net.URLEncoder.encode(Base64.getEncoder().encodeToString(o.toByteArray()), "UTF-8")
    }

    // ---- planner

    @Test fun plansOtpauthUris() {
        val p = AuthImportPlanner.plan(listOf(otp("Salesforce", "me@work.com", k1), otp("GitHub", "octocat", k2)), emptyList())!!
        assertEquals(2, p.fresh.size); assertEquals(0, p.skipped)
        assertEquals(listOf(ImportItem("Salesforce", "me@work.com"), ImportItem("GitHub", "octocat")), p.items)
    }

    @Test fun plansGoogleMigrationAcrossBatches() {
        val a = migration(listOf(params("12345678901234567890".toByteArray(), "Salesforce:me@work.com", "Salesforce")), size = 2, index = 0)
        val b = migration(listOf(params("abcdefghij".toByteArray(), "octocat", "GitHub")), size = 2, index = 1)
        val p = AuthImportPlanner.plan(listOf(a, b), emptyList())!!
        assertEquals(listOf("Salesforce", "GitHub"), p.items.map { it.issuer })
    }

    @Test fun mixesOtpauthAndMigration() {
        val m = migration(listOf(params("12345678901234567890".toByteArray(), "x", "Mig")))
        assertEquals(2, AuthImportPlanner.plan(listOf(otp("A", "a", k1), m), emptyList())!!.fresh.size)
    }

    @Test fun skipsWhatTheVaultAlreadyHas() {
        // Same secret under another issuer and spelling (lower case, spaces) is still the same account.
        val p = AuthImportPlanner.plan(listOf(otp("Salesforce", "me@work.com", k1), otp("GitHub", "octocat", k2)), listOf(existing("jbsw y3dp ehpk 3pxp")))!!
        assertEquals(listOf("GitHub"), p.items.map { it.issuer }); assertEquals(1, p.skipped)
    }

    @Test fun skipsRepeatsInsideTheBatch() {
        val p = AuthImportPlanner.plan(listOf(otp("A", "a", k1), otp("A", "a", k1), otp("B", "b", k2)), emptyList())!!
        assertEquals(2, p.fresh.size); assertEquals(1, p.skipped)
    }

    @Test fun allDuplicatesIsAPlanWithNothingToAdd() {
        val p = AuthImportPlanner.plan(listOf(otp("A", "a", k1)), listOf(existing(k1)))!!
        assertEquals(0, p.fresh.size); assertEquals(1, p.skipped)
    }

    @Test fun nothingParsableIsNull() {
        assertNull(AuthImportPlanner.plan(emptyList(), emptyList()))
        assertNull(AuthImportPlanner.plan(listOf("hello", "https://example.com", "otpauth://totp/x?secret=!!!", "otpauth-migration://offline?data=@@@"), emptyList()))
    }

    @Test fun unreadableUrisCountAsSkippedWhenSomethingElseParsed() {
        val p = AuthImportPlanner.plan(listOf(otp("A", "a", k1), "otpauth://totp/x?secret=!!!", "hello"), emptyList())!!
        assertEquals(1, p.fresh.size); assertEquals(2, p.skipped)
    }

    @Test fun entriesGoogleCouldNotEncodeCountAsSkipped() {
        val md5 = params("12345678901234567890".toByteArray(), "old", "Old", alg = 4) // MD5 is unsupported
        val p = AuthImportPlanner.plan(listOf(migration(listOf(params("12345678901234567890".toByteArray(), "a", "A"), md5))), emptyList())!!
        assertEquals(1, p.fresh.size); assertEquals(1, p.skipped)
    }

    @Test fun limitsHoldAgainstAHostileMac() {
        val tooLong = "otpauth://totp/x?secret=$k1&issuer=" + "a".repeat(AuthImportWire.MAX_URI_CHARS)
        assertNull(AuthImportPlanner.plan(listOf(tooLong), emptyList()))
        val many = (0 until AuthImportWire.MAX_URIS + 10).map { otp("I$it", "a", Base32.encode("secret-number-$it".toByteArray())) }
        val p = AuthImportPlanner.plan(many, emptyList())!!
        assertEquals(AuthImportWire.MAX_URIS, p.fresh.size)
    }

    @Test fun reviewItemsNeverCarrySecrets() {
        val p = AuthImportPlanner.plan(listOf(otp("Salesforce", "me@work.com", k1)), emptyList())!!
        assertFalse(p.items.toString().contains(k1))
        assertFalse(p.toString().contains(k1)); assertFalse(p.fresh[0].toString().contains(k1))
    }

    @Test fun reviewTextIsCleaned() {
        val e = AuthEntry(issuer = "Evil\u0007\n Corp", account = "x".repeat(300), secret = k1)
        val item = ImportItem.of(e)
        assertEquals("Evil Corp", item.issuer); assertEquals(80, item.account.length)
        assertEquals("Account", ImportItem("", "").title)
        assertEquals("me", ImportItem("", "me").title); assertEquals("", ImportItem("", "me").subtitle)
        assertEquals("me", ImportItem("Acme", "me").subtitle)
    }

    // ---- wire

    private fun msg(vararg kv: Pair<String, JsonElement>) = Message.of(AuthImportWire.IMPORT) { kv.forEach { (k, v) -> put(k, v) } }

    @Test fun parsesRequest() {
        val r = AuthImportWire.parseRequest(msg("req" to JsonPrimitive("r1"), "uris" to JsonArray(listOf(JsonPrimitive("a"), JsonPrimitive("b")))))!!
        assertEquals("r1", r.req); assertEquals(listOf("a", "b"), r.uris)
    }

    @Test fun requestNeedsReqAndToleratesBadUris() {
        assertNull(AuthImportWire.parseRequest(msg("uris" to JsonArray(emptyList()))))
        assertNull(AuthImportWire.parseRequest(msg("req" to JsonPrimitive(""))))
        assertEquals(emptyList<String>(), AuthImportWire.parseRequest(msg("req" to JsonPrimitive("r")))!!.uris)
        assertEquals(listOf("a"), AuthImportWire.parseRequest(msg("req" to JsonPrimitive("r"), "uris" to JsonArray(listOf(JsonPrimitive("a"), JsonPrimitive(5), JsonObject(emptyMap())))))!!.uris)
        assertEquals("7", AuthImportWire.parseRequest(msg("req" to JsonPrimitive(7)))!!.req) // a numeric req is tolerated like the other auth messages
    }

    @Test fun requestCapsTheUriCount() {
        val many = JsonArray((0 until 500).map { JsonPrimitive("u$it") })
        assertEquals(AuthImportWire.MAX_URIS, AuthImportWire.parseRequest(msg("req" to JsonPrimitive("r"), "uris" to many))!!.uris.size)
    }

    @Test fun requestToStringHidesUris() {
        val r = AuthImportWire.parseRequest(msg("req" to JsonPrimitive("r"), "uris" to JsonArray(listOf(JsonPrimitive(otp("A", "a", k1))))))!!
        assertFalse(r.toString().contains(k1))
    }

    @Test fun resultMessage() {
        val ok = AuthImportWire.result("r1", true, 3, 1)
        assertEquals("auth.import.result", ok.type); assertEquals("r1", ok.str("req")); assertEquals(true, ok.bool("ok")); assertEquals(3, ok.int("added")); assertEquals(1, ok.int("skipped"))
        assertFalse(ok.header.containsKey("error"))
        val bad = AuthImportWire.result("r2", false, 0, 0, AuthImportWire.CANCELLED)
        assertEquals(false, bad.bool("ok")); assertEquals("cancelled", bad.str("error"))
        assertEquals("locked", AuthImportWire.LOCKED); assertEquals("invalid", AuthImportWire.INVALID)
    }

    @Test fun importIsOneOfTheAuthTypes() = assertTrue(AuthImportWire.IMPORT in AuthWire.TYPES)

    @Test fun timeoutIsTwoMinutes() = assertEquals(120_000L, AuthImportWire.TIMEOUT_MS)
}
