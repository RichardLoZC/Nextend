#!/usr/bin/env python3
"""Compile the production NSD adapter with deterministic Android API fixtures.

Uses the same Kotlin 2.2.0 compiler already cached by the Android build. Does not
access the network, devices, installed apps or user pairing files.
"""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path.home() / '.gradle/caches/modules-2/files-2.1'
def jar(group, name, version=None):
    paths = sorted((CACHE/group/name).glob((version or '*')+'/*/*.jar'))
    if not paths:
        raise RuntimeError(f'Build Android first to cache {name}')
    return paths[-1]

def main():
    stdlib = jar('org.jetbrains.kotlin', 'kotlin-stdlib', '2.2.0')
    dependencies = [jar('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.2.0'), stdlib,
                    jar('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.2.0'),
                    jar('org.jetbrains.kotlin', 'kotlin-reflect', '1.6.10'),
                    jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm'),
                    jar('org.jetbrains', 'annotations')]
    java_home = os.environ.get('JAVA_HOME', '/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home')
    java = str(Path(java_home)/'bin/java')
    out = ROOT/'work/reconnect-fix/discovery-tests.jar'
    out.parent.mkdir(parents=True, exist_ok=True)
    sources = [ROOT/'android/app/src/main/java/dev/padbridge/PadConnectRequest.kt', *sorted((ROOT/'tests/discovery_fixtures').glob('*.kt'))]
    runtime = os.pathsep.join(map(str, [stdlib, dependencies[-1]]))
    subprocess.run([java, '-cp', os.pathsep.join(map(str, dependencies)), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
                    '-no-stdlib', '-no-reflect', '-classpath', runtime, '-d', str(out), *map(str, sources)], check=True, timeout=120)
    subprocess.run([java, '-cp', str(out)+os.pathsep+runtime, 'HarnessKt'], check=True, timeout=15)

if __name__ == '__main__': main()
