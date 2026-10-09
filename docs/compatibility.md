# Compatibility and evidence

BiQuad Monitor 0.2.0 is a development preview. Distinguish what the code targets from what has been exercised on physical hardware.

## Router adapter

| Router / firmware | Evidence |
| --- | --- |
| Cudy LT500 V2, `2.4.16-20250804-150319` | The 0.1.4 baseline and packaged 0.2.0 commit `b1e4454` completed real login and repeated readings on this device. Extended acceptance remains below. |
| Other Cudy models, firmware or localized interfaces | Unverified. Do not infer support from a similar admin page. |
| GL.iNet / Glint, Huawei, generic OpenWrt | No adapter provided. |

The Cudy adapter reads:

```text
/cgi-bin/luci/admin/network/gcom/status?detail=1&iface=4g
```

The parent `/gcom?iface=4g` page is a navigation shell on the tested firmware. The detailed fragment supplies the signal table. A minimal sanitized fixture and transport regression tests preserve this distinction.

Four signal readings are parsed with explicit missing-value and range checks. RSSI is treated as a raw index unless its response supplies a dBm unit. Unsupported responses fail with safe diagnostics rather than invented readings. The app does not require custom firmware, an SSH server or router configuration changes.

## macOS and architectures

| Target | Status / boundary |
| --- | --- |
| Intel `x86_64` | Native implementation and local development target |
| Apple Silicon `arm64` | Universal slice and hosted arm64 unit/native UI execution verified; user-device installation and router acceptance remain separate |
| macOS 13 | Declared minimum deployment target; a build targeting 13 does not prove runtime acceptance on 13 |
| Newer macOS | Subject to OS-specific Local Network permission and clean-launch verification |
| Developer ID / notarization | Not part of the ad-hoc preview; required before a trusted distribution release |

CI is configured to test Intel and Apple Silicon separately and build a Universal preview. A workflow file is not passing-run evidence. Check the jobs for the exact commit under review, including native interaction results and preserved reports.

The package uses system SwiftUI, AppKit, Swift Charts and SQLite. Full Xcode and its macOS SDK are required for the documented build/UI-test workflow. The package declares Swift tools 5.9; this declaration alone does not certify every later or earlier toolchain combination.

## Local preview evidence — 2026-10-08

- **PASS:** 45 offline parser, measurement, transport, storage and coordinator tests on Intel macOS 26 / Xcode 26.5.
- **PASS:** app-owned window geometry and coordinator smoke checks; compact, workspace and settings rendered and visually inspected with simulated data.
- **PASS:** native app and XCUITest target build-for-testing.
- **TEST_INVALID:** local XCUITest interaction execution timed out while macOS enabled automation mode. This is not a passing interaction test. Hosted CI results must be checked separately.

## Hosted execution evidence

The [CI run for `b1e4454`](https://github.com/subkoks/BiQuadMonitor/actions/runs/37838502054) passed on both Intel (`macos-26-intel`) and Apple Silicon (`macos-26`) using Xcode 26.6. Each architecture passed the 45 offline tests, window/coordinator smoke and the native XCUITest trial/settings/pause flow. The Universal preview job also passed.

The follow-up [CI run for `1be440e`](https://github.com/subkoks/BiQuadMonitor/actions/runs/37903118515) also passed both native architectures, UI interaction and Universal packaging with the original app icon and hardened workflow checks. Its [CodeQL run](https://github.com/subkoks/BiQuadMonitor/actions/runs/37903118466) passed for all three languages.

These hosted native UI results resolve the interaction-test evidence gap for that commit; they do not grant Local Network access on a user’s Mac or exercise a physical router. Check subsequent commits separately.

## Packaged live check — 2026-10-09

The clean-source Universal preview for `b1e4454` authenticated with the physical LT500 and returned all four metrics through eight timed updates at five-second intervals. The read-only diagnostic used isolated in-memory measurement storage and did not save credentials or change router settings. This confirms real login and polling for that artifact; it does not establish the longer acceptance gates below.

The same commit passed Swift, Python and Actions [CodeQL analysis](https://github.com/subkoks/BiQuadMonitor/actions/runs/37838502002). No open CodeQL findings were returned for that branch at verification time.

## Acceptance still required for this candidate

- Side-by-side comparison with the router status page and two real antenna trials through the normal interface, including restart and export.
- Finder launch and Local Network permission, including a clean installation context.
- Apple Silicon user-device installation and minimum macOS 13 runtime acceptance.
- An eight-hour collection run with responsive UI, bounded display memory and complete export.
- Sleep/wake, network loss/recovery, login expiry and display reconnect behavior in real usage.
- Developer ID signing, notarization and downloaded-app installation for a distribution release.

Offline tests, fixtures, rendered demo images and cross-compilation are useful evidence for their own scope. They do not replace these acceptance checks. Record results against the candidate commit using the [release checklist](release.md).
