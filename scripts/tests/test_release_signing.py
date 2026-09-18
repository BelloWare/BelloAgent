"""Exercise release signing policy without accessing a real private key."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
import release_signing as signing


class ReleaseSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pi-signing-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Bello Agent.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": signing.APP_ID}))
        self.entitlements = self.root / "release.entitlements"
        self.entitlements.write_bytes(plistlib.dumps(signing.APP_ENTITLEMENTS))

    def result(self, code=0, stdout=b"", stderr=b""):
        return subprocess.CompletedProcess([], code, stdout, stderr)

    def test_fresh_unsigned_bundle_uses_profile_free_clipboard_entitlements(self):
        with patch.object(signing.subprocess, "run", return_value=self.result(
                1, stderr=b"code object is not signed at all")):
            self.assertEqual(signing.validate_profile_free(self.app, entitlements=self.entitlements), {})
        self.assertEqual(plistlib.loads((ROOT / "apps/macos/PiApp/PiApp.entitlements").read_bytes()),
                         signing.APP_ENTITLEMENTS)

    def test_stale_profile_is_rejected_before_any_signature_access(self):
        for path in ("Contents/embedded.provisionprofile", "Contents/Helpers/Other.app/Contents/embedded.mobileprovision"):
            with self.subTest(path=path):
                profile = self.app / path
                profile.parent.mkdir(parents=True, exist_ok=True)
                profile.write_bytes(b"obsolete profile fixture")
                with patch.object(signing.subprocess, "run") as run, self.assertRaisesRegex(ValueError, "Stale embedded"):
                    signing.validate_profile_free(self.app, entitlements=self.entitlements)
                run.assert_not_called()
                profile.unlink()

    def test_stale_restricted_source_and_signed_entitlements_are_rejected(self):
        for key in signing.RESTRICTED_ENTITLEMENTS:
            with self.subTest(key=key):
                stale = {**signing.APP_ENTITLEMENTS, key: ["43TXHV3TM3.com.belloware.PiApp"]}
                self.entitlements.write_bytes(plistlib.dumps(stale))
                with patch.object(signing.subprocess, "run") as run, self.assertRaisesRegex(ValueError, "Stale profile-based"):
                    signing.validate_profile_free(self.app, entitlements=self.entitlements)
                run.assert_not_called()
                with patch.object(signing.subprocess, "run", return_value=self.result(stdout=plistlib.dumps(stale))), \
                        self.assertRaisesRegex(ValueError, "Stale profile-based"):
                    signing.validate_profile_free(self.app)

    def test_unreadable_or_invalid_existing_signature_does_not_become_an_unsigned_build(self):
        for result in (self.result(1, stderr=b"invalid signature"), self.result(stdout=b"malformed plist")):
            with self.subTest(result=result), patch.object(signing.subprocess, "run", return_value=result), \
                    self.assertRaises(ValueError):
                signing.validate_profile_free(self.app)

    def test_timestamp_retry_preserves_identity_runtime_and_entitlements(self):
        with patch.object(signing.subprocess, "run", side_effect=[self.result(1), self.result(1), self.result()]) as run, \
                patch.object(signing.time, "sleep") as sleep:
            signing.sign(self.app, entitlements=self.entitlements, identity=signing.DEFAULT_IDENTITY)
        self.assertEqual(run.call_count, 3)
        expected = ["codesign", "--force", "--sign", signing.DEFAULT_IDENTITY, "--timestamp", "--options", "runtime",
                    "--entitlements", str(self.entitlements), str(self.app)]
        self.assertEqual([call.args[0] for call in run.call_args_list], [expected] * 3)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [2, 2])

    def test_failed_signing_has_no_untimestamped_or_unsigned_fallback(self):
        with patch.object(signing.subprocess, "run", return_value=self.result(1)) as run, \
                patch.object(signing.time, "sleep"), self.assertRaisesRegex(RuntimeError, "secure timestamp"):
            signing.sign(self.app, runtime=False)
        self.assertEqual(run.call_count, 3)
        for call in run.call_args_list:
            self.assertIn("--timestamp", call.args[0])
            self.assertNotIn("--options", call.args[0])
            self.assertNotIn("--timestamp=none", call.args[0])
        with patch.object(signing.subprocess, "run") as run, self.assertRaises(ValueError):
            signing.sign(self.app, identity="-")
        run.assert_not_called()

    def test_release_signature_requires_developer_id_team_timestamp_runtime_and_identity(self):
        valid = ("Identifier=com.belloware.PiApp\nTeamIdentifier=43TXHV3TM3\n"
                 "Authority=Developer ID Application: Zhaofeng Wang (43TXHV3TM3)\n"
                 "Timestamp=Sep 15, 2026\nCodeDirectory v=20500 flags=0x10000(runtime)\n")
        signing.validate_signature_metadata(valid, identifier=signing.APP_ID)
        for wrong in (valid.replace("Timestamp=Sep 15, 2026", "Signed Time=Sep 15, 2026"),
                      valid.replace("Developer ID Application:", "Apple Development:"),
                      valid.replace("43TXHV3TM3", "OTHERTEAM"),
                      valid.replace("0x10000(runtime)", "0x0(none)"),
                      valid.replace("Identifier=com.belloware.PiApp", "Identifier=other.app")):
            with self.subTest(wrong=wrong), self.assertRaises(ValueError):
                signing.validate_signature_metadata(wrong, identifier=signing.APP_ID)

    def test_sign_app_orders_nested_targets_before_outer_app_without_profile(self):
        framework = self.app / "Contents/Frameworks/Sparkle.framework/Versions/B"
        targets = [framework / "XPCServices/Downloader.xpc", framework / "XPCServices/Installer.xpc",
                   framework / "Autoupdate", framework / "Updater.app", framework,
                   self.app / "Contents/Helpers/pi-native-host", self.app]
        for target in targets[:-1]:
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.suffix in (".app", ".xpc") or target == framework: target.mkdir(exist_ok=True)
            else: target.write_bytes(b"synthetic executable")
        commands = self.root / "commands"
        commands.mkdir()
        events = self.root / "events.jsonl"
        stub = commands / "codesign"
        stub.write_text("#!" + sys.executable + "\n" + '''import json, os, pathlib, plistlib, sys
args = sys.argv[1:]
events = pathlib.Path(os.environ["PI_FIXTURE_EVENTS"])
prior = [json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
with events.open("a") as output: output.write(json.dumps(args) + "\\n")
if "--display" in args:
    if "--entitlements" in args:
        signed = any("--sign" in item and item[-1] == args[-1] for item in prior)
        sys.stdout.buffer.write(plistlib.dumps({"com.apple.security.app-sandbox": False} if signed else {}))
    else:
        print("Identifier=com.belloware.PiApp\\nTeamIdentifier=43TXHV3TM3\\n"
              "Authority=Developer ID Application: Zhaofeng Wang (43TXHV3TM3)\\n"
              "Timestamp=Sep 15, 2026\\nCodeDirectory v=20500 flags=0x10000(runtime)", file=sys.stderr)
''')
        stub.chmod(0o755)
        env = {**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"], "PI_FIXTURE_EVENTS": str(events)}
        env.pop("PI_PROVISIONING_PROFILE", None)
        result = subprocess.run(["bash", str(SCRIPTS / "sign-app.sh"), str(self.app)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        operations = [json.loads(line) for line in events.read_text().splitlines()]
        signatures = [args for args in operations if "--sign" in args]
        self.assertEqual([Path(args[-1]).resolve() for args in signatures], [target.resolve() for target in targets])
        self.assertEqual(len(signatures), 7)
        for command in signatures: self.assertIn("--timestamp", command)
        for command in signatures[:4] + signatures[5:]: self.assertIn("runtime", command)
        self.assertNotIn("runtime", signatures[4])
        self.assertTrue("--entitlements" in signatures[-1])
        self.assertEqual(list(self.app.rglob("embedded.provisionprofile")), [])


if __name__ == "__main__":
    unittest.main()
