package com.mydroid.protocol.auth

/** The built-in issuer to website map that pre-fills `domains` on a new entry. The Mac teaches the rest (`auth.domain.set`). */
object IssuerDomains {
    private class Svc(val names: List<String>, val domains: List<String>)

    private fun svc(names: String, domains: String) = Svc(names.split('|'), domains.split(' '))

    private val services = listOf(
        svc("Google|Google Account|Gmail|YouTube|Google Workspace|Google Cloud", "google.com youtube.com gmail.com"),
        svc("GitHub", "github.com"),
        svc("GitLab", "gitlab.com"),
        svc("Salesforce|Salesforce.com|Force.com|Trailhead", "salesforce.com force.com"),
        // Never plain amazon.com: that's Amazon shopping. AWS sign-in lives on aws.amazon.com (signin./console.).
        svc("AWS|Amazon Web Services|Amazon AWS|AWS Console", "aws.amazon.com amazonaws.com awsapps.com"),
        svc("Amazon", "amazon.com amazon.in amazon.co.uk amazon.de amazon.ca"),
        svc("Microsoft|Microsoft Account|Azure|Office 365|Microsoft 365|Outlook|Live", "microsoft.com live.com office.com microsoftonline.com azure.com outlook.com"),
        svc("Atlassian|Jira|Confluence|Bitbucket", "atlassian.com atlassian.net bitbucket.org"),
        svc("Slack", "slack.com"),
        svc("Dropbox", "dropbox.com"),
        svc("Okta", "okta.com oktapreview.com"),
        svc("Zoho|Zoho Mail|Zoho Books|Zoho CRM", "zoho.com zoho.in zoho.eu zohocorp.com"),
        svc("Cloudflare", "cloudflare.com"),
        svc("Stripe", "stripe.com"),
        svc("Shopify", "shopify.com myshopify.com"),
        svc("Twitter|X|X Corp|Twitter X", "twitter.com x.com"),
        svc("Facebook|Meta|Meta Platforms", "facebook.com fb.com meta.com"),
        svc("Instagram", "instagram.com"),
        svc("LinkedIn", "linkedin.com"),
        svc("Discord", "discord.com discordapp.com"),
        svc("Binance", "binance.com binance.us"),
        svc("Coinbase", "coinbase.com"),
        svc("Kraken", "kraken.com"),
        svc("Zerodha|Kite", "zerodha.com"),
        svc("Upstox", "upstox.com"),
        svc("Groww", "groww.in"),
        svc("Angel One|Angel Broking", "angelone.in angelbroking.com"),
        svc("Paytm", "paytm.com"),
        svc("Razorpay", "razorpay.com"),
        svc("PayPal", "paypal.com"),
        svc("Apple|Apple ID|iCloud", "apple.com icloud.com"),
        svc("Reddit", "reddit.com"),
        svc("Twitch", "twitch.tv"),
        svc("DigitalOcean", "digitalocean.com"),
        svc("Heroku", "heroku.com"),
        svc("npm|npmjs", "npmjs.com"),
        svc("Docker|Docker Hub", "docker.com"),
        svc("Notion", "notion.so"),
        svc("Figma", "figma.com"),
        svc("Linear", "linear.app"),
        svc("Asana", "asana.com"),
        svc("Trello", "trello.com"),
        svc("HubSpot", "hubspot.com"),
        svc("Mailchimp", "mailchimp.com"),
        svc("Twilio", "twilio.com"),
        svc("SendGrid", "sendgrid.com"),
        svc("OpenAI|ChatGPT", "openai.com chatgpt.com"),
        svc("Anthropic|Claude", "anthropic.com claude.ai"),
        svc("Vercel", "vercel.com"),
        svc("Netlify", "netlify.com"),
        svc("1Password", "1password.com"),
        svc("LastPass", "lastpass.com"),
        svc("Bitwarden", "bitwarden.com"),
        svc("Proton|ProtonMail|Proton Mail", "proton.me protonmail.com"),
        svc("Yahoo|Yahoo Mail", "yahoo.com"),
        svc("WordPress|WordPress.com", "wordpress.com"),
        svc("GoDaddy", "godaddy.com"),
        svc("Namecheap", "namecheap.com"),
        svc("Snapchat", "snapchat.com"),
        svc("TikTok", "tiktok.com"),
        svc("Steam|Steam Guard", "steampowered.com steamcommunity.com"),
        svc("Epic Games", "epicgames.com"),
        svc("Robinhood", "robinhood.com"),
        svc("Wise|TransferWise", "wise.com transferwise.com"),
        svc("Revolut", "revolut.com"),
        svc("Postman", "postman.com"),
        svc("Sentry", "sentry.io"),
        svc("Datadog", "datadoghq.com"),
        svc("PagerDuty", "pagerduty.com"),
        svc("Zoom", "zoom.us"),
        svc("Box", "box.com"),
        svc("Adobe", "adobe.com"),
    )

    private val suffixWords = setOf("inc", "llc", "ltd", "corp", "corporation", "company", "co", "com", "app", "account", "login", "signin", "2fa", "mfa", "auth", "sso", "the")

    private val index: Map<String, List<String>> by lazy {
        val m = HashMap<String, List<String>>()
        for (s in services) for (n in s.names) m.putIfAbsent(key(n), s.domains)
        m
    }

    /** "Salesforce, Inc." -> "salesforce". Lower case, letters and digits only, filler words dropped from the end. */
    internal fun words(issuer: String): List<String> {
        val ws = issuer.lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }.toMutableList()
        while (ws.size > 1 && ws.last() in suffixWords) ws.removeAt(ws.size - 1)
        while (ws.size > 1 && ws.first() in suffixWords) ws.removeAt(0)
        return ws
    }

    private fun key(name: String) = words(name).joinToString("")

    /**
     * Websites for [issuer]: exact normalised name first ("GitHub", "github", "Salesforce, Inc."), then the longest leading run of
     * words ("Atlassian Cloud" -> Atlassian), then a single distinctive word of 4+ letters. An issuer that is itself a domain
     * ("example.com") yields that domain. Empty when nothing matches.
     */
    fun forIssuer(issuer: String): List<String> {
        val t = issuer.trim()
        if (t.isEmpty()) return emptyList()
        if (Regex("^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$").matches(t) && !t.contains(' ') && Domains.isPlausibleHost(t)) return listOf(Domains.normalize(t))
        val ws = words(t)
        if (ws.isEmpty()) return emptyList()
        index[ws.joinToString("")]?.let { return it }
        for (n in ws.size - 1 downTo 1) index[ws.take(n).joinToString("")]?.let { return it }
        for (w in ws) if (w.length >= 4) index[w]?.let { return it }
        return emptyList()
    }

    /** Every known service name, for the lookalike check on the Mac side and for tests. */
    fun knownNames(): Set<String> = index.keys

    fun allDomains(): Set<String> = services.flatMapTo(HashSet()) { it.domains }
}
