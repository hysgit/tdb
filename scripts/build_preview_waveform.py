"""Build a reproducible preview envelope from the bundled audio, never random data."""
import argparse
import array
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--audio', default='assets/demo/Introduction.mp3')
    parser.add_argument('--output', default='dist/current-reference/demo-envelope.json')
    parser.add_argument('--ffmpeg', default='ffmpeg')
    args = parser.parse_args()
    source = Path(args.audio)
    pcm = subprocess.run([args.ffmpeg, '-v', 'error', '-i', str(source),
                          '-ac', '1', '-ar', '8000', '-f', 's16le', '-'],
                         check=True, stdout=subprocess.PIPE).stdout
    samples = array.array('h')
    samples.frombytes(pcm)
    if sys.byteorder != 'little':
        samples.byteswap()
    data = []
    for index in range(0, len(samples), 100):
        block = samples[index:index + 100]
        data.extend([min(block), max(block)])
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        'source': str(source), 'sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'sampleRate': 8000, 'samplesPerPixel': 100, 'length': len(data) // 2,
        'version': 1, 'flags': 0, 'data': data,
    }, separators=(',', ':')), encoding='utf-8')
    print(f'{output}: {len(data) // 2} min/max pairs from {len(samples)} actual PCM samples')


if __name__ == '__main__':
    main()
