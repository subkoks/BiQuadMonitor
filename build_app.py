#!/usr/bin/env python3
"""Build a standalone local macOS app with the installed Swift toolchain."""
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parent
subprocess.run(["swift", "build", "-c", "release"], cwd=root, check=True)
binary_path = subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=root, text=True).strip()
app = root / "dist" / "BiQuad Monitor 0.1.4.app"
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(exist_ok=True)
shutil.copy2(Path(binary_path) / "BiQuadMonitor", contents / "MacOS" / "BiQuadMonitor")
info = {
    "CFBundleName": "BiQuad Monitor", "CFBundleDisplayName": "BiQuad Monitor",
    "CFBundleIdentifier": "local.blackterminal.BiQuadMonitor",
    "CFBundleVersion": "5", "CFBundleShortVersionString": "0.1.4",
    "CFBundleExecutable": "BiQuadMonitor", "CFBundlePackageType": "APPL",
    "LSUIElement": True, "LSMinimumSystemVersion": "13.0",
    "NSHighResolutionCapable": True,
    "NSLocalNetworkUsageDescription": "Reads cellular signal metrics from your Cudy router on your local network.",
    "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True, "NSAllowsArbitraryLoads": True},
}
with (contents / "Info.plist").open("wb") as file:
    plistlib.dump(info, file)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
print(app)
