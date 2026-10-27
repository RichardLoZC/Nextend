"""The published product must not inherit cloud-provider history or mode bits."""
from pathlib import Path
import tempfile
import unittest
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'ops'))
from mac_bundle import copy_bundle, bundle_files

class NativeBundleTests(unittest.TestCase):
    def test_history_is_excluded_and_executable_mode_is_restored(self):
        with tempfile.TemporaryDirectory(prefix='nextend-bundle-test-') as temporary:
            root = Path(temporary); app = root/'cloud.app'; executable = app/'Contents/MacOS/Nextend'
            executable.parent.mkdir(parents=True); executable.write_bytes(b'current binary'); executable.chmod(0o600)
            history = executable.parent/'.duckversions'; history.mkdir(); (history/'previous').write_bytes(b'old binary')
            native = copy_bundle(app, root/'Nextend.app')
            self.assertEqual(set(bundle_files(native)), {'Contents/MacOS/Nextend'})
            self.assertEqual((native/'Contents/MacOS/Nextend').read_bytes(), b'current binary')
            self.assertEqual((native/'Contents/MacOS/Nextend').stat().st_mode & 0o777, 0o755)

    def test_symlink_is_rejected_before_copying_external_data(self):
        with tempfile.TemporaryDirectory(prefix='nextend-bundle-test-') as temporary:
            root = Path(temporary); app = root/'source.app'; app.mkdir()
            outside = root/'outside'; outside.write_bytes(b'do not include')
            (app/'link').symlink_to(outside)
            with self.assertRaisesRegex(ValueError, 'symlink'):
                copy_bundle(app, root/'destination.app')

if __name__ == '__main__': unittest.main()
