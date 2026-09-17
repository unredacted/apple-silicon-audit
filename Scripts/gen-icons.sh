#!/bin/zsh
# Regenerate every platform asset and the portable logo from the same vector drawing.
set -euo pipefail
cd "$(dirname "$0")/.."
swift Tools/gen-icons/gen-icons.swift build/icons
python3 - <<'PY'
import json
import shutil
from pathlib import Path

source = Path('build/icons')
catalog = Path('Apps/Shared/Resources/Assets.xcassets')
count = 0
for manifest in catalog.rglob('Contents.json'):
    for image in json.loads(manifest.read_text()).get('images', []):
        name = image.get('filename')
        if name:
            shutil.copyfile(source / name, manifest.parent / name)
            count += 1
brand = Path('docs/brand')
brand.mkdir(parents=True, exist_ok=True)
for name in ['silicon-audit.svg', 'icon-1024-light.png', 'icon-1024-dark.png', 'icon-1024-macos.png']:
    shutil.copyfile(source / name, brand / name)
shutil.copyfile(source / 'silicon-audit.svg', 'site/logo.svg')
print(f'Installed {count} catalog images and the project logo.')
PY
