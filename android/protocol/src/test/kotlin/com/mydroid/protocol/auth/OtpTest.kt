package com.mydroid.protocol.auth

import com.mydroid.protocol.Hex
import org.junit.Assert.*
import org.junit.Test

class OtpTest {
    private val ascii = { s: String -> s.toByteArray(Charsets.US_ASCII) }

    /** RFC 4226 Appendix D. */
    @Test fun hotpAppendixD() {
        val key = ascii("12345678901234567890")
        val expected = listOf("755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489")
        expected.forEachIndexed { i, code -> assertEquals("counter $i", code, Otp.hotp(key, i.toLong())) }
    }

    /** RFC 6238 Appendix B: 8 digits, 30 s, the three seeds. */
    @Test fun totpAppendixB() {
        val k1 = ascii("12345678901234567890")
        val k256 = ascii("12345678901234567890123456789012")
        val k512 = ascii("1234567890123456789012345678901234567890123456789012345678901234")
        val rows = listOf(
            Triple(59L, listOf("94287082", "46119246", "90693936"), 0),
            Triple(1111111109L, listOf("07081804", "68084774", "25091201"), 0),
            Triple(1111111111L, listOf("14050471", "67062674", "99943326"), 0),
            Triple(1234567890L, listOf("89005924", "91819424", "93441116"), 0),
            Triple(2000000000L, listOf("69279037", "90698825", "38618901"), 0),
            Triple(20000000000L, listOf("65353130", "77737706", "47863826"), 0),
        )
        for ((t, codes, _) in rows) {
            assertEquals("SHA1 t=$t", codes[0], Otp.totp(k1, t, 8, 30, OtpAlgorithm.SHA1))
            assertEquals("SHA256 t=$t", codes[1], Otp.totp(k256, t, 8, 30, OtpAlgorithm.SHA256))
            assertEquals("SHA512 t=$t", codes[2], Otp.totp(k512, t, 8, 30, OtpAlgorithm.SHA512))
        }
    }

    @Test fun sixDigitsAndPeriods() {
        val k = ascii("12345678901234567890")
        assertEquals("287082", Otp.totp(k, 59, 6, 30))   // step 1
        assertEquals("287082", Otp.totp(k, 30, 6, 30))
        assertEquals("755224", Otp.totp(k, 29, 6, 30))   // step 0
        assertEquals("287082", Otp.totp(k, 119, 6, 60))  // 60 s period: step 1
        assertEquals(1, Otp.secondsRemaining(59, 30)); assertEquals(30, Otp.secondsRemaining(60, 30)); assertEquals(1, Otp.secondsRemaining(119, 60))
        assertEquals(0.5f, Otp.fractionRemaining(15_000, 30), 0.0001f)
    }

    @Test fun base32Rfc4648() {
        val vec = mapOf("" to "", "f" to "MY======", "fo" to "MZXQ====", "foo" to "MZXW6===", "foob" to "MZXW6YQ=", "fooba" to "MZXW6YTB", "foobar" to "MZXW6YTBOI======")
        for ((plain, enc) in vec) {
            assertEquals(enc, Base32.encode(plain.toByteArray(), padding = true))
            assertEquals(enc.trimEnd('='), Base32.encode(plain.toByteArray()))
            if (plain.isNotEmpty()) assertEquals(plain, String(Base32.decode(enc)!!))
        }
        assertEquals("foobar", String(Base32.decode("mzxw 6ytb-oi")!!)) // case, spaces, dashes
        assertNull(Base32.decode("MZXW1")) // 1 is not in the alphabet
        assertNull(Base32.decode(""))
        assertEquals("JBSWY3DPEHPK3PXP", Base32.normalize("jbsw y3dp ehpk 3pxp"))
        assertTrue(Base32.isValidSecret("JBSWY3DPEHPK3PXP")); assertFalse(Base32.isValidSecret("MZXW6"))
        val random = ByteArray(33) { (it * 37).toByte() }
        assertArrayEquals(random, Base32.decode(Base32.encode(random)))
    }

    @Test fun scryptRfc7914() {
        fun s(p: String, salt: String, n: Int, r: Int, par: Int) = Hex.encode(Scrypt.derive(p.toByteArray(), salt.toByteArray(), n, r, par, 64))
        assertEquals(
            "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906",
            s("", "", 16, 1, 1),
        )
        assertEquals(
            "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640",
            s("password", "NaCl", 1024, 8, 16),
        )
        assertEquals(
            "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887",
            s("pleaseletmein", "SodiumChloride", 16384, 8, 1),
        )
    }
}
