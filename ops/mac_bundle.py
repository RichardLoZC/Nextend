"""Normalize a generated app on native storage; never copy project sources.

File Provider adds history directories and cannot retain executable mode bits.
Only the generated product uses a temporary local copy for signing/validation.
"""
from pathlib import Path
from contextlib import contextmanager
import warnings
import os
import shutil
import subprocess
import tempfile

def bundle_files(app):
    app = Path(app)
    if app.is_symlink():
        raise ValueError('Refusing app symlink')
    result = {}
    for base, dirs, files in os.walk(app, followlinks=False):
        dirs[:] = [d for d in dirs if d != '.duckversions']
        for name in dirs + files:
            if (Path(base)/name).is_symlink():
                raise ValueError('Refusing symlink in app bundle')
        for name in files:
            p = Path(base)/name
            result[p.relative_to(app).as_posix()] = p
    return result

def copy_bundle(app, destination):
    destination = Path(destination)
    destination.mkdir(parents=True)
    for name, source in bundle_files(app).items():
        target = destination/name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)  # no FinderInfo, resource forks or File Provider attributes
        target.chmod(0o755 if name == 'Contents/MacOS/Nextend' else 0o644)
    return destination

@contextmanager
def temporary_test_app(prefix):
    """Keep test apps out of Spotlight and remove their Launch Services entry."""
    with tempfile.TemporaryDirectory(prefix=prefix, suffix='.noindex') as directory:
        folder = Path(directory)
        try:
            yield folder
        finally:
            app = folder/'Nextend.app'
            register = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')
            if app.exists() and register.exists():
                try:
                    result = subprocess.run([str(register), '-u', str(app.resolve())],
                                            capture_output=True, text=True, timeout=10)
                    if result.returncode:
                        warnings.warn('Could not unregister temporary Nextend app: ' + result.stderr.strip())
                except (OSError, subprocess.TimeoutExpired) as error:
                    warnings.warn('Could not unregister temporary Nextend app: ' + str(error))

def sign(app):
    app = Path(app)
    with tempfile.TemporaryDirectory(prefix='nextend-sign-') as directory:
        native = copy_bundle(app, Path(directory)/'Nextend.app')
        subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'dev.padbridge.mac', str(native)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(native)], check=True)
        # Transfer only signed product bytes back to the canonical output. The
        # release ZIP is verified from another normalized native copy.
        for name in ['Contents/MacOS/Nextend', 'Contents/_CodeSignature/CodeResources']:
            target = app/name; target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((native/name).read_bytes())

if __name__ == '__main__':
    import sys
    sign(sys.argv[1])
