"""Smoke-test the packaged workers without reading or deleting real credentials."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent
for architecture, application in (("arm64", root / "dist/MijiaMenuBar.app"),
                                  ("x86_64", root / "dist/intel/MijiaMenuBar.app")):
    worker = application / "Contents/Resources/CloudWorker/CloudWorker"
    with tempfile.TemporaryDirectory(prefix="hitachi-package-test-") as temporary:
        runtime = Path(temporary)
        credentials = {"user_id": "package-test", "ssecurity": "package-test-security", "service_token": "package-test-token"}
        (runtime / "auth.json").write_text(json.dumps({"generation": "package-test", "state": "authenticated", "account": "session.mock"}))
        (runtime / "report.json").write_text(json.dumps({"devices": [], "sensors": [], "accessories": [], "alarms": []}))
        environment = {**os.environ, "HITACHI_RUNTIME_PATH": str(runtime), "HITACHI_AUTH_GENERATION": "package-test"}
        response = subprocess.run([str(worker), "--refresh", "--require-session", "--session-stdin", "--session-output"],
                                  env=environment, input=json.dumps(credentials), text=True, capture_output=True, check=True, timeout=15)
        assert json.loads(response.stdout)["session"] == credentials
        assert json.loads((runtime / "status.json").read_text())["phase"] == "complete"
        for name in ("auth.json", "report.json", "status.json"):
            assert "package-test-token" not in (runtime / name).read_text()
        missing = subprocess.run([str(worker), "--refresh", "--require-session", "--session-output"],
                                 env=environment, text=True, capture_output=True, timeout=15)
        assert missing.returncode == 1
        assert json.loads((runtime / "status.json").read_text())["reason"] == "keychain_access"
        assert not missing.stdout
        (runtime / "report.json").unlink()
        (runtime / "auth.json").write_text(json.dumps({"generation": "package-test", "state": "logged_out", "retired_accounts": []}))
        environment = {**os.environ, "HITACHI_RUNTIME_PATH": str(runtime), "HITACHI_AUTH_GENERATION": "package-test"}
        for arguments in (["--refresh", "--require-session"], ["--logout"]):
            subprocess.run([str(worker), *arguments], env=environment, check=True, timeout=15)
            assert json.loads((runtime / "status.json").read_text())["phase"] == "logged_out"
            assert not (runtime / "report.json").exists()
            assert not (runtime / "login.png").exists()
        print(architecture + ": packaged private session pipe, no Keychain fallback, refresh/logout passed")
