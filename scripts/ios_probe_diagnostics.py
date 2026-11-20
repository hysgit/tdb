"""Bounded, read-only diagnostics for one probe-owned iOS simulator/app."""
from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess


def sanitize_output(text: str) -> str:
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    text = re.sub(r'(?:https?|wss?)://[^\s\"\'<>]+', '[REDACTED_URL]', text)
    text = re.sub(r'(?i)(\b(?:token|secret|authorization|password|api[_-]?key|auth[_-]?code)\b\s*[:=]\s*)[^\s,;]+',
                  r'\1[REDACTED]', text)
    text = re.sub(r'\beyJ[A-Za-z0-9_.-]{25,}', '[REDACTED]', text)
    lines = []
    for line in text.splitlines(keepends=True):
        if ('TDB_AUDIO_E2E_' not in line and 'TDB_WIFI_E2E_' not in line and
                (re.search(r'(?:\]|^)\s*(?:export\s+)?[A-Z][A-Z0-9_]{2,}\s*=', line) or
                 re.search(r'(?i)\b(?:environment|env)\s*[:=]\s*\{', line))):
            line = '[BUILD_ENV_ASSIGNMENT omitted]\n'
        lines.append(line)
    return ''.join(lines)


def collect_diagnostics(udid: str, bundle_id: str, since: float, destination: Path) -> None:
    """Never enumerate environment variables, unrelated devices or app logs."""
    if not re.fullmatch(r'[0-9A-Fa-f-]{36}', udid) or not re.fullmatch(r'[A-Za-z0-9_.-]+', bundle_id):
        return
    destination.parent.mkdir(parents=True, exist_ok=True)

    def emit(label: str, value: str) -> None:
        message = sanitize_output(f'\nAUDIO/IOS PROBE DIAGNOSTIC {label}\n{value}\n')
        print(message, end='', flush=True)
        with destination.open('a', encoding='utf-8') as log:
            log.write(message)

    def run(command: list[str], limit: int | None = 80) -> str:
        try:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, encoding='utf-8', errors='replace', timeout=20)
            if limit is None:
                return result.stdout
            return '\n'.join(result.stdout.splitlines()[-limit:])[-18000:]
        except (OSError, subprocess.SubprocessError) as error:
            return f'Diagnostic command {command[0]} unavailable: {type(error).__name__}'

    inventory = run(['xcrun', 'simctl', 'list', 'devices', '--json'], None)
    try:
        payload = json.loads(inventory)
        selected = [dict(item, runtime=runtime) for runtime, devices in payload.get('devices', {}).items()
                    for item in devices if item.get('udid', '').lower() == udid.lower()]
        emit('selected simulator state', json.dumps(selected, ensure_ascii=False))
    except ValueError:
        emit('selected simulator state', 'Unable to parse simulator inventory.')
    emit('probe app container', run(['xcrun', 'simctl', 'get_app_container', udid, bundle_id, 'app'], 8))
    processes = run(['xcrun', 'simctl', 'spawn', udid, 'launchctl', 'list'], None)
    emit('matching app processes', '\n'.join(line for line in processes.splitlines()
        if bundle_id in line or 'Runner' in line) or 'No matching app process reported.')
    predicate = f'process == "Runner" OR (process == "SpringBoard" AND eventMessage CONTAINS "{bundle_id}")'
    emit('selected simulator recent app log', run([
        'xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--style', 'compact',
        '--last', '3m', '--predicate', predicate,
    ], 120))
    # A crash file is admitted only if it is new and contains this exact device ID.
    crash_root = Path.home() / 'Library/Logs/DiagnosticReports'
    for file in sorted(crash_root.glob('Runner*.ips'), key=lambda item: item.stat().st_mtime, reverse=True)[:8]:
        if file.stat().st_mtime < since - 5:
            continue
        text = file.read_text(encoding='utf-8', errors='replace')[:2_000_000]
        if udid.lower() not in text.lower():
            continue
        try:
            decoder = json.JSONDecoder()
            header, offset = decoder.raw_decode(text.lstrip())
            remaining = text.lstrip()[offset:].lstrip()
            report = decoder.raw_decode(remaining)[0] if remaining else header
            summary = {key: report.get(key) for key in ('procName', 'exception', 'termination')}
            triggered = next((thread for thread in report.get('threads', []) if thread.get('triggered')), {})
            summary['triggered_symbols'] = [frame.get('symbol') for frame in triggered.get('frames', [])[:16]]
            emit('matching recent Runner crash', json.dumps(summary, ensure_ascii=False))
        except (ValueError, TypeError, AttributeError):
            emit('matching recent Runner crash', 'Crash exists, but its structured summary could not be parsed.')
