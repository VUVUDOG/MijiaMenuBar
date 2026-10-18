import json
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
        "CFBundleShortVersionString": "0.7.3", "CFBundleVersion": "26",
        "LSUIElement": True, "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "13.0"}
with (bundle / "Contents" / "Info.plist").open("wb") as output:
    plistlib.dump(info, output)
# Compile the app, then generate the App Intents metadata (Shortcuts actions) the way
# Xcode does: the compiler records constant values, the metadata processor turns them
# into Contents/Resources/Metadata.appintents.
sources = [root / "App.swift", root / "Intents.swift", root / "main.swift"]
intents = work / "intents"
shutil.rmtree(intents, ignore_errors=True)
intents.mkdir(parents=True)
triple = args.arch + "-apple-macos13.0"
(intents / "protocols.json").write_text(json.dumps([
    "AppIntent", "EntityQuery", "AppEntity", "TransientEntity", "AppEnum", "AppShortcutProviding",
    "AppShortcutsProvider", "AnyResolverProviding", "AppIntentsPackage", "DynamicOptionsProvider"]))
constvalues = intents / "MijiaMenuBar.swiftconstvalues"
subprocess.run(["swiftc", *map(str, sources), "-o", str(macos / "MijiaMenuBar"), "-module-name", "MijiaMenuBar",
                "-wmo", "-emit-const-values-path", str(constvalues),
                "-Xfrontend", "-const-gather-protocols-file", "-Xfrontend", str(intents / "protocols.json"),
                "-target", triple, "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "Security",
                "-framework", "AppIntents"], check=True)
(intents / "sources.txt").write_text("\n".join(map(str, sources)) + "\n")
(intents / "constvalues.txt").write_text(str(constvalues) + "\n")
developer = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True, check=True).stdout.strip()
xcode_build = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, check=True).stdout.split()[-1]
sdk = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()
subprocess.run(["xcrun", "appintentsmetadataprocessor", "--output", str(resources),
                "--toolchain-dir", developer + "/Toolchains/XcodeDefault.xctoolchain", "--module-name", "MijiaMenuBar",
                "--sdk-root", sdk, "--xcode-version", xcode_build, "--platform-family", "macOS",
                "--deployment-target", "13.0", "--target-triple", triple,
                "--source-file-list", str(intents / "sources.txt"), "--swift-const-vals-list", str(intents / "constvalues.txt"),
                "--no-app-shortcuts-localization", "--force"], check=True)
# PyInstaller otherwise derives a fresh identifier from each executable UUID.
# Keep the helper identity predictable; ad-hoc code changes still need Keychain
# authorization after an update (this does not weaken the stored item's ACL).
subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", "local.hitachi.cloudworker", str(worker / "CloudWorker")], check=True)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(bundle)], check=True)
print(bundle)
