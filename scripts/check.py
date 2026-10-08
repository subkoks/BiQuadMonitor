#!/usr/bin/env python3
"""Deterministic local/CI gate. Results are written under ignored dist/checks."""
import argparse
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ui", action="store_true", help="Run native XCUITest interaction checks")
    args = parser.parse_args()
    output = ROOT / "dist/checks"
    output.mkdir(parents=True, exist_ok=True)
    result = {"commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), "gates": [], "status": "RUNNING"}
    gates = [("source-manifest", ["python3", "scripts/publication_check.py"], 60), ("unit-transport-store", ["swift", "test"], 300), ("window-coordinator", [".build/debug/BiQuadMonitor", "--ui-smoke-test"], 60)]
    if args.ui:
        gates.append(("native-ui", ["xcodebuild", "-project", "BiQuadMonitor.xcodeproj", "-scheme", "BiQuadMonitor", "-destination", "platform=macOS", "-derivedDataPath", ".build/xcode", "test"], 600))
    for name, command, timeout in gates:
        started = time.monotonic()
        with (output / (name + ".log")).open("w") as log:
            try:
                code = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=timeout).returncode
            except subprocess.TimeoutExpired:
                code = 124
        result["gates"].append({"name": name, "status": "PASS" if code == 0 else "FAIL", "exitCode": code, "seconds": round(time.monotonic() - started, 2)})
        print(f"{name}: {result['gates'][-1]['status']}", flush=True)
        if code != 0:
            result["status"] = "FAIL"
            break
    else:
        result["status"] = "PASS"
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    raise SystemExit(0 if result["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
