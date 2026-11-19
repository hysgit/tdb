import hashlib
import json
from pathlib import Path
import shutil

root = Path(__file__).resolve().parent
app = root / 'ipa/Payload/听读宝.app'
first = json.loads((root / 'ui-evidence-decoded.json').read_text(encoding='utf-8-sig'))
decoded = {d['relative_path'] for d in first['normalized_result']['documents']}
dest = root / 'ui_remainder.app'
dest.mkdir(exist_ok=True)
shutil.copy2(app / 'Info.plist', dest / 'Info.plist')
manifest = []
for source in app.rglob('*.nib'):
    relative = source.relative_to(app).as_posix()
    if relative in decoded:
        continue
    target = dest / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    manifest.append({'source': str(source), 'relative_path': relative,
                     'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
(root / 'ui-remainder-provenance.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
print(f'Copied {len(manifest)} remaining nib files without modification.')
