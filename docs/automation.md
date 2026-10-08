# Codex + GitHub delivery workflow

One owner-approved task becomes one worktree, one reviewable diff and one evidence report. CI runs deterministic source, unit, transport, SQLite, window/coordinator and native UI gates. Universal packaging produces a clearly labelled development artifact. CodeQL inspects Swift, Python and Actions. Required checks are configured only after their real job names exist.

## Local on-demand tasks

Copy `docs/task-example.json` outside the tracked source or into ignored `private/`, edit the goal, permitted paths and acceptance, and explicitly set `approved` to true after owner review.

```sh
python3 scripts/run_task.py private/my-task.json        # validate and show scope
python3 scripts/run_task.py private/my-task.json --run  # execute that approved task
```

The runner uses the existing Codex login and profile, workspace-write sandbox, structured final result, one active-run lock and a maximum 30-minute agent duration. It verifies changed paths and unchanged Git HEAD, then runs deterministic checks. It keeps the worktree and private report for review. It never commits, pushes, merges or publishes a release. No cloud model credentials or scheduler are installed.

The scope check is a post-run validation, not a complete read-access security boundary. Project/personal rules still apply. Elapsed time is enforced; this runner does not claim a model-token or monetary budget. Existing account limits still govern usage. Its manual real-agent pilot remains pending; do not enable recurring runs before that pilot passes. Raw agent events remain under ignored `private/automation/` and must not be uploaded.

## Review and release

1. Owner approves a scoped task.
2. Codex implements in a worktree with explicit acceptance and stop conditions.
3. Deterministic checks fail closed; a narrative cannot turn a failing gate green.
4. Review the resulting diff, behavior, UI and security evidence; prepare a draft PR.
5. Human merge decision; then produce a commit-stamped candidate.
6. Validate physical-router behavior, installation and distribution signing before an approved stable release.

GitHub workflow artifacts are the initial evidence dashboard. Feature development and cloud CI use no self-hosted runner on the user's LAN. On-demand tasks are local and manually initiated. Optional schedules remain a later opt-in.
