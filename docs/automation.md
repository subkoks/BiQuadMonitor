# Codex + GitHub delivery workflow

One owner-approved task becomes one worktree, one reviewable diff and one evidence report. CI runs deterministic source, unit, transport, SQLite, window/coordinator and native UI gates. Universal packaging produces a clearly labelled development artifact. CodeQL inspects Swift, Python and Actions. Required checks are configured only after their real job names exist.

## Local on-demand tasks

Copy `docs/task-example.json` outside the tracked source or into ignored `private/`, edit the goal, permitted paths and acceptance, and explicitly set `approved` to true after owner review.

```sh
python3 scripts/run_task.py private/my-task.json        # validate and show scope
python3 scripts/run_task.py private/my-task.json --run  # execute that approved task
```

The runner uses the existing Codex login and profile, workspace-write sandbox, structured final result, one active-run lock and a maximum 30-minute agent duration. It checks the task manifest before execution, rejecting malformed, empty, nonstring, absolute and escaping paths. It keeps the worktree and private report for review. It never commits, pushes, merges or publishes a release. No cloud model credentials or scheduler are installed.

Before starting Codex, it captures `scripts/check.py` and `scripts/publication_check.py` from the exact base commit as read-only harness files outside the task worktree. Acceptance invokes that copy with an explicit project root; changing the worktree's check script cannot replace the acceptance harness. Hashes are checked before and after acceptance. Commit these runner changes before the first pilot so the base commit contains the compatible harness.

Git HEAD and permitted changed paths are checked before the agent, after the agent, and after acceptance. The path audit includes ignored untracked files, except disposable `.build/`, `.swiftpm/` and `dist/checks/` output. Python acceptance commands disable bytecode generation so their own imports do not create out-of-scope caches. Environment-file changes, changed symlinks and symlinked output directories are rejected. These checks detect final filesystem state, not every intermediate action.

Each check run writes a new run ID and `RUNNING` evidence before starting commands, then finalizes a non-PASS result on failure, interruption or launch error. Missing tools and setup failures are `TEST_INVALID`, not successful tests. Agent, acceptance and gate processes run in managed process groups. Timeout, Ctrl-C and termination signals trigger group cleanup and reap the direct child before releasing the run lock; acceptance has additional cleanup time for its gate processes.

The sandbox, captured harness and post-run checks are **not a complete security boundary**. Builds and tests execute changed project code with the invoking user's permissions, and intentionally detached processes can escape a process group. The runner cannot prove absence of private-data reads, network effects or transient writes. Run only owner-approved work in a trusted checkout and review the resulting diff and evidence. Elapsed time is enforced; this runner does not claim a model-token or monetary budget. Existing account limits still govern usage.

The real-agent pilot remains pending; do not enable recurring runs before that pilot passes. Offline runner regression checks require no Codex invocation or credentials:

```sh
python3 -B -m unittest discover -s Tests/AutomationTests -v
```

Raw agent events remain under ignored `private/automation/` and must not be uploaded. Gate evidence is kept alongside the run's private report; ordinary `scripts/check.py` evidence is under ignored `dist/checks/`.

## Review and release

1. Owner approves a scoped task.
2. Codex implements in a worktree with explicit acceptance and stop conditions.
3. Deterministic checks fail closed; a narrative cannot turn a failing gate green.
4. Review the resulting diff, behavior, UI and security evidence; prepare a draft PR.
5. Human merge decision; then produce a commit-stamped candidate.
6. Validate physical-router behavior, installation and distribution signing before an approved stable release.

GitHub workflow artifacts are the initial evidence dashboard. Feature development and cloud CI use no self-hosted runner on the user's LAN. On-demand tasks are local and manually initiated. Optional schedules remain a later opt-in.
