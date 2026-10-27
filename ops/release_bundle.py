#!/usr/bin/env python3
"""Signed NAS release bundles. prepare/verify/commit; no credentials or network clients.

Native package identity and signing certificates must be verified by the caller
before prepare. commit verifies the pinned release key and every artifact again.
"""
import argparse, base64, contextlib, fcntl, hashlib, json, os, re, shutil, subprocess, tempfile, time, uuid
from pathlib import Path

MAX_MANIFEST = 65536
MAX_ARTIFACT = 200 * 1024 * 1024

def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b''): h.update(part)
    return h.hexdigest()

def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, timeout=30, **kwargs).stdout

def checked_manifest(value, application=None):
    if not isinstance(value, dict) or value.get('schema') != 1 or value.get('channel') not in ('stable', 'beta'):
        raise ValueError('Unsupported manifest schema/channel')
    app = value.get('application', '')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{2,160}', app) or application is not None and app != application:
        raise ValueError('Wrong application')
    if not isinstance(value.get('notes'), str) or len(value['notes']) > 4000: raise ValueError('Invalid notes')
    platforms = value.get('platforms')
    if not isinstance(platforms, dict) or not 1 <= len(platforms) <= 8: raise ValueError('Missing platforms')
    paths = set()
    for platform, item in platforms.items():
        if not re.fullmatch(r'[a-z][a-z0-9-]{1,40}', platform): raise ValueError('Invalid platform')
        if type(item.get('build')) is not int or not 1 <= item['build'] <= 2_100_000_000: raise ValueError('Invalid build')
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', item.get('version', '')): raise ValueError('Invalid version')
        path = item.get('path', '')
        if not re.fullmatch(r'updates/[A-Za-z0-9][A-Za-z0-9._-]{0,140}\.(apk|zip)', path) or '..' in path or path in paths: raise ValueError('Invalid/duplicate artifact path')
        paths.add(path)
        if type(item.get('size')) is not int or not 0 < item['size'] <= MAX_ARTIFACT: raise ValueError('Invalid artifact size')
        if not re.fullmatch(r'[a-f0-9]{64}', item.get('sha256', '')): raise ValueError('Invalid digest')
    return value

def verify_envelope(data, public_key, application=None):
    if len(data) > MAX_MANIFEST: raise ValueError('Manifest too large')
    envelope = json.loads(data)
    if envelope.get('algorithm') != 'RS256': raise ValueError('Unsupported algorithm')
    payload = base64.b64decode(envelope['payload'], validate=True)
    signature = base64.b64decode(envelope['signature'], validate=True)
    with tempfile.TemporaryDirectory(prefix='nas-release-verify-') as temp:
        sig = Path(temp) / 'signature'; sig.write_bytes(signature)
        run(['openssl', 'dgst', '-sha256', '-verify', str(public_key), '-signature', str(sig)], input=payload)
    return checked_manifest(json.loads(payload), application)

def verify_bundle(bundle, public_key, application=None):
    bundle = Path(bundle)
    raw = (bundle / 'updates/manifest.json').read_bytes()
    manifest = verify_envelope(raw, public_key, application)
    for item in manifest['platforms'].values():
        path = bundle / item['path']
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(bundle.resolve()): raise ValueError('Invalid artifact file')
        if path.stat().st_size != item['size'] or digest(path) != item['sha256']: raise ValueError('Artifact bytes differ from manifest')
    return manifest, raw

def prepare(spec_file, key, public_key, output):
    spec = json.loads(Path(spec_file).read_text()); output = Path(output)
    derived = run(['openssl', 'pkey', '-in', str(key), '-pubout', '-outform', 'DER'])
    pinned = run(['openssl', 'pkey', '-pubin', '-in', str(public_key), '-outform', 'DER'])
    if derived != pinned: raise ValueError('Release signing key does not match pinned client key')
    manifest = {k: spec[k] for k in ('application', 'channel', 'notes')}
    manifest.update(schema=1, published_at=int(time.time()), platforms={})
    for platform, source in spec['platforms'].items():
        file = Path(source['file']); item = {k: v for k, v in source.items() if k != 'file'}
        item.update(size=file.stat().st_size, sha256=digest(file)); manifest['platforms'][platform] = item
    checked_manifest(manifest)
    if output.exists():
        existing, _ = verify_bundle(output, public_key, manifest['application'])
        if any(existing[k] != manifest[k] for k in ('schema', 'application', 'channel', 'notes', 'platforms')): raise ValueError('Existing bundle differs: use a new build and output directory')
        return existing
    output.parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix='.release-', dir=output.parent))
    try:
        (temp / 'updates').mkdir()
        for platform, item in manifest['platforms'].items(): shutil.copyfile(spec['platforms'][platform]['file'], temp / item['path'])
        payload = json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
        signature = run(['openssl', 'dgst', '-sha256', '-sign', str(key)], input=payload)
        envelope = dict(algorithm='RS256', payload=base64.b64encode(payload).decode(), signature=base64.b64encode(signature).decode())
        (temp / 'updates/manifest.json').write_text(json.dumps(envelope, separators=(',', ':')))
        verify_bundle(temp, public_key, manifest['application'])
        os.rename(temp, output)
    finally:
        if temp.exists(): shutil.rmtree(temp)
    return manifest

def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try: os.fsync(descriptor)
    finally: os.close(descriptor)

def copy_atomic(source, target):
    target = Path(target); temp = target.with_name('.upload-' + uuid.uuid4().hex)
    try:
        with Path(source).open('rb') as src, temp.open('xb') as dst:
            shutil.copyfileobj(src, dst); dst.flush(); os.fsync(dst.fileno())
        os.chmod(temp, 0o644); os.replace(temp, target); sync_directory(target.parent)
    finally: temp.unlink(missing_ok=True)

def write_atomic(data, target):
    target = Path(target); temp = target.with_name('.upload-' + uuid.uuid4().hex)
    try:
        with temp.open('xb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.chmod(temp, 0o644); os.replace(temp, target); sync_directory(target.parent)
    finally: temp.unlink(missing_ok=True)

def commit(bundle, root, state, public_key, application):
    bundle, root, state = map(Path, (bundle, root, state))
    manifest, raw = verify_bundle(bundle, public_key, application)
    if root.is_symlink() or state.is_symlink(): raise ValueError('Release roots must not be symlinks')
    if state.resolve().is_relative_to(root.resolve()) or root.resolve().is_relative_to(state.resolve()): raise ValueError('Public and private release roots must be separate')
    state.mkdir(parents=True, exist_ok=True, mode=0o700); root.mkdir(parents=True, exist_ok=True)
    with (state / 'publish.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = root / 'updates/manifest.json'
        if current.exists():
            old_raw = current.read_bytes(); old = verify_envelope(old_raw, public_key, application)
            if old['channel'] != manifest['channel'] or set(old['platforms']) != set(manifest['platforms']): raise ValueError('Channel/platform changes require an explicit migration')
            for platform, item in manifest['platforms'].items():
                prior = old['platforms'][platform]
                if item['build'] < prior['build']: raise ValueError('Version rollback refused')
                if item['build'] == prior['build'] and item != prior: raise ValueError('A build must identify immutable metadata and bytes')
            if old['platforms'] == manifest['platforms'] and old_raw != raw: raise ValueError('Published release metadata is immutable')
            history = state / 'history'; history.mkdir(exist_ok=True)
            saved = history / (hashlib.sha256(old_raw).hexdigest() + '.json')
            if not saved.exists(): write_atomic(old_raw, saved)
        for item in manifest['platforms'].values():
            dest = root / item['path']; dest.parent.mkdir(parents=True, exist_ok=True)
            if dest.is_symlink() or not dest.resolve().is_relative_to(root.resolve()): raise ValueError('Invalid target')
            if dest.exists():
                if digest(dest) != item['sha256'] or dest.stat().st_size != item['size']: raise ValueError('Immutable artifact already differs')
            else:
                copy_atomic(bundle / item['path'], dest)
                if digest(dest) != item['sha256']: raise ValueError('Target hash mismatch')
        # The old manifest stays active until all immutable artifacts are verified.
        write_atomic(raw, current)
    return {'application': application, 'channel': manifest['channel'], 'builds': {k: v['build'] for k, v in manifest['platforms'].items()}, 'sha256': hashlib.sha256(raw).hexdigest()}

def main():
    p = argparse.ArgumentParser(description=__doc__); sub = p.add_subparsers(dest='command', required=True)
    a = sub.add_parser('prepare'); a.add_argument('--spec', required=True); a.add_argument('--key', required=True); a.add_argument('--public-key', required=True); a.add_argument('--output', required=True)
    a = sub.add_parser('verify'); a.add_argument('--bundle', required=True); a.add_argument('--public-key', required=True); a.add_argument('--application', required=True)
    a = sub.add_parser('commit'); a.add_argument('--bundle', required=True); a.add_argument('--root', required=True); a.add_argument('--state', required=True); a.add_argument('--public-key', required=True); a.add_argument('--application', required=True)
    args = vars(p.parse_args()); command = args.pop('command')
    if command == 'verify': value = verify_bundle(**args)[0]
    else: value = globals()[command](**args)
    print(json.dumps(value, ensure_ascii=False))
if __name__ == '__main__': main()
