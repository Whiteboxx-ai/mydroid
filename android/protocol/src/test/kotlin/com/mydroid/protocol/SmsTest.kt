package com.mydroid.protocol

import org.junit.Assert.*
import org.junit.Test

class SmsTest {
    private fun sms(addr: String, body: String, at: Long, aliases: List<String> = emptyList()) =
        SmsEntry(addr, body, at, OtpParser.parse(body, addr), aliases)

    @Test fun multipartAssembly() {
        val out = SmsAssembler.assemble(listOf(SmsPart("VM-HDFCBK", "482913 is the OTP "), SmsPart("VM-HDFCBK", "for txn. Do not share"), SmsPart("+919876543210", "hi")))
        assertEquals(2, out.size)
        assertEquals("482913 is the OTP for txn. Do not share", out[0].body)
        assertEquals("hi", out[1].body)
        assertEquals("482913", OtpParser.parse(out[0].body, out[0].address)?.code)
    }

    @Test fun redactionDetection() {
        val markers = listOf("Contenu sensible masqué")
        assertTrue(Redaction.isRedacted("Sensitive notification content hidden", emptyList()))
        assertTrue(Redaction.isRedacted(" Contenu sensible masqué ", markers))
        assertFalse(Redaction.isRedacted("Your OTP is 123456", markers))
        assertFalse(Redaction.isRedacted(null, markers))
        assertFalse(Redaction.isRedacted("", markers))
    }

    @Test fun matchBySenderIdAndName() {
        val c = SmsCache()
        c.add(sms("VM-HDFCBK", "482913 is your OTP", 1000))
        assertNotNull(c.find(listOf("HDFCBK"), 2000))
        assertNotNull(c.find(listOf("HDFC Bank"), 2000))
        assertNull(c.find(listOf("Maya"), 2000))
        assertNull(c.find(listOf(""), 2000))
    }

    @Test fun matchByNumberAndAlias() {
        val c = SmsCache()
        c.add(sms("+919876543210", "your code is 5566", 1000, listOf("Maya Tan")))
        assertNotNull(c.find(listOf("098765 43210"), 2000))
        assertNotNull(c.find(listOf("Maya Tan"), 2000))
        assertNull(c.find(listOf("+919999999999"), 2000))
    }

    @Test fun windowAndTtl() {
        val c = SmsCache(ttlMs = 120_000)
        c.add(sms("HDFCBK", "482913 is your OTP", 0))
        assertNotNull(c.find(listOf("HDFCBK"), 59_000))
        assertNull(c.find(listOf("HDFCBK"), 61_000)) // outside 60 s match window
        c.add(sms("AXISBK", "111222 is your OTP", 200_000)) // prunes the old one
        assertEquals(1, c.size())
    }

    @Test fun newestWinsAndLenient() {
        val c = SmsCache()
        c.add(sms("HDFCBK", "111111 is your OTP", 1000))
        c.add(sms("HDFCBK", "222222 is your OTP", 2000))
        assertEquals("222222", c.find(listOf("HDFCBK"), 3000)?.otp?.code)
        assertNull(c.find(listOf("Unknown"), 3000, lenient = true)) // two candidates: ambiguous
        val d = SmsCache(); d.add(sms("HDFCBK", "333333 is your OTP", 1000))
        assertEquals("333333", d.find(listOf("Unknown"), 3000, lenient = true)?.otp?.code)
        d.find(listOf("HDFCBK"), 3000)!!.consumed = true
        assertNull(d.find(listOf("Unknown"), 3000, lenient = true))
    }

    @Test fun nonOtpSmsHasNoOtp() = assertNull(sms("MAYA", "see you at 6", 1).otp)
}
