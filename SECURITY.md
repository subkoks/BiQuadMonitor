# Security and privacy

BiQuad Monitor is a local, independent cellular monitor. The 0.2.0 preview has not completed stable-release security and distribution acceptance.

## Router access

- The address validator accepts private IPv4 addresses. The app signs in through the router's web interface and reads a fixed cellular-status endpoint.
- The login form is the only POST. The app does not change router configuration, install firmware, send AT commands, access SMS, or use SSH.
- HTTP login material and measurements cross the LAN without transport encryption. HTTPS is available only with normal certificate validation; the app does not bypass certificate errors.
- Redirects are restricted to the same origin and a small set of known login/navigation paths. Responses are size-limited. Sessions use ephemeral cookies and no disk cache.
- Keychain storage is opt-in and uses this app's own service entry. The app does not read browser passwords or browser cookies. An expired login can be renewed once using a saved password; otherwise the user is asked to connect again.

## Stored and exported data

The local SQLite database contains measurements, timestamps, operator/radio context, cell identifiers, trial names, orientations and notes. It is stored at `~/Library/Application Support/BiQuadMonitor/measurements.sqlite` with owner-only file permissions. The database is **not encrypted by the app**; normal Mac account and disk protections apply.

Passwords, authentication cookies, raw router responses and SIM identifiers are not written to the measurement store or exports. Parsing retains only the supported signal and radio metadata fields.

Exports omit cell identifiers and user names/notes unless explicitly included. They still contain measurement times, band and other radio information. Review an export before sharing it. CSV text fields are quoted and neutralized for spreadsheet formula prefixes. JSON exports carry a schema version and timestamp unit.

There is no telemetry or cloud upload. Routine cleanup runs only when the user selects it, and excludes active and pinned sessions. Antenna experiment sessions are pinned automatically. Unpinning makes a closed session eligible for later cleanup.

## Reporting a problem

Do not post passwords, router backups, session cookies, private keys, raw login responses or unredacted screenshots in a public issue. For an ordinary bug, provide the app version, macOS version, CPU architecture, router model/firmware, safe error text and reproduction steps.

For a vulnerability, use GitHub's private **Report a vulnerability** option if it is available on this repository. Otherwise open an issue requesting a private reporting channel without including exploit details or sensitive data. Do not upload a private router capture as a substitute for a minimal sanitized reproduction.

## Development and distribution

The local preview is ad-hoc signed and not notarized. Developer ID signing, notarization and clean-install acceptance remain release gates. Keep macOS security controls enabled while diagnosing Local Network or certificate issues.

Source-publication checks and CI are safeguards, not guarantees. Review the exact source and artifact manifest before publishing. Router backups, firmware archives, third-party installers, measurement databases and credentials must remain outside the public repository and app bundle.
