#!/usr/bin/env python3
"""Check the tracked source manifest and selected archive before publication."""
import argparse
import re
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWED_ROOTS = {"Sources", "Tests", "Resources", "scripts", "docs", ".github", ".vscode", "BiQuadMonitor.xcodeproj"}
ALLOWED_FILES = {".gitignore", "Package.swift", "README.md", "LICENSE", "SECURITY.md", "CONTRIBUTING.md", "AGENTS.md", "build_app.py"}
FORBIDDEN = {".bin", ".dmg", ".zip", ".sqlite", ".db", ".log", ".p12", ".p8", ".pem", ".key"}


def verify_source(root: Path = ROOT) -> int:
    names = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    bad = []
    for name in filter(None, names):
        path = Path(name)
        if (path.parts[0] not in ALLOWED_ROOTS and name not in ALLOWED_FILES) or path.suffix.lower() in FORBIDDEN or any(p in {"recovery", "captures", "private", ".env", "dist", ".build"} for p in path.parts) or path.name.startswith(".env"):
            bad.append(name)
            continue
        target = root / path
        # A source symlink must not make the checker read outside the checkout.
        if any(parent.is_symlink() for parent in [target, *target.parents] if root in parent.parents) or root not in target.resolve().parents:
            bad.append(name)
            continue
        if not target.exists():
            # An unstaged source deletion is reviewed in the diff, not read here.
            continue
        if path.suffix.lower() not in {".png", ".jpg"}:
            # Detect obvious credential assignments; never print matched values.
            text = target.read_text(errors="replace")
            patterns = [r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", r"(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}"]
            if any(re.search(pattern, text) for pattern in patterns):
                bad.append(name)
    if bad:
        raise SystemExit("PUBLICATION_FAIL: prohibited files or credentials: " + ", ".join(sorted(set(bad))))
    print(f"PUBLICATION_PASS: {len(list(filter(None, names)))} tracked source files")
    return 0


def verify_archive(path: Path) -> None:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
    allowed = {"BiQuad Monitor.app/Contents/Info.plist", "BiQuad Monitor.app/Contents/MacOS/BiQuadMonitor", "BiQuad Monitor.app/Contents/_CodeSignature/CodeResources"}
    bad = [name for name in names if not name.endswith("/") and name not in allowed and not name.startswith("BiQuad Monitor.app/Contents/Resources/")]
    if bad or not allowed.issubset(names):
        raise SystemExit("ARCHIVE_FAIL: unexpected or missing bundle entries")
    print("ARCHIVE_PASS: app bundle only")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=ROOT)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    verify_source(args.project_root.resolve())
    if args.archive:
        verify_archive(args.archive)
