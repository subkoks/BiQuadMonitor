# BiQuad Monitor 0.2.0

Native cellular monitoring and antenna experiments for Cudy LT500 V2, firmware 2.4.16. Universal binary for Intel and Apple Silicon.

- Full menu labels: LTE band, SINR, RSRQ, RSRP and RSSI.
- Compact tuner and signal workspace with four linked history charts.
- Settling/recording antenna trials, matching-context comparisons and local SQLite history.
- Complete CSV/JSON exports with privacy defaults, optional sound and floating tuner.
- Correct Cudy web authentication and detailed-status fragment; no SSH, AT commands or router changes.

## Installation and distribution

Download `BiQuad-Monitor-0.2.0-universal-unsigned.zip`, unzip, and move **BiQuad Monitor.app** to Applications. Quit older copies first. Keep your prior app and measurement history for rollback.

**Explicitly unsigned and not notarized.** An ad-hoc integrity signature is included, but there is no Apple Developer ID signature. macOS may block first launch; use the per-app Open Anyway option in Privacy & Security if you choose to run it. Do not disable Gatekeeper globally.

Connect through Settings → Router using your router address and admin password. Wi-Fi is sufficient. Allow Local Network access when prompted. HTTP traffic remains unencrypted on the LAN; HTTPS requires a trusted router certificate.

RSSI such as `23` is the router's raw index, not dBm. Other router models/firmware are unverified.

## Evidence and limits

The owner confirmed correct live readings, saved trials surviving restart, and sleep/network recovery in normal 0.2.0 usage. Automated validation covers parser/measurement rules, transport, persistence, exports, coordinator/window behavior and native interface on hosted Intel and Apple Silicon. Release preparation preserves the router adapter and measurement logic. Exact source provenance and binary architectures are in `build.json`; asset checksums are in `SHA256SUMS`.

Minimum macOS 13 runtime, Apple Silicon user-device/router acceptance, clean downloaded-app launch and an eight-hour instrumented soak remain unverified. This release does not claim Apple-trusted distribution or full platform certification. Measurements stay local; no telemetry or cloud service.
