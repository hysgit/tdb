"""Read-only static observations from the supplied IPA and extracted resources."""
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import plistlib
import sqlite3
import struct

ROOT = Path(__file__).resolve().parent
APP = ROOT / 'ipa/Payload/听读宝.app'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))

info = plistlib.loads((APP / 'Info.plist').read_bytes())
binary = (APP / info['CFBundleExecutable']).read_bytes()
assert struct.unpack_from('<I', binary)[0] == 0xFEEDFACF
count = struct.unpack_from('<I', binary, 16)[0]
offset = 32
encryption = []
dependencies = []
for _ in range(count):
    command, size = struct.unpack_from('<II', binary, offset)
    if command in (0x21, 0x2C):
        cryptoff, cryptsize, cryptid = struct.unpack_from('<III', binary, offset + 8)
        encryption.append({'load_command': hex(command), 'load_command_file_offset': offset,
                           'cryptoff': cryptoff, 'cryptsize': cryptsize, 'cryptid': cryptid})
    if command in (0xC, 0x18, 0x80000018, 0x1F, 0x8000001F, 0x80000023):
        name_offset = struct.unpack_from('<I', binary, offset + 8)[0]
        name = binary[offset + name_offset:offset + size].split(b'\0', 1)[0].decode('utf-8', errors='replace')
        dependencies.append(name)
    offset += size

ui = {}
evidence = []
colors = Counter()
for filename in ('ui-evidence-decoded.json', 'ui-evidence-remainder.json'):
    document = read_json(ROOT / filename)
    evidence.append({'path': filename, 'evidence_id': document['evidence_id'], 'sha256': digest(ROOT / filename)})
    for node in document['normalized_result']['graph']['nodes']:
        refs = node.get('evidence', [])
        if not refs:
            continue
        source = refs[0].get('artifact_path')
        if not source:
            continue
        bucket = ui.setdefault(source, {'sha256': refs[0].get('artifact_sha256'), 'texts': [], 'actions': [], 'outlets': [], 'custom_classes': []})
        attributes = node.get('attributes', {})
        values = attributes.get('nibValues', {})
        for key in ('UIText', 'UITitle', 'UIPlaceholder'):
            text = values.get(key)
            if isinstance(text, str) and text and text != 'Label':
                bucket['texts'].append({'field': key, 'value': text})
        if node['kind'] in ('action', 'outlet'):
            bucket[node['kind'] + 's'].append(node['name'])
        custom_class = values.get('UIClassName')
        if custom_class:
            bucket['custom_classes'].append(custom_class)
        if attributes.get('class_name') == 'UIColor' and 'UIRed' in values:
            components = tuple(round(values.get(k, 0), 4) for k in ('UIRed', 'UIGreen', 'UIBlue', 'UIAlpha'))
            colors[components] += 1
for bucket in ui.values():
    for key in ('actions', 'outlets', 'custom_classes'):
        bucket[key] = sorted(set(bucket[key]))

with sqlite3.connect('file:' + str(APP / 'settings.sqlite') + '?mode=ro', uri=True) as database:
    schema = [{'name': name, 'sql': sql} for name, sql in database.execute("SELECT name,sql FROM sqlite_master WHERE type='table'")]
    settings_count = database.execute('SELECT count(*) FROM Settings').fetchone()[0]

subtitles = read_json(APP / 'Introduction.txt')
result = {
    'analysis_date': '2026-11-19',
    'source_ipa': {'path': str(ROOT.parent / 'tingdubao-1133575767.ipa'), 'sha256': digest(ROOT.parent / 'tingdubao-1133575767.ipa')},
    'identity': {key: info.get(key) for key in ('CFBundleDisplayName', 'CFBundleShortVersionString', 'CFBundleVersion', 'CFBundleIdentifier', 'CFBundleExecutable')},
    'resource_sha256': {name: digest(APP / name) for name in ('Info.plist', '听读宝', 'ASPlayerDetailSettingsViewConfig.json', 'Introduction.txt', 'settings.sqlite')},
    'native': {'format': 'Mach-O 64-bit ARM64', 'encryption_commands': encryption, 'dylib_load_commands': dependencies},
    'declared_integration': {'background_modes': info.get('UIBackgroundModes'), 'file_sharing': info.get('UIFileSharingEnabled'),
                             'url_scheme_names': [x.get('CFBundleURLName', '') for x in info.get('CFBundleURLTypes', [])],
                             'shortcut_titles': [x.get('UIApplicationShortcutItemTitle') for x in info.get('UIApplicationShortcutItems', [])]},
    'ui_evidence': evidence,
    'ui_documents_count': len(ui),
    'ui_documents': ui,
    'archived_colors': [{'rgba': color, 'count': count} for color, count in colors.most_common()],
    'player_settings': read_json(APP / 'ASPlayerDetailSettingsViewConfig.json'),
    'packaged_subtitle_example': {'path': 'Introduction.txt', 'format': 'JSON array', 'count': len(subtitles),
                                 'keys': sorted(subtitles[0]), 'first_start_seconds': subtitles[0]['ATime'],
                                 'last_end_seconds': subtitles[-1]['BTime']},
    'settings_database': {'path': 'settings.sqlite', 'schema': schema, 'settings_row_count': settings_count},
    'model_bundle_names': sorted(x.name for x in APP.glob('*.mlmodelc')),
    'limitations': [
        'Static package and recognized archive fields only; original application has not been executed.',
        'Mach-O cryptid=1 declares encrypted code. This is not recovered original source or proven native handler behavior.',
        'Nib text/action/outlet/class presence does not prove runtime visibility, successful operations, complete geometry, or implementation.',
        'The remainder nib files were byte-identical copies preserving relative paths; original provenance is ui-remainder-provenance.json.',
        'CoreML bundle names establish packaged assets, not the algorithms, call flows, input contracts, availability, or scoring accuracy.',
        'Cloud, purchases, speech services and sharing have no runtime/network verification.'
    ]
}
(ROOT / 'feature_inventory.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('UI documents:', len(ui))
print('Encryption:', encryption)
print('Dependencies:', json.dumps(dependencies, ensure_ascii=False))
for path, bucket in ui.items():
    if 'Main.storyboardc' in path or 'Dictation' in path or 'Favor' in path:
        print(path, json.dumps({key: value for key, value in bucket.items() if key != 'sha256' and value}, ensure_ascii=False))
