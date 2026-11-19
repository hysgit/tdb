import collections
import json
from pathlib import Path

root = Path(__file__).resolve().parent
data = json.loads((root / 'ui-evidence-decoded.json').read_text(encoding='utf-8-sig'))
graph = data['normalized_result']['graph']
texts = collections.defaultdict(list)
colors = collections.Counter()
for node in graph['nodes']:
    values = node.get('attributes', {}).get('nibValues', {})
    source = node.get('evidence', [{}])[0].get('artifact_path', '')
    for key in ('UIText', 'UITitle', 'UIPlaceholder', 'UIHint', 'UIAccessibilityLabel', 'NS.string'):
        value = values.get(key)
        if isinstance(value, str):
            texts[source].append([key, value])
    if node.get('attributes', {}).get('class_name') == 'UIColor':
        if 'UIRed' in values:
            colors[tuple(round(values.get(k, 0), 3) for k in ('UIRed', 'UIGreen', 'UIBlue', 'UIAlpha'))] += 1
for source, rows in texts.items():
    print(source, json.dumps(rows, ensure_ascii=False))
print('COLORS', colors.most_common(14))
print('EDGES', json.dumps(graph['edges'][:4], ensure_ascii=False))
