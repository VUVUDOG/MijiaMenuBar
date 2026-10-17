import json
import io
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

import keyring

import probe
from auth import SessionStore, StaleSession


class AuthTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.runtime = Path(self.directory.name)
        self.credentials = {"user_id": "test", "service_token": "test-token", "ssecurity": "test-security"}
        self.keychain = {"session": json.dumps(self.credentials)}
        self.patches = [patch("auth.keyring.get_password", side_effect=lambda service, account: self.keychain.get(account)),
                        patch("auth.keyring.set_password", side_effect=lambda service, account, value: self.keychain.__setitem__(account, value)),
                        patch("auth.keyring.delete_password", side_effect=self.delete)]
        for replacement in self.patches:
            replacement.start()
            self.addCleanup(replacement.stop)

    def delete(self, service, account):
        if account not in self.keychain:
            raise keyring.errors.PasswordDeleteError("absent")
        del self.keychain[account]

    def store(self):
        return SessionStore(self.runtime, "test-service")

    def seed_cache(self):
        for name in ("report.json", "devices.json", "status.json", "login.png"):
            (self.runtime / name).write_text("cached data")

    def test_upgrade_preserves_existing_login(self):
        store = self.store()
        store.begin()
        self.assertEqual(store.credentials(), self.credentials)
        restarted = self.store()
        restarted.begin()
        self.assertEqual(restarted.credentials(), self.credentials)

    def test_cancelled_relogin_does_not_restore_old_session_on_restart(self):
        self.seed_cache()
        login = self.store()
        login.begin("login")
        self.assertFalse(self.keychain)
        for name in ("report.json", "devices.json", "status.json", "login.png"):
            self.assertFalse((self.runtime / name).exists())
        restarted = self.store()
        restarted.begin()
        self.assertIsNone(restarted.credentials())

    def test_logout_removes_credentials_and_cached_rooms(self):
        self.seed_cache()
        store = self.store()
        store.begin("logout")
        self.assertFalse(self.keychain)
        self.assertFalse((self.runtime / "report.json").exists())
        restarted = self.store()
        restarted.begin()
        self.assertIsNone(restarted.credentials())

    def test_superseded_worker_cannot_restore_credentials_report_or_qr(self):
        old = self.store()
        old.begin("login")
        new = self.store()
        new.begin("logout")
        for operation in (lambda: old.save_credentials(self.credentials),
                          lambda: old.write_json("report.json", {"devices": []}),
                          lambda: old.write_json("status.json", {"phase": "complete"}),
                          lambda: old.write_qr(b"old qr")):
            with self.assertRaises(StaleSession):
                operation()
        self.assertFalse(self.keychain)
        self.assertFalse((self.runtime / "report.json").exists())

    def test_new_login_persists_and_uses_a_new_keychain_account(self):
        store = self.store()
        store.begin("login")
        store.save_credentials(self.credentials)
        self.assertEqual(list(self.keychain), ["session." + store.generation])
        restarted = self.store()
        restarted.begin()
        self.assertEqual(restarted.credentials(), self.credentials)
        restarted.begin("logout")
        self.assertFalse(self.keychain)

    def test_native_revocation_survives_exit_before_cleanup_worker_starts(self):
        # Native app writes this marker synchronously, then starts --logout.
        marker = {"generation": "native-generation", "state": "logged_out", "retired_accounts": ["session"]}
        (self.runtime / "auth.json").write_text(json.dumps(marker))
        restarted = self.store()
        restarted.begin()
        self.assertIsNone(restarted.credentials())
        # A later cleanup worker can remove the retired credential without
        # choosing another generation or reviving the old login.
        restarted.begin("logout", expected="native-generation")
        self.assertFalse(self.keychain)
        self.assertEqual(restarted.generation, "native-generation")

    def test_refresh_while_logged_out_does_not_automatically_start_qr_login(self):
        self.store().begin("logout")
        with patch.object(probe, "RUNTIME", self.runtime), patch.dict("os.environ", {}, clear=True), patch("probe.XiaomiCloud") as cloud:
            cloud.return_value.credentials = None
            self.assertEqual(probe.main(["--refresh"]), 0)
            cloud.return_value.start_qr.assert_not_called()
        self.assertEqual(json.loads((self.runtime / "status.json").read_text())["phase"], "logged_out")

    def test_keychain_prompt_does_not_block_revocation_or_return_old_credentials(self):
        old = self.store()
        old.begin()
        entered = threading.Event()
        release = threading.Event()
        outcomes = []
        saved = self.keychain["session"]
        def blocked_read(service, account):
            entered.set()
            release.wait(3)
            return saved
        def read():
            try:
                outcomes.append(old.credentials())
            except StaleSession:
                outcomes.append("revoked")
        with patch("auth.keyring.get_password", side_effect=blocked_read):
            worker = threading.Thread(target=read, daemon=True)
            worker.start()
            self.assertTrue(entered.wait(1))
            try:
                self.store().begin("logout")
            finally:
                release.set()
                worker.join(3)
        self.assertEqual(outcomes, ["revoked"])
        self.assertFalse(self.keychain)

    def test_keychain_write_finishing_after_logout_cannot_restore_login(self):
        old = self.store()
        old.begin("login")
        def late_write(service, account, value):
            self.store().begin("logout")
            self.keychain[account] = value
        with patch("auth.keyring.set_password", side_effect=late_write), self.assertRaises(StaleSession):
            old.save_credentials(self.credentials)
        self.assertFalse(self.keychain)
        restarted = self.store()
        restarted.begin()
        self.assertIsNone(restarted.credentials())

    def test_memory_session_refreshes_do_not_read_keychain_or_write_tokens_to_disk(self):
        self.store().begin()
        (self.runtime / "report.json").write_text(json.dumps({"devices": [], "sensors": [], "accessories": [], "alarms": []}))
        output = io.StringIO()
        with patch.object(probe, "RUNTIME", self.runtime), patch.dict("os.environ", {}, clear=True), \
             patch("auth.keyring.get_password", side_effect=AssertionError("must not read keychain")), \
             patch("sys.stdout", output), patch("sys.stderr", io.StringIO()):
            for _ in range(3):
                with patch("sys.stdin", io.StringIO(json.dumps(self.credentials))):
                    self.assertEqual(probe.main(["--refresh", "--session-stdin", "--session-output"]), 0)
        replies = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(replies), 3)
        self.assertTrue(all(reply["session"] == self.credentials for reply in replies))
        for name in ("auth.json", "status.json", "report.json"):
            contents = (self.runtime / name).read_text()
            self.assertNotIn("test-token", contents)
            self.assertNotIn("test-security", contents)

    def test_memory_session_cannot_be_used_after_logout(self):
        store = self.store()
        store.begin()
        self.store().begin("logout")
        with self.assertRaises(StaleSession):
            store.memory_credentials(self.credentials)
        current = self.store()
        current.begin()
        with self.assertRaises(StaleSession):
            current.memory_credentials(self.credentials)

    def test_keychain_denial_is_identified_without_losing_cached_rooms(self):
        self.store().begin()
        (self.runtime / "report.json").write_text(json.dumps({"devices": [], "sensors": [], "accessories": [], "alarms": []}))
        with patch.object(probe, "RUNTIME", self.runtime), patch.dict("os.environ", {}, clear=True), \
             patch("auth.keyring.get_password", side_effect=keyring.errors.KeyringLocked("denied")), \
             patch("sys.stderr", io.StringIO()), patch("sys.stdout", io.StringIO()):
            self.assertEqual(probe.main(["--refresh", "--session-output"]), 1)
        status = json.loads((self.runtime / "status.json").read_text())
        self.assertEqual(status["reason"], "keychain_access")
        self.assertEqual(status["phase"], "error")
        self.assertTrue((self.runtime / "report.json").exists())

    def test_gui_worker_without_private_session_never_falls_back_to_keychain(self):
        self.store().begin()
        with patch.object(probe, "RUNTIME", self.runtime), patch.dict("os.environ", {}, clear=True), \
             patch("auth.keyring.get_password", side_effect=AssertionError("GUI worker must not read Keychain")), \
             patch("sys.stderr", io.StringIO()), patch("sys.stdout", io.StringIO()):
            self.assertEqual(probe.main(["--refresh", "--require-session", "--session-output"]), 1)
        status = json.loads((self.runtime / "status.json").read_text())
        self.assertEqual(status["reason"], "keychain_access")

    def test_gui_worker_logged_out_does_not_request_keychain_authorization(self):
        self.store().begin("logout")
        with patch.object(probe, "RUNTIME", self.runtime), patch.dict("os.environ", {}, clear=True), \
             patch("auth.keyring.get_password", side_effect=AssertionError("logged-out GUI must not read Keychain")), \
             patch("sys.stderr", io.StringIO()), patch("sys.stdout", io.StringIO()):
            self.assertEqual(probe.main(["--refresh", "--require-session", "--session-output"]), 0)
        self.assertEqual(json.loads((self.runtime / "status.json").read_text())["phase"], "logged_out")


if __name__ == "__main__":
    unittest.main()
