#!/usr/bin/env python3
"""Build from the canonical source; only transient Gradle outputs use native disk."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='nextend-android-build-') as directory:
    build = Path(directory)/'app'
    result = subprocess.run(['bash', str(ROOT/'android/gradlew'), ':app:assembleDebug', ':app:testDebugUnitTest',
                             '--console=plain', '--no-daemon', '--no-watch-fs', '-PnextendBuildDir='+str(build), *sys.argv[1:]], cwd=ROOT/'android')
    reports = ROOT/'outputs/test-results/android'
    if (build/'test-results').exists():
        reports.mkdir(parents=True, exist_ok=True)
        shutil.copytree(build/'test-results', reports, dirs_exist_ok=True)
    if result.returncode: raise SystemExit(result.returncode)
    target = ROOT/'outputs/Nextend.apk'; target.parent.mkdir(parents=True, exist_ok=True)
    staged = target.with_suffix('.apk.part')
    shutil.copyfile(build/'outputs/apk/debug/app-debug.apk', staged)
    os.replace(staged, target)
    print(target)
