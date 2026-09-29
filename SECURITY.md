# Security Policy

FineKo is a set of plugins for KOReader. This policy explains which versions
receive security fixes and how to report a vulnerability responsibly.

## Supported versions

Only the latest release is supported. Fixes are published as a new tagged
release; older releases are not patched. Please update to the latest version
before reporting an issue.

| Version | Supported |
| --- | --- |
| Latest release | :white_check_mark: |
| Older releases | :x: |

## Reporting a vulnerability

Please **do not** report security issues through public GitHub issues, pull
requests, or discussions, as this exposes users before a fix is available.

Report privately using GitHub's **Security Advisories**:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability** (private vulnerability reporting).
3. Fill in the report with as much detail as you can.

If private reporting is unavailable for you, open a minimal public issue that
asks for a private contact channel, **without** including any vulnerability
details, and a maintainer will follow up.

## What to include

A good report helps fix the problem faster:

- A clear description of the vulnerability and its impact.
- The affected plugin(s) and version (release tag or commit).
- Your KOReader version and device.
- Step-by-step instructions to reproduce it.
- Any proof of concept, logs, or screenshots (keep them minimal and safe).
- A suggested fix or mitigation, if you have one.

## Scope

Because FineKo runs inside KOReader and talks to external services, keep the
following in mind:

- **In scope:** vulnerabilities in FineKo's own code, for example unsafe file
  handling, remote code execution, path traversal in metadata/cover handling,
  or unintended data exposure caused by the plugins.
- **Out of scope:** vulnerabilities in **KOReader** itself and issues in the
  **external metadata or cover sources** the plugins query (Google Books, Open
  Library, Inventaire/Wikidata, Amazon, and others). Please report those to the
  respective project or service.

## What to expect

- We will acknowledge your report as soon as possible.
- We will investigate and keep you informed about the progress.
- When the fix is ready, we will publish a new release and credit you in the
  advisory, unless you prefer to stay anonymous.
- Please give us reasonable time to fix the issue before any public
  disclosure.

## No bug bounty

This is a volunteer project and does not offer monetary rewards for security
reports. We are nonetheless grateful for responsible disclosure.

## Safe harbor

We consider security research conducted in good faith, respecting this policy
and avoiding harm to users or data, to be authorized. We will not pursue or
support legal action for such research.
