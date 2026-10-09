# Contributing

BiQuad Monitor prioritizes correct cellular readings and reliable antenna comparisons. Keep changes small enough to review and verify against an explicit acceptance condition.

## Working locally

Use full Xcode, its macOS SDK, Swift, and Python 3. Open the repository in VS Code with Codex, or use the included Xcode project for native UI tests. The Swift package is the source of the application and core modules.

```sh
swift test
python3 scripts/check.py
python3 scripts/check.py --ui
python3 build_app.py
```

Native UI checks require a macOS GUI session. Report an unavailable test environment separately from a passing test. Build output, local reports, databases and private captures belong in ignored directories.

## Structure

| Location | Responsibility |
| --- | --- |
| `Sources/SignalCore` | Router parsing, units, display formatting, measurement models and analysis |
| `Sources/SessionStore` | SQLite persistence, recovery, retention and export |
| `Sources/BiQuadMonitor` | Router transport, collection coordination, windows and native interface |
| `Tests` | Sanitized fixtures, offline regression tests and native UI tests |
| `scripts` | Repeatable checks, publication checks and bounded local task automation |

Preserve missing values rather than converting them to zero. Do not infer RSSI units from the sign of a number. Keep chart gaps, trial phases and radio context intact across storage and export. Router access must remain read-only apart from signing in.

Add meaningful regression tests for changes to authentication, parsing, retries, persistence, comparison or export. Prefer sanitized minimal fixtures over full router pages. Do not weaken a failing assertion to complete a gate.

## Pull requests

Work on a feature branch and stage explicit paths. Use commits such as `fix(parser): preserve missing signal values`. Describe the user-visible behavior, the verification performed and any remaining uncertainty. UI changes should include a rendered preview marked as simulated unless it truly shows authorized live readings.

Before publication, run `python3 scripts/publication_check.py` and review the complete staged file list and diff. The manifest check supplements manual review and secret scanning; it is not a complete secret detector. Never commit router backups, firmware, third-party installers, credentials, cookies, real SIM identifiers or personal measurement databases.

The [automation workflow](docs/automation.md) uses owner-approved tasks and reviewable evidence. Automation does not authorize merging or publishing a stable release. Consult [release acceptance](docs/release.md) for those steps.
