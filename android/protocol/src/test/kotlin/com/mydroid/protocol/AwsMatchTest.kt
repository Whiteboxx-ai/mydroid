package com.mydroid.protocol

import com.mydroid.protocol.auth.*
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue

/** Regression: on signin.aws.amazon.com the AWS entry must win over Amazon shopping, even if the typed email matches Amazon. */
class AwsMatchTest {
    private fun entry(id: String, issuer: String, account: String, domains: List<String>) =
        AuthEntry(id = id, issuer = issuer, account = account, secret = "JBSWY3DPEHPK3PXP", domains = domains)

    @Test fun awsBeatsAmazonOnAwsSignin() {
        val amazon = entry("a", "Amazon", "me@mail.com", IssuerDomains.forIssuer("Amazon"))
        val aws = entry("b", "Amazon Web Services", "root-account-mfa-device@123", IssuerDomains.forIssuer("Amazon Web Services"))
        val r = CodeRequest(req = "1", domains = listOf("amazon.com", "signin.aws.amazon.com"), account = "me@mail.com", entryId = null, client = "Chrome")
        val m = AuthWire.match(listOf(amazon, aws), r)
        assertTrue("expected AWS, got $m", m is AuthMatch.One && m.entry.id == "b")
    }

    @Test fun amazonShoppingStillMatchesAmazon() {
        val amazon = entry("a", "Amazon", "me@mail.com", IssuerDomains.forIssuer("Amazon"))
        val aws = entry("b", "AWS", "x", IssuerDomains.forIssuer("AWS"))
        val r = CodeRequest(req = "1", domains = listOf("amazon.com", "www.amazon.com"), account = null, entryId = null, client = "Chrome")
        val m = AuthWire.match(listOf(amazon, aws), r)
        assertTrue(m is AuthMatch.One && m.entry.id == "a")
    }

    @Test fun awsMapHasNoPlainAmazon() {
        assertEquals(false, IssuerDomains.forIssuer("Amazon Web Services").contains("amazon.com"))
    }
}
