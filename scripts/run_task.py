#!/usr/bin/env python3
"""Run one explicitly approved local Codex task in an isolated worktree. Plan-only by default."""
import argparse
import json
import os
import re
import signal
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def git(*args, cwd=ROOT):
    return subprocess.check_output(["git", *args], cwd=cwd, text=True).strip()


def load_task(path):
    task = json.loads(path.read_text())
    required = {"id", "approved", "goal", "allowedPaths", "acceptance", "maxSeconds"}
    if set(task) != required or task["approved"] is not True or not re.fullmatch(r"[a-z0-9-]{3,64}", task["id"]):
        raise ValueError("Task must have the exact schema and explicit approval")
    if not isinstance(task["maxSeconds"], int) or not 60 <= task["maxSeconds"] <= 1800:
        raise ValueError("maxSeconds must be between 60 and 1800")
    for field in ["goal", "acceptance"]:
        if not isinstance(task[field], str) or not 10 <= len(task[field]) <= 8000:
            raise ValueError("Invalid task text")
    if not isinstance(task["allowedPaths"], list) or not 1 <= len(task["allowedPaths"]) <= 30:
        raise ValueError("Specify permitted source paths")
    for name in task["allowedPaths"]:
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or path.parts[0] not in {"Sources", "Tests", "docs", "scripts", "Resources"}:
            raise ValueError("Task paths must stay inside permitted project source directories")
    return task


def run(task, execute):
    commit = git("rev-parse", "HEAD")
    run_id = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + task["id"]
    print(json.dumps({"task": task["id"], "baseCommit": commit, "maxSeconds": task["maxSeconds"], "execution": execute}, indent=2))
    if not execute:
        return 0
    # No public issue content, cloud credentials, scheduler, push or merge step.
    private = ROOT / "private/automation"
    private.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = private / "active.lock"
    try:
        lock.mkdir()
    except FileExistsError:
        raise SystemExit("Another run is active; inspect its evidence before clearing the lock")
    report_dir = private / run_id
    report_dir.mkdir(mode=0o700)
    worktree = ROOT.parent / ("BiQuadMonitor-task-" + run_id)
    result = {"task": task["id"], "run": run_id, "baseCommit": commit, "status": "FAILED", "gates": []}
    try:
        subprocess.run(["git", "worktree", "add", "-b", "task/" + run_id, str(worktree), commit], cwd=ROOT, check=True)
        schema = {"type": "object", "additionalProperties": False, "properties": {"status": {"type": "string", "enum": ["completed", "blocked"]}, "summary": {"type": "string"}, "checks": {"type": "array", "items": {"type": "string"}}}, "required": ["status", "summary", "checks"]}
        schema_file = report_dir / "schema.json"
        schema_file.write_text(json.dumps(schema))
        final = report_dir / "agent-result.json"
        prompt = f'''Implement this owner-approved task only.
Goal: {task['goal']}
Allowed paths: {json.dumps(task['allowedPaths'])}
Acceptance: {task['acceptance']}
You are not alone: preserve unrelated work. Do not read credentials, .env files, private data, router backups, other projects, or transcript archives. Do not access the router, change workstation settings, install services, perform paid API calls, commit, push, merge or release. No automatic retry loop. After two failed attempts with one approach, change strategy or report blocked. Return structured evidence, not an unsupported success claim.'''
        command = ["codex", "exec", "--sandbox", "workspace-write", "--ephemeral", "--json", "--output-schema", str(schema_file), "--output-last-message", str(final), "-C", str(worktree), "-"]
        started = time.monotonic()
        with (report_dir / "private-events.jsonl").open("w") as log:
            os.chmod(log.name, 0o600)
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=log, stderr=log, text=True, start_new_session=True)
            try:
                process.communicate(prompt, timeout=task["maxSeconds"])
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                result["reason"] = "Elapsed-time budget exhausted"
                return 1
        result["seconds"] = round(time.monotonic() - started, 2)
        if process.returncode != 0 or not final.exists():
            result["reason"] = "Agent failed or returned no structured result"
            return 1
        response = json.loads(final.read_text())
        if set(response) != {"status", "summary", "checks"} or response["status"] != "completed" or not isinstance(response["summary"], str) or not isinstance(response["checks"], list) or any(not isinstance(item, str) for item in response["checks"]):
            result["reason"] = "Agent result does not meet completion schema"
            return 1
        if git("rev-parse", "HEAD", cwd=worktree) != commit:
            result["reason"] = "Agent committed or rewrote history unexpectedly"
            return 1
        changed = set(git("diff", "--name-only", "HEAD", cwd=worktree).splitlines()) | set(git("ls-files", "--others", "--exclude-standard", cwd=worktree).splitlines())
        allowed = lambda name: any(name == path.rstrip("/") or name.startswith(path.rstrip("/") + "/") for path in task["allowedPaths"])
        if any(not allowed(name) for name in changed):
            result["reason"] = "Changed files exceeded the task scope"
            return 1
        result["changedPaths"] = sorted(changed)
        with (report_dir / "checks.log").open("w") as log:
            try:
                check = subprocess.run(["python3", "scripts/check.py"], cwd=worktree, stdout=log, stderr=subprocess.STDOUT, timeout=600)
                code = check.returncode
            except subprocess.TimeoutExpired:
                code = 124
        result["gates"].append({"name": "deterministic-checks", "exitCode": code})
        result["status"] = "REVIEWABLE" if code == 0 else "FAILED"
        result["worktree"] = str(worktree)
        return 0 if code == 0 else 1
    finally:
        (report_dir / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        lock.rmdir()
        print("Run evidence: " + str(report_dir / "result.json"))
        print("Worktree retained for review; no automatic commit or publication.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("task", type=Path)
    parser.add_argument("--run", action="store_true", help="Execute the specifically approved task using existing Codex sign-in")
    args = parser.parse_args()
    try:
        raise SystemExit(run(load_task(args.task), args.run))
    except (ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error))
