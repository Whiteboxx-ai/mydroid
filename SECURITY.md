# Security

Report a vulnerability through GitHub: **Security → Report a vulnerability** on this repository. Please don't open a public issue for it.

Include the version, what you did, and what happened. Expect a first reply within a week.

Mydroid reads SMS, call state, notifications and 2FA approvals, so reports about pairing, encryption, the Mac's local socket and the browser extension matter most. The design is in [`protocol/PROTOCOL.md`](protocol/PROTOCOL.md); what stays on your devices is in [Privacy](site/src/content/docs/privacy.md).

Check a download before you run it: compare `shasum -a 256 <file>` with the `SHA256SUMS` file on the release page.
