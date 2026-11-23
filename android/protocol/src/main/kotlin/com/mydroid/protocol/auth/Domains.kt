package com.mydroid.protocol.auth

/** Host and domain helpers for matching a web page to a vault entry. */
object Domains {
    /** "https://Login.Example.com:8443/x?y" -> "login.example.com". Lower case, no scheme, port, path or trailing dot; a leading `www.` is kept off. */
    fun normalize(input: String): String {
        var s = input.trim().lowercase()
        s = s.substringAfter("://", s)
        s = s.substringBefore('/').substringBefore('?').substringBefore('#')
        s = s.substringAfterLast('@')
        if (s.startsWith("[")) return s // IPv6 literal: left alone
        s = s.substringBefore(':').trimEnd('.')
        if (s.startsWith("www.")) s = s.removePrefix("www.")
        return s
    }

    fun isPlausibleHost(h: String): Boolean {
        val n = normalize(h)
        return n.length in 3..253 && n.contains('.') && n.all { it.isLetterOrDigit() || it == '.' || it == '-' } && !n.startsWith('.') && !n.contains("..")
    }

    /** True when [host] is [domain] or a subdomain of it (`login.salesforce.com` matches `salesforce.com`; `evilsalesforce.com` does not). */
    fun matches(host: String, domain: String): Boolean {
        val h = normalize(host); val d = normalize(domain)
        if (h.isEmpty() || d.isEmpty()) return false
        return h == d || h.endsWith(".$d")
    }

    /** The request's `domain` may carry several names (an eTLD+1 and the full host); split on commas, spaces and semicolons. */
    fun split(domainField: String): List<String> =
        domainField.split(',', ' ', ';', '\n').map { normalize(it) }.filter { it.isNotEmpty() }.distinct()

    /** Stored form: normalised, deduplicated, blanks dropped. */
    fun clean(list: List<String>): List<String> = list.map { normalize(it) }.filter { it.isNotEmpty() }.distinct()
}
