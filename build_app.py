#!/usr/bin/env python3
"""Build a source-stamped local preview, native or Universal. Never accesses signing keys."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
VERSION = "0.2.0"


def run(*args: str, capture: bool = False) -> str:
    result = subprocess.run(args, cwd=ROOT, check=True, text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["native", "universal"], default="universal")
    args = parser.parse_args()
    arch_args = ["--arch", "x86_64", "--arch", "arm64"] if args.arch == "universal" else []
    run("swift", "build", "-c", "release", *arch_args)
    binary_dir = Path(run("swift", "build", "-c", "release", *arch_args, "--show-bin-path", capture=True))
    app = ROOT / "dist" / "preview" / "BiQuad Monitor.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    (contents / "Resources").mkdir(exist_ok=True)
    executable = contents / "MacOS" / "BiQuadMonitor"
    shutil.copy2(binary_dir / "BiQuadMonitor", executable)
    commit = run("git", "rev-parse", "HEAD", capture=True)
    dirty = bool(run("git", "status", "--porcelain", "--untracked-files=no", capture=True))
    info = {
        "CFBundleName": "BiQuad Monitor", "CFBundleDisplayName": "BiQuad Monitor",
        "CFBundleIdentifier": "local.blackterminal.BiQuadMonitor",
        "CFBundleVersion": "6", "CFBundleShortVersionString": VERSION,
        "CFBundleExecutable": "BiQuadMonitor", "CFBundlePackageType": "APPL",
        "LSUIElement": True, "LSMinimumSystemVersion": "13.0",
        "LSMultipleInstancesProhibited": True, "NSHighResolutionCapable": True,
        "NSLocalNetworkUsageDescription": "Reads cellular signal metrics from your Cudy router on your local network.",
        # Numeric LAN addresses are restricted by RouterProtocol.baseURL and same-origin redirects.
        # ATS alone cannot express an RFC1918 subnet exception.
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True, "NSAllowsArbitraryLoads": True},
        "BiQuadSourceCommit": commit, "BiQuadSourceDirty": dirty,
        "BiQuadDistribution": "ad-hoc development preview; not notarized",
    }
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    run("/usr/bin/codesign", "--force", "--sign", "-", str(app))
    run("/usr/bin/codesign", "--verify", "--strict", str(app))
    architectures = run("/usr/bin/lipo", "-archs", str(executable), capture=True).split()
    if args.arch == "universal" and set(architectures) != {"x86_64", "arm64"}:
        raise SystemExit("Missing required Universal binary slice")
    metadata = {"version": VERSION, "commit": commit, "dirty": dirty, "architectures": architectures,
                "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(), "distribution": "ad-hoc preview"}
    (app.parent / "build.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(app)


if __name__ == "__main__":
    main()
