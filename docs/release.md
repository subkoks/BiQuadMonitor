# Release and acceptance

Version 0.2.0 is distributed as an **unsigned Universal release**, by explicit owner decision on 2026-10-09. It has an ad-hoc integrity signature, no Developer ID signature and no notarization. Preview builds remain available for development. Source publication and CI artifacts alone do not establish physical-device acceptance.

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
| Distribution | Verify clean downloaded-app launch. Version 0.2.0 uses unsigned distribution. Apple-trusted distribution also requires Developer ID signing, Hardened Runtime, notarization and stapling. |

## Owner-device evidence record

Copy this record for each reviewed candidate. The gate requirements are the [Candidate gates](#candidate-gates); keep detailed captures in the external owner-device evidence sheet and record only a redacted summary or reference here. Use `PASS`, `FAIL` or `NOT RUN` for every result; do not infer a pass from missing evidence.

- **Candidate:** BiQuadMonitor 0.2.0
- **Source SHA:** `<exact reviewed commit SHA>`
- **Package SHA-256:** `<package archive SHA-256>`
- **macOS:** `<version and build>`
- **CPU architecture:** `<arm64 or x86_64>`
- **Owner evidence reference:** `<redacted external-sheet or report reference>`

- [ ] **Physical router** ([gate](#candidate-gates)) — Result: `<PASS / FAIL / NOT RUN>`; redacted evidence: `<packaged-app authentication, repeated readings for all four metrics and router-page comparison>`
- [ ] **Finder and Local Network** ([gate](#candidate-gates)) — Result: `<PASS / FAIL / NOT RUN>`; redacted evidence: `<Finder launch, permission prompt/allow/deny/recovery and subsequent readings>`
- [ ] **Fault recovery** ([gate](#candidate-gates)) — Result: `<PASS / FAIL / NOT RUN>`; redacted evidence: `<network loss, login expiry, no service, sleep/wake and manual pause; stale-state and source-data outcomes>`
- [ ] **Window placement** ([gate](#candidate-gates)) — Result: `<PASS / FAIL / NOT RUN>`; redacted evidence: `<visible title bars, resizing and recovery after display reconnect>`
- [ ] **Saved experiments and export** ([gate](#candidate-gates)) — Result: `<PASS / FAIL / NOT RUN>`; redacted evidence: `<two real trials, restart/reopen, matching-context comparison and complete stored-sample export>`
- [ ] **Eight-hour soak** ([gate](#candidate-gates)) — Result: `<PASS / FAIL / NOT RUN>`; redacted evidence: `<actual duration, responsiveness, resource/database growth, gaps and export completeness>`
- [ ] **Platform coverage** ([gate](#candidate-gates)) — Result: `<PASS / FAIL / NOT RUN>`; redacted evidence: `<Intel and Apple Silicon runs, minimum and current macOS versions, and outcomes>`
- [ ] **Distribution** ([gate](#candidate-gates)) — Result: `<PASS / FAIL / NOT RUN>`; redacted evidence: `<unsigned 0.2.0 signature/notarization state, archive-hash match and clean downloaded-app launch outcome>`

A live acceptance password must be supplied through the app or an explicitly authorized standard-input mechanism. Never place it in shell arguments, environment variables, fixtures, logs or GitHub Actions. CI uses synthetic fixtures and has no access to the private router.

For the existing diagnostic executable mode, `--live-smoke-test` checks login and eight timed updates. It does not establish the eight-hour soak, Finder permission or all interaction checks. `--render-preview <path>` creates a synthetic image from the app's own view; label such images as simulated. A screenshot is not a substitute for interaction testing.

## Publishing

1. Finish review and the human merge decision.
2. Build a candidate from the reviewed commit and preserve provenance.
3. Complete applicable device, platform and distribution gates above.
4. Obtain the release decision for that concrete candidate and evidence.
5. Publish only the app artifact, checksums, source reference, release notes and safe evidence.

Developer ID and notarization need separately provisioned credentials. They have not been inspected or configured. Version 0.2.0 explicitly uses unsigned distribution instead; release notes must disclose this and all unverified platform/stability gates. Do not claim Apple-trusted distribution or full platform certification.

## Unsigned 0.2.0 packaging

From the reviewed, clean `main` commit:

```sh
python3 build_app.py --distribution unsigned
ditto -c -k --keepParent 'dist/release/BiQuad Monitor.app' dist/release/BiQuad-Monitor-0.2.0-universal-unsigned.zip
python3 scripts/publication_check.py --archive dist/release/BiQuad-Monitor-0.2.0-universal-unsigned.zip
```

Keep `build.json` and `SHA256SUMS` alongside the archive. Publish an annotated `v0.2.0` tag at that exact commit. The archive contains only the application. Normal macOS downloaded-app policy may block unsigned software; use Apple's per-app Open Anyway flow if you choose to run it. Never disable Gatekeeper globally.

Keep the prior working app and a backup of measurement data before upgrading. Do not downgrade a database by editing its schema version. An incompatible database should remain intact for recovery or a deliberate migration.
