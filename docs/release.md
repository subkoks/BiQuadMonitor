# Release and acceptance

The 0.2.0 build is a development preview. A public source repository or downloadable CI artifact is not a stable-release acceptance result.

## Reproducible local preview

From a reviewed checkout with full Xcode selected:

```sh
python3 scripts/check.py --ui
python3 build_app.py
```

The app is written to `dist/preview/BiQuad Monitor.app`. The default Universal build must contain both `x86_64` and `arm64` slices. `build.json` records version, source commit, tracked-dirty state, executable hash and architectures. The bundle records its preview distribution status. Keep this provenance with the candidate evidence.

The builder uses ad-hoc signing and checks the resulting signature. It does not access signing credentials, notarize the app or publish a release.

## Candidate gates

Record PASS, FAIL or NOT RUN for each gate against the exact candidate commit and artifact. Preserve report files locally or in the corresponding CI run. Do not convert an unavailable environment into a passing result.

| Gate | Acceptance |
| --- | --- |
| Source publication | Review staged file names and diff; manifest and secret checks pass; no router backup, firmware, installer or private capture is included |
| Core behavior | Offline parser, formatting, transport, storage, recovery, export and coordinator checks pass |
| Native interface | XCUITest interactions pass; inspect compact, workspace and settings views, keyboard navigation and accessible labels |
| Window placement | All windows open with visible title bars; resizing and display reconnect recover onto an available screen |
| Packaging | Clean-source build succeeds; expected bundle manifest, architectures and ad-hoc or release signature are verified |
| Physical router | Authenticate through the packaged app, obtain repeated readings for all four metrics, and compare with the router page |
| Fault recovery | Exercise network loss, login expiry, no service, sleep/wake and manual pause; stale readings remain clearly marked |
| Saved experiments | Record two real trials, restart, reopen them, compare matching contexts and export every stored sample |
| Soak | Collect for eight hours; inspect UI responsiveness, resource use, database growth, gaps and export completeness |
| Platform coverage | Execute on Intel and Apple Silicon; test the declared minimum macOS runtime and a current macOS version |
| Distribution | Validate Developer ID signing, Hardened Runtime, notarization, stapling and clean downloaded-app launch |

A live acceptance password must be supplied through the app or an explicitly authorized standard-input mechanism. Never place it in shell arguments, environment variables, fixtures, logs or GitHub Actions. CI uses synthetic fixtures and has no access to the private router.

For the existing diagnostic executable mode, `--live-smoke-test` checks login and eight timed updates. It does not establish the eight-hour soak, Finder permission or all interaction checks. `--render-preview <path>` creates a synthetic image from the app's own view; label such images as simulated. A screenshot is not a substitute for interaction testing.

## Publishing

1. Finish review and the human merge decision.
2. Build a candidate from the reviewed commit and preserve provenance.
3. Complete applicable device, platform and distribution gates above.
4. Obtain the release decision for that concrete candidate and evidence.
5. Publish only the app artifact, checksums, source reference, release notes and safe evidence.

Developer ID and notarization need separately provisioned credentials. Those credentials have not been inspected or configured for this preview. If a gate remains open, label the artifact as a development preview and state the missing evidence; do not call it a stable release.

Keep the prior working app and a backup of measurement data before upgrading. Do not downgrade a database by editing its schema version. An incompatible database should remain intact for recovery or a deliberate migration.
