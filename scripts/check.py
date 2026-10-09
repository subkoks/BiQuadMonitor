#!/usr/bin/env python3
"""Deterministic gate with fresh evidence and bounded process-group execution."""
import argparse
import contextlib
import json
import os
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def write_evidence(path, result):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(result, indent=2) + "\n")
    temporary.replace(path)


def signal_group(process, number):
    for attempt in range(2):
        try:
            os.killpg(process.pid, number)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            # On macOS a group containing only its unreaped zombie leader can
            # return EPERM. Reap our child and retry; real denial still fails.
            if attempt:
                raise
            process.poll()


def terminate_group(process, grace=1.0):
    """Stop descendants even if the direct process has already exited; reap it."""
    signal_group(process, signal.SIGTERM)
    deadline = time.monotonic() + grace
    while signal_group(process, 0) and time.monotonic() < deadline:
        process.poll()
        time.sleep(0.02)
    if signal_group(process, 0):
        signal_group(process, signal.SIGKILL)
    process.wait()


def run_command(command, *, cwd, timeout, stdout=None, input_text=None, text=True, cleanup_grace=1.0):
    process = subprocess.Popen(command, cwd=cwd, stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
                               stdout=stdout, stderr=subprocess.STDOUT, text=text, start_new_session=True)
    try:
        output, _ = process.communicate(input=input_text, timeout=timeout)
        return subprocess.CompletedProcess(command, process.returncode, output)
    finally:
        terminate_group(process, grace=cleanup_grace)


@contextlib.contextmanager
def interruption_signals():
    def interrupted(number, frame):
        raise KeyboardInterrupt("Interrupted by signal " + str(number))
    previous = {number: signal.signal(number, interrupted) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def default_gates(root, ui):
    # Resolve this next to the trusted harness, never from the target worktree.
    publication = Path(__file__).resolve().with_name("publication_check.py")
    gates = [("source-manifest", [sys.executable, "-I", "-B", str(publication), "--project-root", str(root)], 60),
             ("automation", [sys.executable, "-I", "-B", "-m", "unittest", "discover", "-s", "Tests/AutomationTests", "-v"], 60),
             ("unit-transport-store", ["swift", "test"], 300),
             ("window-coordinator", [str(root / ".build/debug/BiQuadMonitor"), "--ui-smoke-test"], 60)]
    if ui:
        gates.append(("native-ui", ["xcodebuild", "-project", "BiQuadMonitor.xcodeproj", "-scheme", "BiQuadMonitor",
                                    "-destination", "platform=macOS", "-derivedDataPath", ".build/xcode", "test"], 600))
    return gates


def run_checks(root, *, ui=False, evidence_dir=None, gates=None):
    root = Path(root).resolve()
    output = Path(evidence_dir).resolve() if evidence_dir else root / "dist/checks"
    output.mkdir(parents=True, exist_ok=True)
    result_path = output / "result.json"
    result = {"run": uuid.uuid4().hex, "commit": None, "gates": [], "status": "RUNNING"}
    write_evidence(result_path, result)
    exit_code = 1
    try:
        commit = run_command(["git", "rev-parse", "HEAD"], cwd=root, stdout=subprocess.PIPE, timeout=30)
        if commit.returncode:
            result["status"] = "TEST_INVALID"
            result["reason"] = "Cannot identify the checked source commit"
            return 1
        result["commit"] = commit.stdout.strip()
        for name, command, timeout in (default_gates(root, ui) if gates is None else gates):
            started = time.monotonic()
            gate = {"name": name, "status": "RUNNING"}
            result["gates"].append(gate)
            write_evidence(result_path, result)
            with (output / (name + ".log")).open("w") as log:
                try:
                    code = run_command(command, cwd=root, stdout=log, timeout=timeout).returncode
                    gate["status"] = "PASS" if code == 0 else "FAIL"
                except subprocess.TimeoutExpired:
                    code = 124
                    gate.update(status="FAIL", reason="Elapsed-time limit exceeded")
                except OSError as error:
                    code = 127
                    gate.update(status="TEST_INVALID", reason="Command could not start: " + type(error).__name__)
                except KeyboardInterrupt:
                    code = 130
                    gate.update(status="INTERRUPTED", reason="Execution interrupted")
                gate.update(exitCode=code, seconds=round(time.monotonic() - started, 2))
            print(f"{name}: {gate['status']}", flush=True)
            if code != 0:
                result["status"] = gate["status"]
                return 1
        result["status"] = "PASS"
        exit_code = 0
    except OSError as error:
        result.update(status="TEST_INVALID", reason="Environment setup failed: " + type(error).__name__)
    except KeyboardInterrupt:
        result.update(status="INTERRUPTED", reason="Execution interrupted")
    except Exception as error:
        result.update(status="FAIL", reason="Harness error: " + type(error).__name__)
    finally:
        if result["status"] == "RUNNING":
            result.update(status="FAIL", reason="Run ended before completion")
        write_evidence(result_path, result)
    return exit_code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=ROOT)
    parser.add_argument("--evidence-dir", type=Path, help="Separate trusted evidence directory")
    parser.add_argument("--ui", action="store_true", help="Run native XCUITest interaction checks")
    args = parser.parse_args()
    with interruption_signals():
        return run_checks(args.project_root, ui=args.ui, evidence_dir=args.evidence_dir)


if __name__ == "__main__":
    raise SystemExit(main())
