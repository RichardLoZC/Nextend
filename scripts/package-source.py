#!/usr/bin/env python3
"""Package a reproducible source checkout, excluding build caches and secrets."""
from pathlib import Path
import os
import re
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

root = Path(__file__).resolve().parent.parent
out = root / 'outputs' / 'Nextend-source.zip'
allowed_roots = ['macos', 'android', 'scripts', 'tests', 'docs', 'assets', 'skills', 'ops']
excluded = {'build', '.gradle', '.kotlin', '__pycache__', '.DS_Store', 'local.properties', '.duckversions'}
excluded_files = {'scripts/build-dockpin.sh', 'scripts/test-dockpin.sh'}
secret_suffixes = {'.key', '.pem', '.p12', '.jks', '.keystore', '.pyc', '.log'}
public_keys = {'ops/update-public-key.pem'}
paths = [root / p for p in ['AGENTS.md', 'README.md', 'README.zh-CN.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', '.gitignore']]
for folder in allowed_roots:
    for base, directories, files in os.walk(root / folder, followlinks=False):
        directories[:] = sorted(d for d in directories if d not in excluded and not (Path(base) / d).is_symlink())
        for name in files:
            p = Path(base) / name
            rel = p.relative_to(root).as_posix()
            if (name in excluded or name.startswith('.env') or rel in excluded_files
                    or p.suffix in secret_suffixes and rel not in public_keys):
                continue
            if p.is_symlink():
                raise SystemExit(f'Refusing symlink in source archive: {rel}')
            paths.append(p)
out.parent.mkdir(parents=True, exist_ok=True)
staging = out.with_suffix('.zip.part')
try:
    with ZipFile(staging, 'w', ZIP_DEFLATED) as archive:
        for p in sorted(set(paths)):
            data = p.read_bytes()
            if re.search(rb'-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----', data):
                raise SystemExit(f'Refusing private key in source archive: {p.relative_to(root)}')
            info = ZipInfo.from_file(p, Path('Nextend') / p.relative_to(root))
            archive.writestr(info, data, compress_type=ZIP_DEFLATED)
    staging.replace(out)
finally:
    staging.unlink(missing_ok=True)
print(out)
