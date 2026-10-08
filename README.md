# BiQuad Monitor

Native, local macOS menu-bar monitor for antenna experiments with a Cudy LT500. Built for Intel macOS 13+ using Swift, SwiftUI and AppKit, with no third-party runtime dependencies.

## Run

Run `python3 build_app.py`, then open `dist/BiQuad Monitor 0.1.4.app`. Click **LTE · Setup**, then **Settings**. Keep router IP `192.168.10.1`, enter your router's **web admin password**, and click **Connect**. Allow local-network access if macOS asks. The app signs in using the router's web login, not SSH. You can choose to remember the password in this Mac's Keychain; otherwise it is used for the current login only. Open Settings and Connect again after a session expires or the app restarts. Nothing accesses browser passwords or cookies.

Menu labels: **S** = SINR, **Q** = RSRQ, **P** = RSRP, **R** = RSSI. The dashboard window displays all four metrics, the last 60 samples as sparklines, averages over the last 60 seconds, LTE band and cell ID. Default polling is every five seconds, with no overlapping requests. On failure the menu says Offline, and the last values remain grey with their last-update state; they are not presented as live. RSSI is kept in the router's original units: positive values such as 24 are labeled **raw index**, negative readings are labeled **dBm**. Unknown or malformed readings appear as a dash.

## Antenna comparisons

Name the antenna position, click **New trial**, then allow at least 60 seconds to settle. **Set reference** captures the current averages. Adjust the antenna and watch the averages and reference differences. Comparison is suppressed when band, cell or RSSI units change. New trial clears the in-memory readings. **Export CSV** saves the current trial's last 720 samples (one hour at the default interval). Export before starting another trial. Demo readings are labeled in the interface and CSV. Higher values mean stronger power or better signal quality, but throughput can also depend on network load and other conditions. Prioritize SINR and compare RSRQ/RSRP as well.

## Scope and security

Only a private IPv4 router address is accepted. No cloud, telemetry, router-side installation, AT commands, SMS access or configuration writes. The only POST is the login form; monitoring uses GET on the cellular status page. The password uses the SHA-256 challenge flow seen in LT500 firmware 2.4.16; older plain-password LuCI forms are supported too. HTTP traffic is unencrypted on the LAN, including authenticated readings and login material. HTTPS is optional and requires a certificate trusted by macOS; certificate verification is never disabled. Cross-origin redirects are blocked. Sessions use ephemeral cookies and no disk cache. Raw responses, SIM identifiers and passwords are never logged or exported. No launch-at-login service is installed.

## Validation and limitations

`swift test` tests HTML parsing, missing values, units, numeric ranges, login request encoding and local address validation. `python3 build_app.py` builds and ad-hoc signs the app locally. The app is not notarized or App Store distributed. Use **Demo** in Settings to preview simulated readings without connecting or accessing Keychain.

Live authentication and repeated readings were verified on the user's LT500 V2 with firmware 2.4.16-20250804-150319 on 2026-10-07. The app reads `/cgi-bin/luci/admin/network/gcom/status?detail=1&iface=4g`, the same detailed fragment loaded by the browser. The parent `/gcom?iface=4g` page contains only tabs and a JavaScript loader; it cannot be parsed as a signal table. Other firmware versions or localized labels may require an adapter. Missing readings fail explicitly instead of inventing metrics.

Protocol research: Cudy's own login JavaScript and [community Cudy integration](https://github.com/usersaynoso/ha-cudy-router). This app is an independent Swift implementation; no third-party code is bundled. Antenna reference supplied by the user: [Double BiQuad calculator](https://buildyourownantenna.blogspot.com/2014/07/double-biquad-antenna-calculator.html) (the page could not be fetched during this build).

## 0.1.4: verified connection repair

The previous build successfully signed in but requested the empty parent page instead of the detailed cellular fragment. This caused the exact error `HTTP 200, HTML; raw metric labels: none. Rows: 0`. The detailed status endpoint also requires `detail=1`; without it the router sends a summary without the four signal readings.

A transport regression test reproduced that exact error before the endpoint fix and passes afterward. The test fixture preserves only the four metric rows from the real response, including the empty leading column and duplicate desktop/mobile paragraphs. It contains no passwords, session cookies, SIM identifiers or other router configuration. There are 27 passing tests covering the transport request, parsing, session expiry, safe error messages, login encoding, address validation and window geometry.

The packaged native app completed eight live readings through its normal login, timer and dashboard path at five-second intervals. All four metrics were present; SINR varied between 6 and 12 dB, with RSRQ −9 dB, RSRP −96 dBm and RSSI 23 (raw index). These are observations from that run, not expected fixed values. The native dashboard was captured and inspected. Release build, ad-hoc signature and Info.plist validation passed.

The dashboard is now 400 × 530 points, with standard draggable title bars, screen-boundary recovery and scrollable content. Menu-bar readings omit unnecessary decimal zeros. No router configuration, firmware or backup changes were required. Older app builds and source recovery copies remain available.

### Developer checks

- `swift test` runs the deterministic offline tests; no router credentials are needed.
- `python3 build_app.py` builds the versioned app. The provided app is already built.
- Run the packaged executable with `--ui-smoke-test` to verify off-screen window recovery; it returns a nonzero exit status on failure.
- `--live-smoke-test` is an explicit live acceptance check against `http://192.168.10.1`. Supply the password on standard input through a pipe, never as a command-line argument or environment variable. It exercises normal connection and timed polling, prints only the four signal readings, and exits after eight successful updates. It does not read or modify Keychain or saved preferences. Optional `--render-live <path>` captures only the app's own dashboard; `--keep-connected` leaves the verified session running afterward. These diagnostic flags are not required for ordinary use.

The supplied router backup can contain credentials. Keep it private; it is not required to build or run the app and is not included in the app bundle.
