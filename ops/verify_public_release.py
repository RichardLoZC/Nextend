#!/usr/bin/env python3
"""Read back the exact public release with the installed Pad's User-Agent."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

from release_bundle import verify_envelope, verify_bundle
from mac_bundle import temporary_test_app

ROOT = Path(__file__).resolve().parents[1]
BASE = 'https://linkbio.gz.cn/wp-content/uploads/apps/nextend/'

class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Release URL must not redirect')

def main():
    p = argparse.ArgumentParser(); p.add_argument('--bundle', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True); a = p.parse_args()
    expected, raw_expected = verify_bundle(a.bundle, ROOT/'ops/update-public-key.pem', 'dev.padbridge')
    opener = urllib.request.build_opener(NoRedirects())
    user_agent = 'Nextend/0.8.0'  # Existing Pad users must be able to discover this update.
    def fetch(path, maximum):
        request = urllib.request.Request(BASE+path, headers={'User-Agent': user_agent})
        with opener.open(request, timeout=30) as r:
            if r.status != 200: raise ValueError('HTTP status is not 200')
            data = r.read(maximum+1)
            if len(data) > maximum: raise ValueError('Download exceeded signed size')
            return data, dict(r.headers)
    raw, headers = fetch('updates/manifest.json', 65536)
    manifest = verify_envelope(raw, ROOT/'ops/update-public-key.pem', 'dev.padbridge')
    if raw != raw_expected or manifest != expected: raise ValueError('Live manifest differs from prepared release')
    cache = next((v for k, v in headers.items() if k.lower() == 'cache-control'), '')
    if 'max-age=0' not in cache and 'no-store' not in cache: raise ValueError('Manifest cache policy is stale')
    a.output.mkdir(parents=True, exist_ok=True)
    (a.output/'manifest.json').write_bytes(raw)
    report = {'verified_at': datetime.now(timezone.utc).isoformat(), 'baseURL': BASE,
              'manifest_signature_verified': True, 'manifest_sha256': hashlib.sha256(raw).hexdigest(),
              'manifest_cache_control': cache, 'user_agent': user_agent, 'downloads': {},
              'network_scope': 'Public HTTPS from current Mac network; not cellular'}
    for platform, item in manifest['platforms'].items():
        data, _ = fetch(item['path'], item['size'])
        if len(data) != item['size'] or hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('Public artifact does not match signed metadata')
        target = a.output/Path(item['path']).name; target.write_bytes(data)
        report['downloads'][platform] = dict(path=item['path'], build=item['build'], size=len(data), sha256=item['sha256'], verified=True)
        if platform == 'macos-arm64':
            with temporary_test_app('nextend-download-test-') as temporary:
                subprocess.run(['ditto', '-x', '-k', str(target), temporary], check=True)
                app = Path(temporary)/'Nextend.app'
                subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
                tested = subprocess.run([str(app/'Contents/MacOS/Nextend'), '--recovery-self-test'], check=True, capture_output=True, timeout=30)
                (a.output/'downloaded-mac-recovery.log').write_bytes(tested.stdout + tested.stderr)
                report['downloaded_mac_signature_and_recovery_test'] = True
    (a.output/'verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))

if __name__ == '__main__': main()
