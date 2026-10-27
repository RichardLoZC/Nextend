"""Isolated regressions for the three publication-review findings.

Run from the Nextend repository: python3 tests/test_publish_release.py -v
No network, no NAS access, and no signing private keys are used. Native package
tools are stubbed; existing test_release_bundle.py covers real RSA verification.
"""
import contextlib
import hashlib
import io
import json
import os
import plistlib
import shlex
import subprocess
import sys
import tempfile
import types
import unittest
import zipfile
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "ops/release_bundle.py").exists())
sys.path.insert(0, str(ROOT / "ops"))
import publish_release as publish
import release_bundle as release


class CapturedRemoteCode(Exception):
    def __init__(self, code, data):
        self.code = code
        self.data = data


class PublishPackageRegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "work", prefix="publish-regression-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.out = self.base / "outputs"
        self.app = self.out / "Nextend.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.info = {"CFBundleIdentifier": "dev.padbridge.mac", "CFBundleVersion": "12",
                     "CFBundleShortVersionString": "0.8.0", "LSMinimumSystemVersion": "14.0"}
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        (self.app / "Contents/MacOS/Nextend").write_bytes(b"current code")
        (self.out / "Nextend.apk").write_bytes(b"unchanged APK")
        (self.out / "releases/android-11-mac-12").mkdir(parents=True)
        self.archive = self.out / "Nextend-0.8.0-macOS-arm64.zip"
        self.write_archive(b"current code")
        self.sdk = self.base / "sdk"
        (self.sdk / "build-tools/35.0.0").mkdir(parents=True)
        (self.base / "ops").mkdir()
        self.signer = "a" * 64
        (self.base / "ops/expected-android-signer.sha256").write_text(self.signer)
        # The pin primitive compares opaque public bytes; never load real keys.
        (self.base / "ops/update-public-key.pem").write_bytes(b"isolated public fixture A")
        self.notes = self.base / "notes.txt"
        self.notes.write_text("same release notes")
        self.state = self.base / "remote-state"
        self.config = self.base / "deploy.local.json"
        self.config.write_text(json.dumps({"sshHost": "never-contacted.invalid",
                                          "remoteRoot": str(self.base / "public"),
                                          "remoteState": str(self.state)}))
        self.prepare = Mock(side_effect=lambda path, *a: json.loads(path.read_text()))

    def write_archive(self, executable):
        with zipfile.ZipFile(self.archive, "w") as z:
            z.writestr("Nextend.app/Contents/Info.plist", plistlib.dumps(self.info))
            member = zipfile.ZipInfo("Nextend.app/Contents/MacOS/Nextend")
            member.external_attr = 0o100755 << 16
            z.writestr(member, executable)

    def fake_run(self, args, **kwargs):
        if str(args[0]).endswith("apksigner"):
            return f"Signer #1 certificate SHA-256 digest: {self.signer}\n".encode()
        if str(args[0]).endswith("aapt"):
            return b"package: name='dev.padbridge' versionCode='11' versionName='0.8.0'\nsdkVersion:'29'\n"
        if args[0] == "codesign":
            return b""
        if args[0] == "ssh":
            remote = shlex.split(args[-1])
            self.assertEqual(remote[:2], ["python3", "-c"])
            raise CapturedRemoteCode(remote[2], kwargs.get("input"))
        raise AssertionError(f"Unexpected external command: {args}")

    def invoke(self, publishing=False):
        argv = ["publish_release.py", "--notes-file", str(self.notes), "--config", str(self.config)]
        if publishing:
            argv.append("--publish")
        with patch.object(publish, "ROOT", self.base), patch.object(publish, "run", self.fake_run), \
                patch.object(publish, "prepare", self.prepare), \
                patch.dict(os.environ, {"ANDROID_HOME": str(self.sdk)}), \
                patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()):
            publish.main()

    def capture_pin(self):
        with self.assertRaises(CapturedRemoteCode) as caught:
            self.invoke(publishing=True)
        return caught.exception.code, caught.exception.data

    def execute_pin_locally(self, code, data):
        with patch.object(sys, "stdin", types.SimpleNamespace(buffer=io.BytesIO(data))):
            exec(code, {"__name__": "__main__"})

    def test_same_build_changed_executable_is_rejected(self):
        self.write_archive(b"old buggy code")
        with self.assertRaisesRegex(ValueError, "ZIP/app bytes differ"):
            self.invoke()
        self.prepare.assert_not_called()

    def test_external_zip_member_is_rejected(self):
        with zipfile.ZipFile(self.archive, 'a') as z:
            z.writestr('../outside', b'not part of the app')
        with self.assertRaisesRegex(ValueError, 'Unsafe ZIP member'):
            self.invoke()
        self.prepare.assert_not_called()

    def test_symlink_zip_member_is_rejected(self):
        with zipfile.ZipFile(self.archive, 'a') as z:
            member = zipfile.ZipInfo('Nextend.app/Contents/link')
            member.external_attr = 0o120777 << 16
            z.writestr(member, '/outside')
        with self.assertRaisesRegex(ValueError, 'Unsafe ZIP member'):
            self.invoke()
        self.prepare.assert_not_called()

    def test_same_build_added_app_file_is_rejected(self):
        (self.app / "Contents/new-resource").write_bytes(b"new resource")
        with self.assertRaisesRegex(ValueError, "ZIP/app contents differ"):
            self.invoke()
        self.prepare.assert_not_called()

    def test_identical_archive_is_accepted_for_idempotent_retry(self):
        self.invoke()
        self.prepare.assert_called_once()

    def test_pin_write_failure_never_leaves_partial_trusted_file(self):
        code, public = self.capture_pin()
        pin = self.state / "update-public-key.pem"
        with patch.object(os, "fsync", side_effect=OSError("simulated disk failure")):
            with self.assertRaises(OSError):
                self.execute_pin_locally(code, public)
        self.assertFalse(pin.exists())
        self.execute_pin_locally(code, public)
        self.assertEqual(pin.read_bytes(), public)
        self.assertEqual(pin.stat().st_mode & 0o777, 0o600)

    def test_pin_is_idempotent_and_refuses_different_key(self):
        code, public = self.capture_pin()
        self.execute_pin_locally(code, public)
        self.execute_pin_locally(code, public)
        with self.assertRaisesRegex(AssertionError, "NAS release key differs"):
            self.execute_pin_locally(code, b"isolated public fixture B")
        self.assertEqual((self.state / "update-public-key.pem").read_bytes(), public)

    def test_concurrent_first_pins_cannot_both_succeed_with_different_keys(self):
        code, public = self.capture_pin()
        # Run the captured code in local child processes, never through SSH.
        a = subprocess.Popen([sys.executable, "-c", code], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        b = subprocess.Popen([sys.executable, "-c", code], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        a.stdin.write(public); a.stdin.close(); a.stdin = None
        b.stdin.write(b"isolated public fixture B"); b.stdin.close(); b.stdin = None
        a.communicate(timeout=10); b.communicate(timeout=10)
        self.assertEqual(sorted([a.returncode, b.returncode]), [0, 1])
        self.assertIn((self.state / "update-public-key.pem").read_bytes(),
                      [public, b"isolated public fixture B"])


class CommitVerifiedSnapshotRegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "work", prefix="commit-snapshot-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.live = self.base / "public"
        self.state = self.base / "state"
        # Only byte-snapshot publication is under test. Real RSA behavior has
        # separate coverage in tests/test_release_bundle.py.
        self.verifier = patch.object(release, "verify_envelope",
                                     side_effect=lambda raw, *args: release.checked_manifest(json.loads(raw), "dev.review.test"))
        self.verifier.start()
        self.addCleanup(self.verifier.stop)

    def bundle(self, build):
        result = self.base / f"bundle-{build}"
        (result / "updates").mkdir(parents=True)
        artifact = f"updates/Test-{build}.apk"
        data = f"APK {build}".encode()
        (result / artifact).write_bytes(data)
        manifest = {"schema": 1, "application": "dev.review.test", "channel": "stable", "notes": "test",
                    "platforms": {"android": {"build": build, "version": f"1.0.{build}", "path": artifact,
                                              "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}}}
        (result / "updates/manifest.json").write_bytes(json.dumps(manifest).encode())
        return result

    def commit(self, bundle):
        return release.commit(bundle, self.live, self.state, self.base / "unused-public-key", "dev.review.test")

    def test_modified_source_manifest_cannot_replace_verified_snapshot(self):
        older, current, next_bundle = [self.bundle(n) for n in (1, 2, 3)]
        self.commit(current)
        expected = (next_bundle / "updates/manifest.json").read_bytes()
        old = (older / "updates/manifest.json").read_bytes()
        actual_verify = release.verify_bundle

        def mutate_after_verify(bundle, *args):
            result = actual_verify(bundle, *args)
            if Path(bundle) == next_bundle:
                (next_bundle / "updates/manifest.json").write_bytes(old)
            return result

        with patch.object(release, "verify_bundle", mutate_after_verify):
            result = self.commit(next_bundle)
        self.assertEqual(result["builds"]["android"], 3)
        self.assertEqual((self.live / "updates/manifest.json").read_bytes(), expected)
        live_manifest = actual_verify(self.live, self.base / "unused-public-key")[0]
        self.assertEqual(live_manifest["platforms"]["android"]["build"], 3)


if __name__ == "__main__":
    unittest.main()
