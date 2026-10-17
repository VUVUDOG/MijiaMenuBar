import plistlib
import argparse
import platform
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--worker", action="store_true", help="重新打包云端运行环境")
parser.add_argument("--arch", choices=["arm64", "x86_64"], default=platform.machine(), help="目标 Mac 架构，需要使用对应架构的 Python")
args = parser.parse_args()
if platform.machine() != args.arch:
    parser.error("云端运行环境必须使用对应架构的 Python 构建；当前 Python 为 " + platform.machine())
output = root / "dist" if args.arch == "arm64" else root / "dist" / "intel"
work = root / ".build" / args.arch
bundle = output / "MijiaMenuBar.app"
macos = bundle / "Contents" / "MacOS"
macos.mkdir(parents=True, exist_ok=True)
resources = bundle / "Contents" / "Resources"
worker = resources / "CloudWorker"
if args.worker or not (worker / "CloudWorker").exists():
    work.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--onedir", "--name", "CloudWorker",
                    "--target-arch", args.arch,
                    "--distpath", str(output / "worker"), "--workpath", str(work / "pyinstaller"),
                    "--specpath", str(work), "--hidden-import", "keyring.backends.macOS",
                    str(root / "probe.py")], cwd=root, check=True)
    resources.mkdir(parents=True, exist_ok=True)
    if worker.exists():
        shutil.rmtree(worker)
    shutil.copytree(output / "worker" / "CloudWorker", worker, symlinks=True)
info = {"CFBundleIdentifier": "local.hitachi.menubar", "CFBundleName": "米家菜单栏", "CFBundleDisplayName": "米家菜单栏",
        "CFBundleExecutable": "MijiaMenuBar", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.6.2", "CFBundleVersion": "21",
        "LSUIElement": True, "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "13.0"}
with (bundle / "Contents" / "Info.plist").open("wb") as output:
    plistlib.dump(info, output)
subprocess.run(["swiftc", str(root / "App.swift"), "-o", str(macos / "MijiaMenuBar"),
                "-target", args.arch + "-apple-macos13.0", "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "Security"], check=True)
# PyInstaller otherwise derives a fresh identifier from each executable UUID.
# Keep the helper identity predictable; ad-hoc code changes still need Keychain
# authorization after an update (this does not weaken the stored item's ACL).
subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", "local.hitachi.cloudworker", str(worker / "CloudWorker")], check=True)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(bundle)], check=True)
print(bundle)
