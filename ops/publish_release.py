#!/usr/bin/env python3
"""Prepare Nextend releases; --publish writes the verified bundle to the configured NAS."""
import argparse, hashlib, json, os, plistlib, re, shlex, stat, subprocess, sys, tempfile, uuid, zipfile
from pathlib import Path
from release_bundle import prepare, verify_bundle
from mac_bundle import copy_bundle, bundle_files
ROOT = Path(__file__).resolve().parents[1]

def run(args, **kwargs):
    try: return subprocess.run(args, check=True, capture_output=True, timeout=120, **kwargs).stdout
    except subprocess.CalledProcessError as error:
        raise RuntimeError(error.stderr.decode(errors='replace')[-2000:].strip() or 'Release command failed') from None

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--notes-file', type=Path, required=True); p.add_argument('--config', type=Path, default=ROOT/'work/releases/deploy.local.json')
    p.add_argument('--key', type=Path, default=Path.home()/'.local/share/nextend/signing/updates.pem'); p.add_argument('--publish', action='store_true')
    p.add_argument('--mac-app', type=Path, default=ROOT/'outputs/Nextend.app', help='Reuse an existing unchanged Mac bundle when only Android is updated')
    a = p.parse_args(); apk = ROOT/'outputs/Nextend.apk'; mac = a.mac_app
    env = os.environ.copy(); env.setdefault('JAVA_HOME', '/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home')
    sdk = Path(os.environ.get('ANDROID_HOME', str(Path.home()/'Library/Android/sdk')))
    build_tools = sorted((sdk/'build-tools').iterdir(), key=lambda v: tuple(map(int, re.findall(r'\d+', v.name))))[-1]
    certs = run([str(build_tools/'apksigner'), 'verify', '--print-certs', str(apk)], env=env).decode()
    found = re.findall(r'Signer #[0-9]+ certificate SHA-256 digest: ([0-9a-f]{64})', certs)
    if found != [(ROOT/'ops/expected-android-signer.sha256').read_text().strip()]: raise ValueError('Android installation signing identity changed')
    badging = run([str(build_tools/'aapt'), 'dump', 'badging', str(apk)]).decode()
    package, code, version = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging).groups()
    if package != 'dev.padbridge': raise ValueError('Wrong Android application')
    min_sdk = int(re.search(r"sdkVersion:'(\d+)'", badging)[1])
    if apk.stat().st_size > 64*1024*1024: raise ValueError('APK exceeds client bound')
    info = plistlib.loads((mac/'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != 'dev.padbridge.mac': raise ValueError('Wrong macOS application')
    mac_build = int(info['CFBundleVersion']); mac_version = info['CFBundleShortVersionString']
    out = ROOT/'outputs/releases'/f'android-{code}-mac-{mac_build}'
    zip_path = ROOT/'outputs'/f'Nextend-{mac_version}-macOS-arm64.zip'
    # Reuse the already prepared archive, so an identical retry is idempotent.
    with tempfile.TemporaryDirectory(prefix='nextend-package-') as directory:
        native = copy_bundle(mac, Path(directory)/'Nextend.app')
        run(['codesign', '--verify', '--deep', '--strict', str(native)])
        if not zip_path.exists(): run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--noqtn', '--keepParent', str(native), str(zip_path)])
    with zipfile.ZipFile(zip_path) as z:
        for member in z.infolist():
            parts = member.filename.rstrip('/').split('/')
            mode = member.external_attr >> 16
            if (parts[0] != 'Nextend.app' or any(p in ('', '.', '..') for p in parts)
                    or '\\' in member.filename or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
                raise ValueError('Unsafe ZIP member')
            if member.filename == 'Nextend.app/Contents/MacOS/Nextend' and mode & 0o111 != 0o111:
                raise ValueError('ZIP main executable is not executable')
        zipped = plistlib.loads(z.read('Nextend.app/Contents/Info.plist'))
        if zipped != info: raise ValueError('ZIP does not match the current app')
        files = bundle_files(mac)
        members = [m for m in z.infolist() if m.filename.startswith('Nextend.app/') and not m.is_dir()]
        if len(members) != len(files) or {m.filename.removeprefix('Nextend.app/') for m in members} != set(files):
            raise ValueError('ZIP/app contents differ: rebuild with a new build number')
        for member in members:
            path = files[member.filename.removeprefix('Nextend.app/')]
            if path.is_symlink() or z.read(member) != path.read_bytes():
                raise ValueError('ZIP/app bytes differ: rebuild with a new build number')
    spec = dict(application='dev.padbridge', channel='stable', notes=a.notes_file.read_text().strip(), platforms={
        'android': dict(file=str(apk), build=int(code), version=version, path=f'updates/Nextend-Android-{code}.apk', minSdk=min_sdk, packageName=package, signerSha256=found[0]),
        'macos-arm64': dict(file=str(zip_path), build=mac_build, version=mac_version, path=f'updates/Nextend-Mac-{mac_build}.zip', bundleIdentifier='dev.padbridge.mac', minimumSystemVersion=info['LSMinimumSystemVersion'])})
    spec_file = ROOT/'work/releases/spec.json'; spec_file.parent.mkdir(parents=True, exist_ok=True); spec_file.write_text(json.dumps(spec, ensure_ascii=False))
    manifest = prepare(spec_file, a.key, ROOT/'ops/update-public-key.pem', out)
    if not a.publish: print(json.dumps({'prepared':str(out),'platforms':list(manifest['platforms'])})); return
    config = json.loads(a.config.read_text()); host = config['sshHost']; remote = config['remoteRoot']; state = config['remoteState']
    if not re.fullmatch(r'[A-Za-z0-9_.@-]+', host) or host.startswith('-'): raise ValueError('Invalid SSH host')
    for path in (remote, state):
        if not path.startswith('/') or '..' in path.split('/'): raise ValueError('Invalid remote path')
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15', host]
    def execute(code, data=None): return run(ssh + ['python3 -c '+shlex.quote(code)], input=data)
    stage = state+'/staging/'+uuid.uuid4().hex
    def upload(path, data):
        execute('from pathlib import Path\nimport sys,os\np=Path('+repr(path)+')\np.parent.mkdir(parents=True,exist_ok=True,mode=0o700)\nwith p.open("xb") as f:\n f.write(sys.stdin.buffer.read());f.flush();os.fsync(f.fileno())', data)
    # Pin the already established server key. Never overwrite a different key.
    public = (ROOT/'ops/update-public-key.pem').read_bytes()
    execute('from pathlib import Path\nimport sys,fcntl,tempfile,os\np=Path('+repr(state+'/update-public-key.pem')+')\np.parent.mkdir(parents=True,exist_ok=True,mode=0o700)\nb=sys.stdin.buffer.read()\nwith (p.parent/"publish.lock").open("a") as lock:\n fcntl.flock(lock,fcntl.LOCK_EX)\n if p.exists():\n  assert p.read_bytes()==b,"NAS release key differs"\n else:\n  with tempfile.NamedTemporaryFile(dir=p.parent,delete=False) as f:\n   f.write(b);f.flush();os.fsync(f.fileno());name=f.name\n  os.chmod(name,0o600);os.replace(name,p)', public)
    try:
        for file in out.rglob('*'):
            if file.is_file(): upload(stage+'/'+file.relative_to(out).as_posix(), file.read_bytes())
        upload(stage+'/release_bundle.py', (ROOT/'ops/release_bundle.py').read_bytes())
        command = ['python3', stage+'/release_bundle.py', 'commit', '--bundle', stage, '--root', remote, '--state', state,
                   '--public-key', state+'/update-public-key.pem', '--application', 'dev.padbridge']
        result = run(ssh+[shlex.join(command)]); print(result.decode().strip())
    finally:
        execute('import shutil\nshutil.rmtree('+repr(stage)+',ignore_errors=True)')
if __name__ == '__main__': main()
