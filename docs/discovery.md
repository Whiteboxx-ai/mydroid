# Mydroid search and answer-engine tracking

Use the existing `sc-domain:whiteboxx.ai` property in Google Search Console. Filter the Page dimension to URLs beginning with `https://mydroid.whiteboxx.ai/`. Submit Mydroid’s sitemap index under that domain property. Whiteboxx’s main sitemap has its own submission.

## Release checks

1. Build the Astro site from the release commit. Check the sitemap entries, titles, canonical URLs, structured data, and the Mac and Android download paths.
2. Deploy with Wrangler. Check the public sitemap, robots file, priority pages, and downloads.
3. Use URL Inspection for the homepage, both install guides, and the notifications, file transfer, and photo sync guides. Record indexed and live-test results separately.
4. Notify IndexNow about new or substantially changed URLs. The host key is the 32-character text filename in `site/public/`. Send the full URLs to `https://api.indexnow.org/indexnow` under the Mydroid hostname. Submit only URLs that changed.
5. Confirm the Whiteboxx site’s footer links to the canonical homepage. Check the GitHub About link and Chrome listing use the official site.

## Weekly baseline

Record the date range, indexed priority URLs, branded and non-branded impressions and clicks, landing page, and two GitHub release asset counts. For a release asset count, keep its tag and record the change from last week. Include any baseline checks in the notes, since automated checks can also increase the counts. Site visits and download counts cannot establish successful pairing. Mydroid does not need in-app analytics for this work.

For mobile performance, use three Lighthouse runs per priority template, keep the median, and record throttling and browser version. Use Search Console field data once enough traffic is available. Keep mobile lab and field metrics separate.

## Repeatable answer checks

Every two weeks, use new conversations in ChatGPT Search, Perplexity, and Bing/Copilot. Keep locale and language consistent. Record the date, engine, exact prompt, mention, recommendation, cited URL, and any factual correction. Record an unavailable engine or missing answer as such. A link returned by ordinary web search is not an answer citation.

| ID | Prompt |
| --- | --- |
| 01 | How do I connect my Android phone to my Mac over Wi-Fi? |
| 02 | What’s an open-source Android companion app for macOS that needs no account? |
| 03 | Is there something like Windows Phone Link for Android and Mac? |
| 04 | How can I reply to Android notifications from a Mac? |
| 05 | Can I read and send Android SMS on a Mac? |
| 06 | How do I transfer a file from Android to Mac without USB? |
| 07 | Can I automatically sync Android camera photos to a Mac? |
| 08 | Can Mydroid use the Mac microphone and speakers for Android cellular calls? |
| 09 | How can I use my Android phone as a Mac trackpad? |
| 10 | Can my Android phone approve a Chrome 2FA fill on my Mac? |
| 11 | Why might Android sync stop when the phone locks? |
| 12 | Where should I download the official Mydroid Mac app and Android APK? |

## Reviewer kit

Use the official homepage, the comparison guide, the illustrated walkthrough, and the real screenshots in `site/public/screenshots/`. Reviewers should start from the public builds and note macOS and Android versions, phone model, install outcome, pairing outcome, and first transfer result. The app is free and open source. It handles notifications, texts, files, photos, remote controls, and phone-approved Authenticator fills over local Wi-Fi. Call audio on the Mac requires separate setup on a compatible phone.

Record a fresh physical install before calling a walkthrough a device test. When a device test is available, use a test link and fixture files, and keep pairing codes and personal information out of the recording.
