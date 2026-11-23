package com.mydroid.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OtpParserTest {
    private fun code(t: String, src: String = "X") = OtpParser.parse(t, src)?.code

    @Test fun codeFirst() = assertEquals("123456", code("123456 is your OTP"))
    @Test fun verificationCode() = assertEquals("4821", code("Your verification code is 4821"))
    @Test fun googlePrefix() = assertEquals("482196", code("G-482196 is your Google verification code"))
    @Test fun spacedGroups() = assertEquals("123456", code("Use 12 34 56 to sign in"))
    @Test fun spacedThrees() = assertEquals("123456", code("Your Uber code is 123 456. Never share it."))
    @Test fun dashedCode() = assertEquals("482196", code("Your Airbnb verification code is 482-196"))
    @Test fun alphanumeric() = assertEquals("AB12CD", code("Your OTP is AB12CD. Do not share it."))
    @Test fun alphanumericPasscode() = assertEquals("K7M2QX", code("Passcode: K7M2QX"))
    @Test fun hindi() = assertEquals("562310", code("आपका ओटीपी 562310 है। किसी से साझा न करें।"))
    @Test fun colonNoSpace() = assertEquals("908172", code("OTP:908172"))
    @Test fun twoFa() = assertEquals("771203", code("2FA code 771203 expires in 5 minutes"))
    @Test fun pinWord() = assertEquals("9034", code("Your PIN is 9034"))
    @Test fun eightDigits() = assertEquals("12345678", code("Login code: 12345678"))
    @Test fun lowercaseKeyword() = assertEquals("3344", code("otp 3344"))
    @Test fun multiline() = assertEquals("654321", code("Verification\n654321"))

    @Test fun bankAmazon() = assertEquals(
        "739201",
        code("OTP for txn of INR 2,500.00 at AMAZON is 739201. Valid for 10 mins. Do not share"),
    )
    @Test fun bankHdfc() = assertEquals(
        "482913",
        code("482913 is the OTP for txn of INR 12,499.00 on HDFC Bank Card ending 1234 at FLIPKART. Valid for 10 mins. Do not share with anyone."),
    )
    @Test fun bankIcici() = assertEquals(
        "118294",
        code("OTP is 118294 for txn of INR 2,500.00 on ICICI Bank Card XX1234 at AMAZON. Valid for 15 mins. Do not share."),
    )
    @Test fun bankSbi() = assertEquals(
        "507761",
        code("Dear Customer, Your OTP for Online Transaction of Rs.2500.00 at AMAZON is 507761 valid for 10 mins. Never share. a/c XX1234"),
    )
    @Test fun bankAxis() = assertEquals(
        "665021",
        code("Use 665021 as OTP for Rs 5000 txn at SWIGGY on Axis Bank A/c no. XX4455. Valid 5 min. Call 1800 419 5959 if not you."),
    )
    @Test fun bankKotakRetrieverHash() = assertEquals(
        "331870",
        code("<#> 331870 is your Kotak OTP. Do not share. FA+9qCX9VSu"),
    )
    @Test fun rupeeBeforeCode() = assertEquals("847203", code("Rs. 4999 debited. OTP 847203 to confirm"))
    @Test fun otpThenMinutesNumber() = assertEquals("482196", code("Your OTP is 482196 10 mins"))
    @Test fun prefersNearKeyword() = assertEquals("4821", code("Order 998877 confirmed. Your OTP is 4821."))

    @Test fun sourcePassedThrough() = assertEquals("HDFC Bank", OtpParser.parse("123456 is your OTP", "HDFC Bank")?.source)

    // --- must NOT match ---
    @Test fun amountOnly() = assertNull(code("Your OTP was sent. Payment of INR 2,500.00 received"))
    @Test fun amountRupeeNoComma() = assertNull(code("Code applied: Rs 5000 off on your cart"))
    @Test fun phoneNumber() = assertNull(code("Call 98765 43210 to verify your account"))
    @Test fun phoneWithCountry() = assertNull(code("Verification pending. Contact +91 98765 43210"))
    @Test fun tollFree() = assertNull(code("Verification failed. Call 1800 267 0008"))
    @Test fun dateSlash() = assertNull(code("Verify your visit on 05/12/2024"))
    @Test fun dateDash() = assertNull(code("Login detected on 2024-12-05 from a new device"))
    @Test fun dateDashShort() = assertNull(code("Login detected on 05-12-24"))
    @Test fun time() = assertNull(code("New login at 10:30:45 from Chrome"))
    @Test fun orderNumberNoKeyword() = assertNull(code("Your order 123456 has shipped"))
    @Test fun orderNumberWithUnrelatedCode() = assertNull(code("Your order #123456 has shipped. Track with code word"))
    @Test fun accountEnding() = assertNull(code("Your a/c XX1234 login was updated"))
    @Test fun accountEndingWord() = assertNull(code("Verification: card ending 1234 was added"))
    @Test fun maskedAlnum() = assertNull(code("Your OTP service for XX1234 is active"))
    @Test fun promoCode() = assertNull(code("Use code SAVE20 for 20% off your next order"))
    @Test fun promoNumeric() = assertNull(code("Use code 2024 for a discount on your next order"))
    @Test fun noKeyword() = assertNull(code("Meet at 4821 Main Street at 6 pm"))
    @Test fun keywordNoCode() = assertNull(code("Your OTP has expired. Please request a new one"))
    @Test fun yearFollowedByPunct() = assertNull(code("Verification email sent on 12/2024"))
    @Test fun tooShort() = assertNull(code("Your code is 123"))
    @Test fun tooLong() = assertNull(code("Your code is 1234567890123"))
    @Test fun lettersOnly() = assertNull(code("Your verification code is ABCDEF"))
    @Test fun empty() = assertNull(OtpParser.parse("", "x"))
    @Test fun nullText() = assertNull(OtpParser.parse(null, "x"))
    @Test fun hugeText() = assertNull(OtpParser.parse("otp 123456 " + "a".repeat(3000), "x"))
}
