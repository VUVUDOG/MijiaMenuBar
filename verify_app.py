"""Run native login regression checks without touching a real login or HVAC."""
import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--arch", choices=["arm64", "x86_64"], default="arm64")
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="hitachi-native-test-") as temporary:
    temporary = Path(temporary)
    source = temporary / "main.swift"
    source.write_text((root / "App.swift").read_text().split("let app = NSApplication.shared\n")[0]
                      + (root / "verify_app.swift").read_text())
    executable = temporary / "NativeTests"
    worker = temporary / "MockWorker"
    worker.write_text("#!" + sys.executable + "\n" + '''import json, os, sys
from pathlib import Path
runtime = Path(os.environ["HITACHI_RUNTIME_PATH"])
auth = json.loads((runtime / "auth.json").read_text())
memory = "--session-stdin" in sys.argv
session = json.load(sys.stdin) if memory else {"user_id": "test", "ssecurity": "test-security", "service_token": "test-token"}
with (runtime / "requests.jsonl").open("a") as log:
    log.write(json.dumps({"memory": memory, "logout": "--logout" in sys.argv}) + "\\n")
if (runtime / "deny-keychain").exists():
    status = {"generation": auth["generation"], "phase": "error", "message": "钥匙串未授权", "reason": "keychain_access"}
    (runtime / "status.json").write_text(json.dumps(status))
    sys.exit(1)
if "--refresh" in sys.argv and (runtime / "slow-refresh").exists():
    import time
    time.sleep(5)
if "--field" in sys.argv or "--batch" in sys.argv:
    with (runtime / "controls.jsonl").open("a") as log:
        log.write(json.dumps(sys.argv[1:]) + "\\n")
    if (runtime / "fail-control").exists():
        status = {"generation": auth["generation"], "phase": "error", "message": "指令已发送，但暂未确认设备状态"}
        failed = (runtime / "fail-control").read_text().strip()
        if failed:
            status["failed"] = failed
        (runtime / "status.json").write_text(json.dumps(status))
        sys.exit(1)
if "--logout" in sys.argv:
    status = {"generation": auth["generation"], "phase": "logged_out", "message": "已退出登录"}
else:
    print(json.dumps({"generation": auth["generation"], "session": session}), flush=True)
    status = {"generation": auth["generation"], "phase": "complete", "message": "设备状态已更新"}
(runtime / "status.json").write_text(json.dumps(status))
''')
    worker.chmod(0o700)
    subprocess.run(["swiftc", str(source), str(root / "Intents.swift"), "-module-name", "NativeTests",
                    "-o", str(executable), "-target", args.arch + "-apple-macos13.0", "-framework", "AppIntents",
                    "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "Security"], check=True)
    fixture = root / "docs" / "fixtures" / "accessories.json"
    subprocess.run([str(executable), str(temporary), str(worker), str(fixture)], check=True)
