# Security Policy

We deeply appreciate any effort to discover and disclose security vulnerabilities responsibly.

For any security bug or issue with Gemstash, please email security@rubygems.org with details about the problem or [report it privately on GitHub](https://github.com/rubygems/gemstash/security/advisories/new). Please do not report security issues in public GitHub issues or pull requests.

For additional information about RubyGems security, please see https://rubygems.org/pages/security.

## Out of scope for Gemstash

The following are not treated as vulnerabilities. A technically correct report may still be fixed in public as a regular bug or hardening change.

- Your own environment and settings. This covers attacks that require direct filesystem write access to files Gemstash already loads on your behalf, such as its configuration file or the data under its `:base_path`, and documented configuration behavior, such as unauthenticated download of private gems and specs while `:protected_fetch` is off.
- Issues already fixed on the `main` branch. Please check it before reporting.
