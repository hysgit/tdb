"""Run real AVFoundation/MPEG audio export checks on a new, owned iOS simulator.

Uses only generated PCM; no user assets, mocked channels, permissions or uploads.
Build/launch logs are sanitized, and a failed run collects only its own app/device.
"""
from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path
import queue
import re
import signal
import subprocess
import sys
import threading
import time
import uuid

from ios_probe_diagnostics import collect_diagnostics, sanitize_output
from ios_probe_launch import VmDiscoveryRecovery, relaunch_probe_once
from run_ios_transfer_probe import ProbeError, checked, probe_bundle_id, select_simulator, simulator_inventory, stop_owned_process


def create_simulator() -> str:
    inventory = simulator_inventory('devices', 'available')
    template = select_simulator(inventory)
    kind = template.get('deviceTypeIdentifier')
    if not kind:
        types = simulator_inventory('devicetypes')
        kind = next((item['identifier'] for item in types.get('devicetypes', [])
                     if item.get('name') == template['name']), None)
    if not kind:
        raise ProbeError('Cannot identify the available iPhone device type; no existing device will be modified.')
    name = 'TdbAudioProbe-' + uuid.uuid4().hex[:8]
    output = checked(['xcrun', 'simctl', 'create', name, kind, template['runtime']], 30)
    identifiers = [line.strip() for line in output.splitlines()
                   if re.fullmatch(r'[0-9A-Fa-f-]{36}', line.strip())]
    if len(identifiers) != 1:
        raise ProbeError('simctl create did not return a valid owned device identifier.')
    return identifiers[0]


def run_probe(args: argparse.Namespace) -> None:
    if sys.platform != 'darwin':
        raise ProbeError('This probe requires macOS, Xcode and an available iOS runtime.')
    repository = Path(__file__).resolve().parents[1]
    log_path = (repository / args.log).resolve()
    if not log_path.is_relative_to(repository / 'build') or log_path.suffix != '.log':
        raise ProbeError('The diagnostic log must be a .log file under this checkout build directory.')
    log_path.parent.mkdir(parents=True, exist_ok=True)
    bundle_id = probe_bundle_id(repository)
    device = create_simulator()
    process = None
    started = time.time()
    recent: deque[str] = deque(maxlen=80)
    try:
        checked(['xcrun', 'simctl', 'boot', device], 60)
        checked(['xcrun', 'simctl', 'bootstatus', device, '-b'], 180)
        command = [args.flutter, 'test', '--verbose', '--no-pub', '--reporter', 'expanded',
                   '--concurrency=1', '-d', device, 'integration_test/audio_tools_test.dart']
        process = subprocess.Popen(command, cwd=repository, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, encoding='utf-8',
                                   errors='replace', bufsize=1, start_new_session=True)
        lines: queue.Queue[str | None] = queue.Queue(maxsize=5000)
        recovery = VmDiscoveryRecovery()

        def read_output() -> None:
            assert process is not None and process.stdout is not None
            try:
                for line in process.stdout:
                    recovery.observe(line, time.monotonic())
                    lines.put(line)
            finally:
                lines.put(None)

        reader = threading.Thread(target=read_output, daemon=True)
        reader.start()
        deadline = time.monotonic() + args.timeout
        last_output = time.monotonic()
        launch_deadline = None
        launched = False
        verified = False
        formats: set[str] = set()
        with log_path.open('w', encoding='utf-8') as log:
            while True:
                now = time.monotonic()
                if now >= deadline:
                    raise ProbeError('Audio probe exceeded its overall build/test deadline.')
                if now - last_output >= args.silence_timeout:
                    raise ProbeError('Flutter produced no output within the probe silence deadline.')
                if launch_deadline is not None and not launched and now >= launch_deadline:
                    raise ProbeError('Build completed but no Dart test start marker arrived within the launch deadline.')
                relaunch_probe_once(recovery, device, bundle_id, checked, now)
                try:
                    line = lines.get(timeout=1)
                except queue.Empty:
                    if process.poll() is not None and not reader.is_alive():
                        break
                    continue
                if line is None:
                    break
                last_output = time.monotonic()
                clean = sanitize_output(line)
                log.write(clean); log.flush()
                recent.append(clean)
                print(clean, end='', flush=True)
                if launch_deadline is None and ('Xcode build done' in line or 'Installing and launching' in line):
                    launch_deadline = time.monotonic() + args.launch_timeout
                if 'TDB_AUDIO_E2E_START ' in line:
                    launched = True
                match = re.search(r'TDB_AUDIO_E2E_FORMAT (m4a|mp3)\b', line)
                if match:
                    formats.add(match.group(1))
                if 'TDB_AUDIO_E2E_OK ' in line:
                    verified = True
            code = process.wait(timeout=max(1, int(deadline - time.monotonic())))
            if code != 0 or not launched or formats != {'m4a', 'mp3'} or not verified:
                raise ProbeError(f'Audio probe failed (flutter exit={code}, started={launched}, formats={sorted(formats)}, verified={verified}).')
        print('Verified real iOS retimed AAC/MP3 export, native decoding, unchanged input and safe temp release.', flush=True)
    except (Exception, KeyboardInterrupt):
        print('Sanitized audio probe diagnostics:\n' + ''.join(recent), file=sys.stderr)
        try:
            collect_diagnostics(device, bundle_id, started, log_path)
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            print('Read-only diagnostics unavailable: ' + type(error).__name__, file=sys.stderr)
        raise
    finally:
        try:
            if process is not None:
                try:
                    stop_owned_process(process)
                finally:
                    if process.stdout is not None:
                        process.stdout.close()
        finally:
            # Only the UDID returned by this invocation's simctl create is touched.
            for command in [
                ['xcrun', 'simctl', 'terminate', device, bundle_id],
                ['xcrun', 'simctl', 'shutdown', device],
                ['xcrun', 'simctl', 'delete', device],
            ]:
                try:
                    subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   timeout=20, check=False)
                except (OSError, subprocess.SubprocessError):
                    print('Owned simulator cleanup command did not complete: ' + command[2], file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', default='flutter')
    parser.add_argument('--timeout', type=int, default=1200)
    parser.add_argument('--launch-timeout', type=int, default=180)
    parser.add_argument('--silence-timeout', type=int, default=180)
    parser.add_argument('--log', default='build/ios-audio-probe.log')
    args = parser.parse_args()
    if min(args.timeout, args.launch_timeout, args.silence_timeout) <= 0:
        parser.error('Timeout values must be positive seconds.')

    def interrupted(signum, frame):
        raise KeyboardInterrupt

    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        run_probe(args)
    except (ProbeError, OSError, subprocess.SubprocessError, ValueError) as error:
        print('Audio probe failed: ' + sanitize_output(str(error)), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('Audio probe interrupted; cleaned only its owned process and simulator.', file=sys.stderr)
        return 130
    finally:
        signal.signal(signal.SIGTERM, previous)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
