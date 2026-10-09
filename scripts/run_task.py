#!/usr/bin/env python3
"""Run one approved local Codex task with a captured acceptance harness. Plan-only by default."""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

from check import interruption_signals, run_command, write_evidence

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODEL = "gpt-6-astra"


def model_name(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,127}", value):
        raise ValueError("Model must be a nonempty model identifier")
    return value


def agent_command(worktree, schema_file, final, model=DEFAULT_MODEL):
    # Per-run overrides preserve the existing login without inheriting provider
    # aliases or changing any user configuration. Rules and AGENTS remain loaded.
    return ["codex", "exec", "--ignore-user-config", "--model", model_name(model),
            "-c", 'model_provider="openai"', "-c", 'forced_login_method="chatgpt"',
            "-c", 'approval_policy="never"', "--sandbox", "workspace-write",
            "--ephemeral", "--json", "--output-schema", str(schema_file),
            "--output-last-message", str(final), "-C", str(worktree), "-"]


def git(*args, cwd=ROOT):
    result = run_command(["git", *args], cwd=cwd, stdout=subprocess.PIPE, timeout=60)
    if result.returncode:
        raise ValueError("Git inspection failed")
    return result.stdout.rstrip("\n")


def load_task(path):
    task = json.loads(path.read_text())
    required = {"id", "approved", "goal", "allowedPaths", "acceptance", "maxSeconds"}
    if not isinstance(task, dict) or set(task) != required or task["approved"] is not True:
        raise ValueError("Task must have the exact schema and explicit approval")
    if not isinstance(task["id"], str) or not re.fullmatch(r"[a-z0-9-]{3,64}", task["id"]):
        raise ValueError("Invalid task identifier")
    if type(task["maxSeconds"]) is not int or not 60 <= task["maxSeconds"] <= 1800:
        raise ValueError("maxSeconds must be between 60 and 1800")
    for field in ["goal", "acceptance"]:
        if not isinstance(task[field], str) or not 10 <= len(task[field]) <= 8000:
            raise ValueError("Invalid task text")
    if not isinstance(task["allowedPaths"], list) or not 1 <= len(task["allowedPaths"]) <= 30:
        raise ValueError("Specify permitted source paths")
    normalized = []
    for name in task["allowedPaths"]:
        if not isinstance(name, str) or not name or any(ord(character) < 32 for character in name):
            raise ValueError("Task paths must be nonempty strings without control characters")
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] not in {"Sources", "Tests", "docs", "scripts", "Resources"}:
            raise ValueError("Task paths must stay inside permitted project source directories")
        normalized.append(path.as_posix())
    task["allowedPaths"] = sorted(set(normalized))
    return task


def capture_harness(commit, destination, *, source_root=ROOT):
    """Copy exact committed gate code outside the writable worktree before Codex."""
    destination.mkdir(mode=0o700)
    manifest = {}
    for name in ("check.py", "publication_check.py"):
        captured = run_command(["git", "show", commit + ":scripts/" + name], cwd=source_root, stdout=subprocess.PIPE, timeout=60, text=False)
        if captured.returncode:
            raise ValueError("Could not capture committed acceptance harness")
        source = captured.stdout
        if b"--project-root" not in source:
            raise ValueError("Commit the updated acceptance scripts before running a task")
        target = destination / name
        target.write_bytes(source)
        target.chmod(0o400)
        manifest[name] = hashlib.sha256(target.read_bytes()).hexdigest()
    return manifest


def verify_harness(destination, manifest):
    for name, expected in manifest.items():
        if hashlib.sha256((destination / name).read_bytes()).hexdigest() != expected:
            raise ValueError("Captured acceptance harness changed unexpectedly")


def changed_paths(worktree):
    tracked = set(filter(None, git("diff", "--name-only", "-z", "HEAD", cwd=worktree).split("\0")))
    # Include ignored untracked files too. Only known disposable build output is exempt.
    untracked = set(filter(None, git("ls-files", "--others", "-z", "--", ".", ":(exclude).build", ":(exclude)dist/checks", ":(exclude).swiftpm", cwd=worktree).split("\0")))
    return tracked | untracked


def audit_scope(worktree, commit, allowed):
    worktree = worktree.resolve()
    if git("rev-parse", "HEAD", cwd=worktree) != commit:
        raise ValueError("Agent committed or rewrote history unexpectedly")
    for generated in (".build", "dist", "dist/checks", ".swiftpm"):
        if (worktree / generated).is_symlink():
            raise ValueError("Generated-output directories must not be symlinks")
    changed = changed_paths(worktree)
    for name in changed:
        path = Path(name)
        if not any(name == scope or name.startswith(scope + "/") for scope in allowed):
            raise ValueError("Changed files exceeded the task scope")
        if any(part.startswith(".env") for part in path.parts):
            raise ValueError("Environment files are outside automated task scope")
        target = worktree / path
        if any(parent.is_symlink() for parent in [target, *target.parents] if parent != worktree and worktree in parent.parents):
            raise ValueError("Changed symlinks are outside automated task scope")
        if worktree not in target.resolve().parents:
            raise ValueError("Changed path escaped the task worktree")
    return sorted(changed)


def run(task, execute, model=DEFAULT_MODEL):
    model = model_name(model)
    commit = git("rev-parse", "HEAD")
    run_id = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + task["id"] + "-" + uuid.uuid4().hex[:8]
    print(json.dumps({"task": task["id"], "baseCommit": commit, "maxSeconds": task["maxSeconds"], "model": model,
                      "provider": "openai", "loginMethod": "chatgpt", "execution": execute}, indent=2))
    if not execute:
        return 0
    private = ROOT / "private/automation"
    private.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = private / "active.lock"
    try:
        lock.mkdir()
    except FileExistsError:
        raise SystemExit("Another run is active; inspect its evidence before clearing the lock")
    report_dir = private / run_id
    worktree = ROOT.parent / ("BiQuadMonitor-task-" + run_id)
    result = {"task": task["id"], "run": run_id, "baseCommit": commit, "status": "RUNNING", "gates": [], "worktree": str(worktree),
              "model": model, "provider": "openai", "loginMethod": "chatgpt"}
    result_path = report_dir / "result.json"
    started = time.monotonic()
    try:
        report_dir.mkdir(mode=0o700)
        write_evidence(result_path, result)
        harness = report_dir / "trusted-harness"
        manifest = capture_harness(commit, harness)
        result["harnessSHA256"] = manifest
        creation = run_command(["git", "worktree", "add", "-b", "task/" + run_id, str(worktree), commit], cwd=ROOT, timeout=60)
        if creation.returncode:
            raise ValueError("Could not create the task worktree")
        audit_scope(worktree, commit, task["allowedPaths"])
        schema = {"type": "object", "additionalProperties": False, "properties": {"status": {"type": "string", "enum": ["completed", "blocked"]}, "summary": {"type": "string"}, "checks": {"type": "array", "items": {"type": "string"}}}, "required": ["status", "summary", "checks"]}
        schema_file = report_dir / "schema.json"
        schema_file.write_text(json.dumps(schema))
        final = report_dir / "agent-result.json"
        prompt = f'''Implement this owner-approved task only.
Goal: {task['goal']}
Allowed paths: {json.dumps(task['allowedPaths'])}
Acceptance: {task['acceptance']}
You are not alone: preserve unrelated work. Do not read credentials, .env files, private data, router backups, other projects, or transcript archives. Do not access the router, change workstation settings, install services, perform paid API calls, commit, push, merge or release. No automatic retry loop. After two failed attempts with one approach, change strategy or report blocked. Return structured evidence, not an unsupported success claim.'''
        command = agent_command(worktree, schema_file, final, model)
        with (report_dir / "private-events.jsonl").open("w") as log:
            os.chmod(log.name, 0o600)
            agent = run_command(command, cwd=worktree, stdout=log, input_text=prompt, timeout=task["maxSeconds"])
        if agent.returncode != 0 or not final.exists():
            raise ValueError("Agent failed or returned no structured result")
        response = json.loads(final.read_text())
        if not isinstance(response, dict) or set(response) != {"status", "summary", "checks"} or response["status"] != "completed" or not isinstance(response["summary"], str) or not isinstance(response["checks"], list) or any(not isinstance(item, str) for item in response["checks"]):
            raise ValueError("Agent result does not meet completion schema")
        result["changedPaths"] = audit_scope(worktree, commit, task["allowedPaths"])
        verify_harness(harness, manifest)
        evidence = report_dir / "acceptance"
        with (report_dir / "checks.log").open("w") as log:
            check = run_command([sys.executable, "-I", "-B", str(harness / "check.py"), "--project-root", str(worktree), "--evidence-dir", str(evidence)],
                                cwd=worktree, stdout=log, timeout=600, cleanup_grace=5)
        verify_harness(harness, manifest)
        result["changedPaths"] = audit_scope(worktree, commit, task["allowedPaths"])
        check_result = json.loads((evidence / "result.json").read_text())
        if not isinstance(check_result, dict):
            raise ValueError("Trusted acceptance evidence is malformed")
        result["gates"].append({"name": "deterministic-checks", "exitCode": check.returncode,
                                "status": check_result.get("status", "FAILED"), "run": check_result.get("run")})
        if check.returncode != 0 or check_result.get("status") != "PASS" or check_result.get("commit") != commit or not check_result.get("run"):
            result["status"] = "TEST_INVALID" if check_result.get("status") == "TEST_INVALID" else "FAILED"
            result["reason"] = "Trusted acceptance checks did not pass"
            return 1
        result["status"] = "REVIEWABLE"
        return 0
    except subprocess.TimeoutExpired:
        result.update(status="FAILED", reason="Elapsed-time budget exhausted; process group terminated")
        return 1
    except KeyboardInterrupt:
        result.update(status="INTERRUPTED", reason="Execution interrupted; process group terminated")
        return 1
    except OSError as error:
        result.update(status="TEST_INVALID", reason="Required file or command unavailable: " + type(error).__name__)
        return 1
    except (ValueError, TypeError) as error:
        result.update(status="FAILED", reason=str(error))
        return 1
    finally:
        result["seconds"] = round(time.monotonic() - started, 2)
        if result["status"] == "RUNNING":
            result.update(status="FAILED", reason="Run ended before completion")
        try:
            if report_dir.exists():
                write_evidence(result_path, result)
        finally:
            lock.rmdir()
        print("Run evidence: " + str(result_path))
        print("Worktree retained for review; no automatic commit or publication.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("task", type=Path)
    parser.add_argument("--model", default=DEFAULT_MODEL, help="OpenAI model for this run (default: gpt-6-astra)")
    parser.add_argument("--run", action="store_true", help="Execute the specifically approved task using existing Codex sign-in")
    args = parser.parse_args()
    try:
        with interruption_signals():
            raise SystemExit(run(load_task(args.task), args.run, model=args.model))
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
