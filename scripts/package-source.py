#!/usr/bin/env python3
"""Package a reproducible source checkout, excluding build caches and secrets."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

root = Path(__file__).resolve().parent.parent
out = root / 'outputs' / 'Nextend-source.zip'
allowed_roots = ['macos', 'android', 'scripts', 'tests', 'docs', 'assets', 'skills']
excluded = {'build', '.gradle', '.kotlin', '__pycache__', '.DS_Store', 'local.properties'}
paths = [root / p for p in ['README.md', 'README.zh-CN.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', '.gitignore']]
for folder in allowed_roots:
    paths.extend(p for p in (root / folder).rglob('*') if p.is_file() and not any(x in excluded for x in p.relative_to(root).parts))
out.parent.mkdir(parents=True, exist_ok=True)
with ZipFile(out, 'w', ZIP_DEFLATED) as archive:
    for p in sorted(paths):
        archive.write(p, Path('Nextend') / p.relative_to(root))
print(out)
