# Compatibility and evidence

BiQuad Monitor 0.2.0 is an unsigned Universal release. The owner chose distribution without Developer ID signing or notarization on 2026-10-09. Distinguish what the code targets from what has been exercised on physical hardware.

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
| Developer ID / notarization | Not provided in 0.2.0; this release is explicitly unsigned |

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

## Owner acceptance — 2026-10-09

The owner confirmed normal 0.2.0 use: correct live readings, saved antenna trials surviving restart, and sleep/network recovery. This is owner-reported physical-device acceptance, separate from hosted automated results. The source changes in release preparation affect workflow updates, documentation and distribution labelling; the router adapter and measurement logic are unchanged.

Minimum macOS 13 runtime, clean downloaded-app launch, Apple Silicon user-device/router acceptance and an eight-hour instrumented soak remain unverified. These are disclosed limitations of the unsigned release, not passing checks. No Apple signing or notarization credentials were accessed.

## Candidate evidence — 2026-11-15

The Universal 0.2.0 preview from `878509c` passed [CI](https://github.com/subkoks/BiQuadMonitor/actions/runs/43070546080) and [CodeQL](https://github.com/subkoks/BiQuadMonitor/actions/runs/43070546126). The preview archive SHA-256 was `226544687a749c89273cb3c9c66c80b1a62c684efff73e673fb1646fb1fe829b`.

On the existing Intel macOS 26.7.3 installation, the preview displayed live readings from a physical Cudy LT500 V2 and reconnected after a normal quit and restart. A previously recorded session reopened with all 395 samples. The exported CSV contained the same 395 samples with cell data redacted. Clean downloaded-app launch, Local Network permission denial and recovery, side-by-side router comparison, macOS 13, Apple Silicon with a physical router, and the eight-hour instrumented soak were not run.

## Acceptance checklist for future release candidates

All evidence above remains attached to the revision named in its original entry. In
particular, results for `b1e4454` and `1be440e`, the 2026-10-08 local run and the
2026-10-09 owner report are not relabelled as tests of
`878509c663707d672b5cd8e61d09b8d275ba2bc5`. The 2026-11-15 checks above apply to the preview and scenarios described there.

The work below is ordered so candidate-bound automation and package provenance come
before installation and long-running owner-device tests. Record PASS, FAIL or NOT RUN
for every item against the exact candidate and artifact. A shorter smoke run, a
rendered preview, XCUITest, a deployment target or a Universal binary does not
substitute for the corresponding owner-device result.

### Automated candidate checks

1. **Run the local deterministic project check.** From the reviewed source checkout,
   run `python3 scripts/check.py` and preserve its report, exit status and summary.
   Evidence required: candidate commit, any dirty state, command, PASS/FAIL,
   test/check counts and the retained report path. This checks source behavior; it
   does not establish Finder launch, Local Network permission or physical-router use.

2. **Qualify the exact commit in hosted automation.** Require the current commit's
   Intel and Apple Silicon jobs, native interaction results, Universal packaging and
   CodeQL analysis to pass. Evidence required: run URLs or retained job reports whose
   commit and result identify the candidate, including every relevant job conclusion and
   artifact. The earlier `b1e4454` and `1be440e` runs remain evidence only for those
   revisions.

3. **Verify candidate package provenance and contents.** Build from the reviewed,
   clean source and preserve the package report with the candidate. Evidence
   required: `build.json` with the expected source commit and clean status, artifact
   checksum, both `x86_64` and `arm64` slices, expected version and signature status,
   archive file list and a passing publication manifest check. Label the result
   honestly as unsigned/ad-hoc until a separately approved signed distribution is
   produced.

### Owner-device checks

These checks use the packaged GUI on owner-controlled hardware. Record both the
candidate commit and artifact checksum, plus the macOS version and safe hardware
description (model and CPU architecture, never a serial number). Keep credentials,
SIM identifiers, cell IDs, IP and MAC addresses, Wi-Fi network names, complete
router-page captures and private measurement databases out of public evidence.

1. **Minimum macOS 13 runtime.** Execute the packaged Universal candidate on macOS
   13.x and record the exact OS version, app launch and basic menu/compact/workspace
   interaction. Evidence required: host details, artifact identity, steps, observed
   result, relevant redacted screenshots or logs and a PASS/FAIL conclusion. This is
   distinct from the clean first-launch check below; the macOS 13 deployment target
   and build success are not substitutes. Also exercise the packaged GUI on owner-controlled
   Intel and Apple Silicon Macs with a current macOS release. Record the exact OS
   build and native process architecture for each host.

2. **Clean launch and Local Network permission.** Start from the final packaged
   artifact in a clean application/install context, preferably after downloading and
   unzipping the archive. Launch it from Finder, exercise any unsigned-app Open
   Anyway path without disabling Gatekeeper, and test the Local Network prompt,
   allowed connection, denial and recovery. Evidence required: artifact checksum,
   macOS version, stable install path, launch path, prompt outcome, post-permission
   connection result, redacted screenshots or logs and PASS/FAIL for each scenario.
   A Terminal or diagnostic executable run does not establish this gate.

3. **Apple Silicon device and physical-router acceptance.** Install and run the
   candidate natively on an owner-controlled Apple Silicon Mac, not only on a hosted
   arm64 runner, and use the physical LT500 through the normal app interface.
   Evidence required: Apple Silicon model and native arm64 process architecture, OS
   version, artifact identity, real login and repeated readings for all four metrics,
   visible band/cell context, a same-time comparison with the router status page and
   a redacted result record. Do not retain the password or a complete router capture.

4. **Complete the owner-device comparison, restart and export flows.** Record two
   real antenna trials through the normal interface, including one with known
   matching band/cell/units; restart and reopen them; compare them; and export every
   stored sample. Exercise sleep/wake, network loss and recovery, login expiry,
   no service, manual pause and resume, and display reconnect on this candidate.
   Record whether stale readings are labelled and windows remain recoverable.
   Include the artifact identity, trial and sample counts, comparison result,
   restart and export results, and redacted evidence for each recovery scenario.

5. **Eight-hour instrumented soak.** Collect continuously for eight hours at the
   candidate polling interval while periodically exercising the UI. Evidence
   required: start/end timestamps, elapsed duration, Mac and OS details, artifact
   identity, polling interval, sample/request totals, gaps and events, UI
   responsiveness observations, display memory trend, database growth and a complete
   export check. The result passes only if the available observations show no
   accumulating memory/request leak and the UI remains responsive. Record a shorter
   development run separately and do not count it as this gate.

Validate the final downloaded unsigned archive using the Finder and Gatekeeper
steps above. Apple-trusted distribution requires separate candidate evidence for
Developer ID signing, Hardened Runtime, notarization and stapling.
