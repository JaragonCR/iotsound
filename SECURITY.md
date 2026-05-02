# Security Policy

## Supported Versions

Only the latest release on `master` receives security fixes.

| Version | Supported |
|---------|-----------|
| Latest  | ✅        |
| Older   | ❌        |

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report vulnerabilities privately via one of these channels:

- **GitHub private reporting:** [Security → Report a vulnerability](../../security/advisories/new) (preferred)
- **Email:** joaragon@gmail.com — include "iotsound security" in the subject line

### What to include

- Description of the vulnerability and potential impact
- Steps to reproduce or proof-of-concept
- Affected versions or components (e.g. `sound-supervisor`, `audio`, a specific plugin)
- Any suggested mitigations if you have them

### What to expect

- Acknowledgement within **5 business days**
- Status update within **14 days** (confirmed, needs more info, or won't fix with rationale)
- Credit in the release notes if you'd like it

## Scope

This project runs on a local network as a personal audio fleet. The primary attack surface is:

- **`sound-supervisor` HTTP API** — unauthenticated, intended for LAN use only; do not expose to the internet
- **PulseAudio/PipeWire TCP port 4317** — LAN-only; same caution applies
- **Snapcast ports 1704/1780** — LAN-only
- **Plugin credentials** — Spotify, Bluetooth pairing, etc.

Out of scope: vulnerabilities that require physical access to the device or that only affect the upstream [iotsound/iotsound](https://github.com/iotsound/iotsound) project (report those upstream).

## Disclosure Policy

Once a fix is available, we aim to release it promptly and disclose the details publicly. We follow a coordinated disclosure model — please give us reasonable time to patch before going public.
