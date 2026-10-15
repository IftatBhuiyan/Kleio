# Contributing to Kleio

Kleio welcomes pull requests for its macOS app, connector, accessibility, documentation, and bug fixes.

1. Open an issue before a large feature or new dependency so we can agree on scope.
2. Fork the public repository and create a focused branch. Keep unrelated changes out of the PR.
3. Build with the README command. For connector changes run `npm ci`, `node --check server.mjs`, and `npm audit --omit=dev` in `connector/`.
4. Describe the problem, resulting behavior, validation, and any remaining limitations. Include screenshots for UI changes without personal dictation content.
5. Use synthetic audio/text in fixtures. Never submit credentials, account identifiers, private logs, transcripts, or signing files. Keep `.env` and Firebase configuration local.

By submitting a contribution you confirm you have the right to contribute it under GPL-3.0-only. Keep existing copyright and third-party license notices. Contributors retain copyright in their contributions; there is no copyright assignment or CLA.

Be respectful and specific. Harassment and disclosure of other people's personal information are not acceptable. Report vulnerabilities privately using the repository's Security tab rather than opening a public exploit report.
