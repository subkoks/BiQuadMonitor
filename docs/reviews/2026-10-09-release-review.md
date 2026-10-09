# Release consolidation review — 2026-10-09

Scope: BiQuadMonitor source, transport/authentication, measurements, coordinator, persistence/export, UI, packaging, automation, Git worktrees/branches, open PRs and required checks. Owner authorized consolidation to main, redundant branch/worktree retirement and an explicitly unsigned GitHub release.

## Findings

- **Major, fixed:** `.github/workflows/codeql.yml` had separate Dependabot PRs for init/analyze. Failed CI explicitly reported a v4/v3 configuration mismatch. Update both to the same pinned v4.38.2 commit and group future CodeQL updates. Required checks remain enforced.
- **Minor, fixed:** release packaging only labelled previews. Add an explicit unsigned mode requiring a clean tracked checkout, preserve source provenance, disclose distribution status in the bundle/UI and document installation/limits. No signing credentials are used.
- **Preservation:** the retired task worktree contained a two-line hypothetical comparison example. Review/preserve the example on main and save its patch under ignored recovery before removal. Its base commit is already an ancestor of main; ignored contents are build output and Finder metadata.
- **Repository metadata warning:** `git fsck --no-reflogs` reports invalid Finder metadata at `refs/.DS_Store` plus unreachable objects. Commit history/reachability is reviewed separately. Do not prune unreachable objects or manually edit the Git directory during branch consolidation.

No additional merge-blocking app defect was identified in this source review. Parameterized SQL, lifetime writer ownership, crash recovery, full export, missing/unit handling, chart gaps, same-origin redirects, bounded HTTP reads and sanitized diagnostics were reviewed. Existing regression tests cover the affected runtime contracts; this is not proof of every device/runtime condition.

## Release decision

The owner explicitly chose unsigned distribution and confirmed normal-use live readings, trial persistence, restart and sleep/network recovery. Keep remaining platform/soak/downloaded-launch limits visible in release notes. Required CI and CodeQL must pass on the release-preparation PR before normal merge. Build the final archive from clean main, verify app-only contents, both slices, ad-hoc signature, packaged smoke, provenance and checksums before publication. No protection bypass, history rewrite or secret access is authorized or necessary.
