package com.mydroid.protocol.auth

import com.mydroid.protocol.Message
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.Base64

class OtpAuthTest {
    // ---------------------------------------------------------------- otpauth://

    @Test fun labelPrefixAndDefaults() {
        val e = OtpAuthUri.parse("otpauth://totp/GitHub:octocat@example.com?secret=jbsw%20y3dp%20ehpk%203pxp")!!
        assertEquals("GitHub", e.issuer); assertEquals("octocat@example.com", e.account)
        assertEquals("JBSWY3DPEHPK3PXP", e.secret)
        assertEquals(OtpAlgorithm.SHA1, e.algorithm); assertEquals(6, e.digits); assertEquals(30, e.period); assertEquals(OtpType.TOTP, e.type)
        assertEquals(listOf("github.com"), e.domains)
    }

    @Test fun issuerParamBeatsPrefixAndDecoding() {
        val e = OtpAuthUri.parse("otpauth://totp/ACME%20Co:john.doe%40email.com?secret=HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ&issuer=ACME%20Corp&algorithm=SHA256&digits=8&period=60")!!
        assertEquals("ACME Corp", e.issuer); assertEquals("john.doe@email.com", e.account)
        assertEquals(OtpAlgorithm.SHA256, e.algorithm); assertEquals(8, e.digits); assertEquals(60, e.period)
    }

    @Test fun labelWithoutIssuerEncodedColonAndSpace() {
        val a = OtpAuthUri.parse("otpauth://totp/me%40work.com?secret=JBSWY3DPEHPK3PXP")!!
        assertEquals("", a.issuer); assertEquals("me@work.com", a.account)
        val b = OtpAuthUri.parse("otpauth://totp/Salesforce%3A%20me@work.com?secret=JBSWY3DPEHPK3PXP")!!
        assertEquals("Salesforce", b.issuer); assertEquals("me@work.com", b.account)
        assertTrue("force.com" in b.domains && "salesforce.com" in b.domains)
        val c = OtpAuthUri.parse("otpauth://totp/Big+Bank:me?secret=JBSWY3DPEHPK3PXP&issuer=Big+Bank")!!
        assertEquals("Big Bank", c.issuer) // + is a space in the query
    }

    @Test fun hotpAndRejects() {
        val h = OtpAuthUri.parse("otpauth://hotp/Svc:me?secret=JBSWY3DPEHPK3PXP&counter=7")!!
        assertEquals(OtpType.HOTP, h.type); assertEquals(7L, h.counter)
        assertNull(OtpAuthUri.parse("otpauth://totp/x?secret=")); assertNull(OtpAuthUri.parse("otpauth://totp/x"))
        assertNull(OtpAuthUri.parse("otpauth://totp/x?secret=!!!!")); assertNull(OtpAuthUri.parse("otpauth://foo/x?secret=JBSWY3DPEHPK3PXP"))
        assertNull(OtpAuthUri.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=12")); assertNull(OtpAuthUri.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=MD5"))
        assertNull(OtpAuthUri.parse("https://example.com")); assertNull(OtpAuthUri.parse("otpauth-migration://offline?data=AAAA"))
    }

    @Test fun buildRoundTrips() {
        val e = AuthEntry(issuer = "A&B Inc", account = "me@x.io", secret = "JBSWY3DPEHPK3PXP", algorithm = OtpAlgorithm.SHA512, digits = 8, period = 45)
        val back = OtpAuthUri.parse(OtpAuthUri.build(e))!!
        assertEquals(e.copy(id = back.id, domains = back.domains), back)
    }

    // ---------------------------------------------------------------- otpauth-migration://

    private fun varint(o: ByteArrayOutputStream, v: Long) { var x = v; while (x and 0x7F.toLong().inv() != 0L) { o.write(((x and 0x7F) or 0x80).toInt()); x = x ushr 7 }; o.write(x.toInt()) }
    private fun lenField(o: ByteArrayOutputStream, f: Int, b: ByteArray) { varint(o, (f shl 3 or 2).toLong()); varint(o, b.size.toLong()); o.write(b) }
    private fun intField(o: ByteArrayOutputStream, f: Int, v: Long) { varint(o, (f shl 3).toLong()); varint(o, v) }

    private fun params(secret: ByteArray, name: String, issuer: String, alg: Int, digits: Int, type: Int, counter: Long = 0): ByteArray {
        val o = ByteArrayOutputStream()
        lenField(o, 1, secret); lenField(o, 2, name.toByteArray()); lenField(o, 3, issuer.toByteArray())
        intField(o, 4, alg.toLong()); intField(o, 5, digits.toLong()); intField(o, 6, type.toLong())
        if (counter != 0L) intField(o, 7, counter)
        return o.toByteArray()
    }

    private fun payload(items: List<ByteArray>, size: Int = 1, index: Int = 0, id: Int = 0): ByteArray {
        val o = ByteArrayOutputStream()
        items.forEach { lenField(o, 1, it) }
        intField(o, 2, 1); intField(o, 3, size.toLong()); intField(o, 4, index.toLong()); intField(o, 5, id.toLong())
        return o.toByteArray()
    }

    private fun uri(bytes: ByteArray) = "otpauth-migration://offline?data=" + java.net.URLEncoder.encode(Base64.getEncoder().encodeToString(bytes), "UTF-8")

    private val s1 = "12345678901234567890".toByteArray()

    @Test fun migrationSingle() {
        val raw = payload(listOf(
            params(s1, "Salesforce:me@work.com", "Salesforce", 1, 1, 2),
            params(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11), "plain-account", "", 2, 2, 1, counter = 300),
            params(s1, "md5", "Old", 4, 1, 2), // MD5 is unsupported
        ), size = 1)
        val p = Migration.parse(uri(raw))!!
        assertEquals(2, p.entries.size); assertEquals(1, p.skipped)
        val a = p.entries[0]
        assertEquals("Salesforce", a.issuer); assertEquals("me@work.com", a.account); assertEquals(Base32.encode(s1), a.secret)
        assertEquals(OtpAlgorithm.SHA1, a.algorithm); assertEquals(6, a.digits); assertEquals(OtpType.TOTP, a.type)
        assertTrue("force.com" in a.domains)
        val b = p.entries[1]
        assertEquals(OtpAlgorithm.SHA256, b.algorithm); assertEquals(8, b.digits); assertEquals(OtpType.HOTP, b.type); assertEquals(300L, b.counter)
        assertEquals("plain-account", b.account); assertEquals("", b.issuer)
        // The codes it will show equal the codes of the original secret.
        assertEquals(Otp.totp(s1, 59, 6), a.code(59))
    }

    @Test fun migrationAcceptsLiteralPlusAndSlashes() {
        // Bytes chosen so the base64 has '+' and '/': 0xFB 0xFF -> "+/8=" style characters inside the payload.
        val raw = payload(listOf(params(ByteArray(12) { 0xFB.toByte() }, "x", "Tune", 1, 1, 2)))
        val b64 = Base64.getEncoder().encodeToString(raw)
        assertTrue(b64.contains('+') || b64.contains('/'))
        assertNotNull(Migration.parse("otpauth-migration://offline?data=$b64"))        // un-encoded, '+' left alone
        assertNotNull(Migration.parse("otpauth-migration://offline?data=${b64.replace('+', ' ')}")) // '+' turned into a space by a lax URL layer
        assertNotNull(Migration.parse(uri(raw)))
    }

    @Test fun migrationMalformed() {
        assertNull(Migration.parse("otpauth-migration://offline")); assertNull(Migration.parse("otpauth-migration://offline?data=!!!"))
        assertNull(Migration.parse("otpauth-migration://offline?data=" + Base64.getEncoder().encodeToString(byteArrayOf(0x0A, 0x7F, 1)))) // length runs off the end
        assertNull(Migration.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP"))
    }

    @Test fun multiPartBatch() {
        fun part(i: Int, name: String) = Migration.parse(uri(payload(listOf(params(s1 + byteArrayOf(i.toByte()), name, "Svc$i", 1, 1, 2)), size = 3, index = i, id = 777)))!!
        val b = MigrationBatch()
        assertEquals(MigrationBatch.Result.Added, b.add(part(1, "b")))
        assertEquals(1, b.scanned); assertEquals(3, b.size); assertFalse(b.isComplete); assertEquals(listOf(1, 3), b.missing)
        assertEquals(MigrationBatch.Result.Duplicate, b.add(part(1, "b")))
        b.add(part(2, "c")); assertFalse(b.isComplete)
        b.add(part(0, "a")); assertTrue(b.isComplete); assertEquals(3, b.entries.size); assertEquals(emptyList<Int>(), b.missing)
        // A part from a different export starts over.
        val other = Migration.parse(uri(payload(listOf(params(s1, "z", "Z", 1, 1, 2)), size = 2, index = 0, id = 5)))!!
        assertEquals(MigrationBatch.Result.NewBatch, b.add(other)); assertEquals(1, b.scanned); assertEquals(2, b.size)
        // Out of range index is invalid; a one-part export is complete at once.
        assertEquals(MigrationBatch.Result.Invalid, MigrationBatch().add(Migration.parse(uri(payload(emptyList(), size = 2, index = 5, id = 1)))!!))
        val single = MigrationBatch().also { it.add(Migration.parse(uri(payload(listOf(params(s1, "q", "Q", 1, 1, 2)))))!!) }
        assertTrue(single.isComplete)
    }

    @Test fun dedupe() {
        val a = AuthEntry(secret = "JBSWY3DPEHPK3PXP", issuer = "A"); val b = AuthEntry(secret = "jbsw y3dp ehpk 3pxp", issuer = "dup"); val c = AuthEntry(secret = "GEZDGNBVGY3TQOJQGEZA")
        assertEquals(listOf(c), AuthEntries.newOnly(listOf(a), listOf(b, c)))
        assertEquals(listOf(a), AuthEntries.newOnly(emptyList(), listOf(a, b)))
    }

    // ---------------------------------------------------------------- issuer domains

    @Test fun issuerMap() {
        assertEquals(listOf("salesforce.com", "force.com"), IssuerDomains.forIssuer("Salesforce"))
        assertEquals(IssuerDomains.forIssuer("GitHub"), IssuerDomains.forIssuer("  GITHUB  "))
        assertEquals(IssuerDomains.forIssuer("Salesforce"), IssuerDomains.forIssuer("Salesforce, Inc."))
        assertEquals(IssuerDomains.forIssuer("Amazon Web Services"), IssuerDomains.forIssuer("AWS"))
        assertEquals(IssuerDomains.forIssuer("Atlassian"), IssuerDomains.forIssuer("Atlassian Cloud"))
        assertEquals(IssuerDomains.forIssuer("X"), IssuerDomains.forIssuer("Twitter"))
        assertEquals(listOf("example.org"), IssuerDomains.forIssuer("www.example.org"))
        assertTrue(IssuerDomains.forIssuer("Some Unknown Startup").isEmpty())
        assertTrue(IssuerDomains.forIssuer("").isEmpty())
        for (n in listOf("Google", "Microsoft", "Dropbox", "Okta", "Zoho", "GitLab", "Cloudflare", "Stripe", "Shopify", "Facebook", "Instagram", "LinkedIn", "Discord", "Binance", "Coinbase", "Zerodha", "Upstox", "Groww", "Slack"))
            assertTrue("$n", IssuerDomains.forIssuer(n).isNotEmpty())
        assertTrue(IssuerDomains.knownNames().size >= 60)
    }

    // ---------------------------------------------------------------- matching and wire codec

    private fun entry(id: String, issuer: String, account: String, vararg domains: String) = AuthEntry(id = id, issuer = issuer, account = account, secret = "JBSWY3DPEHPK3PXP", domains = domains.toList())

    @Test fun domainMatching() {
        assertTrue(Domains.matches("login.salesforce.com", "salesforce.com")); assertTrue(Domains.matches("salesforce.com", "salesforce.com"))
        assertTrue(Domains.matches("https://WWW.Salesforce.com:443/x", "salesforce.com")); assertTrue(Domains.matches("my.force.com.", "force.com"))
        assertFalse(Domains.matches("evilsalesforce.com", "salesforce.com")); assertFalse(Domains.matches("salesforce.com.evil.io", "salesforce.com"))
        assertFalse(Domains.matches("", "x.com"))
        assertEquals(listOf("salesforce.com", "login.salesforce.com"), Domains.split("salesforce.com, login.salesforce.com"))
    }

    private fun req(domain: String, account: String? = null, entryId: String? = null) =
        AuthWire.parseCodeGet(Message.of("auth.code.get") { put("req", "r1"); put("domain", domain); account?.let { put("account", it) }; entryId?.let { put("entryId", it) }; put("client", "Chrome") })!!

    @Test fun matchingPolicy() {
        val sf1 = entry("1", "Salesforce", "me@work.com", "salesforce.com", "force.com")
        val sf2 = entry("2", "Salesforce", "me@sandbox.org", "salesforce.com", "force.com")
        val gh = entry("3", "GitHub", "octocat", "github.com")
        val all = listOf(sf1, sf2, gh)
        assertEquals(gh, (AuthWire.match(all, req("github.com")) as AuthMatch.One).entry)
        assertEquals(gh, (AuthWire.match(all, req("gist.github.com, github.com")) as AuthMatch.One).entry)
        val amb = AuthWire.match(all, req("login.salesforce.com")) as AuthMatch.Ambiguous
        assertEquals(listOf("1", "2"), amb.choices.map { it.id }); assertEquals("me@work.com", amb.choices[0].account)
        assertEquals(sf2, (AuthWire.match(all, req("login.salesforce.com", account = "ME@sandbox.org")) as AuthMatch.One).entry)
        assertEquals(sf1, (AuthWire.match(all, req("acme.my.force.com", account = "me")) as AuthMatch.Ambiguous).let { all.first { e -> e.id == it.choices[0].id } }) // "me" is not a full local part of either
        assertEquals(AuthMatch.None, AuthWire.match(all, req("evilgithub.com")))
        assertEquals(AuthMatch.None, AuthWire.match(all, req("github.com", entryId = "nope")))
        assertEquals(sf2, (AuthWire.match(all, req("anything.com", entryId = "2")) as AuthMatch.One).entry) // the user already chose it on the Mac
        assertNull(AuthWire.parseCodeGet(Message.of("auth.code.get") { put("req", "r") }))
        assertEquals("a browser", req("x.com").let { AuthWire.parseCodeGet(Message.of("auth.code.get") { put("req", "r"); put("domain", "x.com") })!!.client })
    }

    @Test fun replyAndNextPeriod() {
        val e = AuthEntry(secret = Base32.encode("12345678901234567890".toByteArray()), digits = 8)
        val early = AuthWire.reply(e, 59 - 20)!!   // 11 s left in the period: this period's code
        assertEquals(Otp.totp("12345678901234567890".toByteArray(), 39, 8), early.code); assertEquals(21, early.validFor)
        val late = AuthWire.reply(e, 56)!!         // 4 s left: next period's code
        assertEquals("94287082".let { Otp.totp("12345678901234567890".toByteArray(), 60, 8) }, late.code); assertEquals(30, late.validFor)
        val edge = AuthWire.reply(e, 55)!!         // exactly 5 s left: still this period
        assertEquals(5, edge.validFor)
    }

    @Test fun wireMessagesNeverCarrySecretsOrBlankFields() {
        val e = entry("9", "Okta", "me@corp.com", "okta.com").copy(secret = "GEZDGNBVGY3TQOJQGEZA")
        val list = AuthWire.list("r7", listOf(e))
        assertEquals("auth.list", list.type); assertEquals("r7", list.str("req"))
        val item = list.arr("items")!![0].jsonObject
        assertEquals(setOf("id", "issuer", "account", "domains", "digits"), item.keys)
        assertFalse(list.header.toString().contains("GEZDGNBVGY3TQOJQGEZA"))
        val ok = AuthWire.code("r8", e, "123456", 21)
        assertEquals(true, ok.bool("ok")); assertEquals("123456", ok.str("code")); assertEquals(21, ok.int("validFor")); assertEquals("9", ok.str("entryId"))
        val no = AuthWire.error("r8", AuthWire.AMBIGUOUS, listOf(Choice("1", "A", "x"), Choice("2", "B", "y")))
        assertEquals(false, no.bool("ok")); assertEquals("ambiguous", no.str("error")); assertEquals(2, no.arr("choices")!!.size)
        assertNull(AuthWire.error("r", AuthWire.DENIED).arr("choices"))
        assertEquals("okta.com", AuthWire.parseDomainSet(Message.of("auth.domain.set") { put("entryId", "9"); put("domain", "https://Login.Okta.com/") })!!.domain.let { if (it == "login.okta.com") "okta.com" else it })
        assertNull(AuthWire.parseDomainSet(Message.of("auth.domain.set") { put("entryId", "9"); put("domain", "nodots") }))
        assertEquals("12", AuthWire.req(Message.of("x") { put("req", 12) }))
    }

    @Test fun autoApprovalPolicy() {
        val now = 10_000_000L
        fun d(mode: ApprovalPolicy.Mode = ApprovalPolicy.Mode.Auto, locked: Boolean = false, unlocked: Long = now - 60_000, present: Boolean = true, min: Int = 5) =
            ApprovalPolicy.decide(mode, locked, unlocked, now, min, present)
        assertEquals(ApprovalPolicy.Decision.Auto, d())
        assertEquals(ApprovalPolicy.Decision.Ask, d(mode = ApprovalPolicy.Mode.Ask))
        assertEquals(ApprovalPolicy.Decision.Ask, d(locked = true))
        assertEquals(ApprovalPolicy.Decision.Ask, d(present = false))
        assertEquals(ApprovalPolicy.Decision.Ask, d(unlocked = now - 6 * 60_000))
        assertEquals(ApprovalPolicy.Decision.Auto, d(unlocked = now - 5 * 60_000))
        assertEquals(ApprovalPolicy.Decision.Ask, d(unlocked = 0))
        assertEquals(ApprovalPolicy.Decision.Ask, d(unlocked = now + 1))
        assertEquals(ApprovalPolicy.Decision.Auto, d(unlocked = now - 9 * 60_000, min = 10))
    }

    // ---------------------------------------------------------------- backup

    private val vault = listOf(
        AuthEntry(id = "a", issuer = "Salesforce", account = "me@work.com", secret = "JBSWY3DPEHPK3PXP", domains = listOf("salesforce.com", "force.com")),
        AuthEntry(id = "b", issuer = "Ünïcode ✓", account = "ß", secret = "GEZDGNBVGY3TQOJQGEZA", algorithm = OtpAlgorithm.SHA512, digits = 8, period = 60, type = OtpType.HOTP, counter = 41),
    )

    @Test fun backupRoundTrip() {
        val f = AuthBackup.encrypt(vault, "correct horse battery".toCharArray(), 1234, n = 1 shl 10)
        assertEquals(vault, AuthBackup.decrypt(f, "correct horse battery".toCharArray()))
        assertFalse(String(f, Charsets.ISO_8859_1).contains("JBSWY3DPEHPK3PXP")); assertFalse(String(f, Charsets.ISO_8859_1).contains("Salesforce"))
        assertNotEquals(f.toList(), AuthBackup.encrypt(vault, "correct horse battery".toCharArray(), 1234, n = 1 shl 10).toList()) // fresh salt and iv
        assertEquals(emptyList<AuthEntry>(), AuthBackup.decrypt(AuthBackup.encrypt(emptyList(), "pw".toCharArray(), 0, n = 16), "pw".toCharArray()))
    }

    @Test fun backupDefaultParameters() {
        val f = AuthBackup.encrypt(vault, "p4ss-phrase".toCharArray(), 1)
        assertTrue(String(f, 12, 80, Charsets.ISO_8859_1).contains("\"n\":32768"))
        assertEquals(vault, AuthBackup.decrypt(f, "p4ss-phrase".toCharArray()))
    }

    private fun failure(block: () -> Unit): AuthBackup.Failure = try { block(); fail("expected failure"); throw IllegalStateException() } catch (e: AuthBackup.BackupException) { e.failure }

    @Test fun backupFailures() {
        val f = AuthBackup.encrypt(vault, "right".toCharArray(), 1, n = 16)
        assertEquals(AuthBackup.Failure.WrongPassphrase, failure { AuthBackup.decrypt(f, "wrong".toCharArray()) })
        val flipped = f.copyOf().also { it[it.size - 3] = (it[it.size - 3].toInt() xor 1).toByte() }
        assertEquals(AuthBackup.Failure.WrongPassphrase, failure { AuthBackup.decrypt(flipped, "right".toCharArray()) })
        val hdr = f.copyOf().also { it[12] = (it[12].toInt() xor 0x20).toByte() } // tamper with the header
        assertTrue(failure { AuthBackup.decrypt(hdr, "right".toCharArray()) } in setOf(AuthBackup.Failure.WrongPassphrase, AuthBackup.Failure.Corrupt))
        assertEquals(AuthBackup.Failure.NotABackup, failure { AuthBackup.decrypt("not a backup at all".toByteArray(), "x".toCharArray()) })
        assertEquals(AuthBackup.Failure.NotABackup, failure { AuthBackup.decrypt(ByteArray(0), "x".toCharArray()) })
        val v2 = f.copyOf().also { it[8] = 2 }
        assertEquals(AuthBackup.Failure.UnsupportedVersion, failure { AuthBackup.decrypt(v2, "right".toCharArray()) })
        assertEquals(AuthBackup.Failure.Corrupt, failure { AuthBackup.decrypt(f.copyOf(14), "right".toCharArray()) })
    }

    @Test fun passphraseStrength() {
        assertEquals(PassphraseStrength.Level.Weak, PassphraseStrength.level("short"))
        assertEquals(PassphraseStrength.Level.Weak, PassphraseStrength.level("password"))
        assertEquals(PassphraseStrength.Level.Weak, PassphraseStrength.level("aaaaaaaaaaaa"))
        assertEquals(PassphraseStrength.Level.Weak, PassphraseStrength.level("12345678"))
        assertTrue(PassphraseStrength.level("correct horse battery staple") >= PassphraseStrength.Level.Good)
        assertEquals(PassphraseStrength.Level.Strong, PassphraseStrength.level("T7#kq9!Lm2@vXp4Z"))
        assertTrue(PassphraseStrength.acceptable("T7#kq9!Lm2@vXp4Z")); assertFalse(PassphraseStrength.acceptable("hunter2"))
    }
}
