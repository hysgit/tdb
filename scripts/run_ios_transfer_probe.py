"""Probe real iOS simulator LAN HTTP, persisted bytes, and native audio decoding.

This uses an available iPhone simulator and the LAN URL printed by its app.
It does not prove a physical iPhone can receive uploads from another LAN device.
Only HTTP requests from this process bypass proxies; system settings are untouched.
"""
from __future__ import annotations

import argparse
from collections import deque
from html.parser import HTMLParser
import ipaddress
import json
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from ios_probe_diagnostics import collect_diagnostics, sanitize_output
from ios_probe_launch import VmDiscoveryRecovery, relaunch_probe_once


class ProbeError(RuntimeError):
    pass


class UploadPage(HTMLParser):
    def __init__(self):
        super().__init__()
        self.upload_path = None

    def handle_starttag(self, tag, attrs):
        if tag == 'body':
            self.upload_path = dict(attrs).get('data-upload-path')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def redact(text: str) -> str:
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    text = re.sub(r'(?:https?|wss?)://[^\s\"\'<>]+', '[REDACTED_URL]', text)
    return re.sub(r'/[A-Za-z0-9_-]{20,}/upload', '/[REDACTED]/upload', text)


def select_simulator(payload: dict, requested: str | None = None) -> dict:
    candidates = []
    for runtime, devices in payload.get('devices', {}).items():
        if '.iOS-' not in runtime:
            continue
        version = tuple(int(value) for value in re.findall(r'\d+', runtime))
        for device in devices:
            if device.get('isAvailable') and device.get('name', '').startswith('iPhone'):
                candidates.append({**device, 'runtime': runtime, 'runtime_version': version})
    if requested:
        candidates = [item for item in candidates if item['udid'] == requested]
    if not candidates:
        raise ProbeError('No matching available iPhone simulator exists on this host.')
    return max(candidates, key=lambda item: (item['state'] == 'Booted', item['runtime_version'], item['name']))


def checked(command: list[str], timeout: int) -> str:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding='utf-8', errors='replace', timeout=timeout)
    if result.returncode:
        raise ProbeError(f'Command {command[0]} failed: {redact(result.stdout[-3000:])}')
    return result.stdout


def simulator_inventory(*parts: str) -> dict:
    """Allow CoreSimulator cold startup; only this read-only query may retry."""
    command = ['xcrun', 'simctl', 'list', *parts, '--json']
    for attempt in (1, 2):
        print(f"CoreSimulator inventory [{' '.join(parts)}]: attempt {attempt}/2, timeout 120s.", flush=True)
        try:
            return json.loads(checked(command, 120))
        except subprocess.TimeoutExpired:
            if attempt == 2:
                raise
            print('CoreSimulator inventory timed out; retrying this read-only query once.', flush=True)
    raise AssertionError('Unreachable inventory retry state')


def xcode_build_in_progress(line: str, previous: bool) -> bool:
    if any(marker in line for marker in (
        'Xcode build done', 'Xcode build failed', '** BUILD FAILED **',
        'Failed to build iOS app', 'Error (Xcode)',
        'Could not build the application for the simulator',
    )):
        return False
    return True if 'Running Xcode build' in line else previous


def lan_root(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    try:
        address = ipaddress.ip_address(parsed.hostname or '')
        port = parsed.port
    except ValueError as error:
        raise ProbeError('The app published an invalid LAN URL.') from error
    if (parsed.scheme != 'http' or not isinstance(address, ipaddress.IPv4Address)
            or not address.is_private or address.is_loopback or address.is_link_local
            or address.is_unspecified or parsed.username or parsed.password
            or parsed.path != '/' or parsed.query or parsed.fragment
            or (port is not None and not 1 <= port <= 65535)):
        raise ProbeError('The app must publish its own non-loopback private LAN root URL.')
    return value


def upload_path(page: str) -> str:
    parser = UploadPage()
    parser.feed(page)
    value = parser.upload_path
    if not value or not re.fullmatch(r'/[A-Za-z0-9_-]+/upload', value):
        raise ProbeError('The app page did not publish a valid same-origin upload path.')
    return value


def host_upload(root: str, source: Path) -> int:
    # Do not edit proxy environment variables or substitute a loopback address.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(root, timeout=20) as response:
        if response.status != 200:
            raise ProbeError('The LAN page did not return HTTP 200.')
        page = response.read(2 * 1024 * 1024).decode('utf-8')
    route = upload_path(page)
    target = urllib.parse.urljoin(root, route) + '?' + urllib.parse.urlencode({'name': source.name})
    data = source.read_bytes()
    if not data:
        raise ProbeError('The bundled audio is empty.')
    request = urllib.request.Request(target, data=data, method='PUT',
                                    headers={'Content-Type': 'audio/mpeg'})
    with opener.open(request, timeout=90) as response:
        if response.status != 200:
            raise ProbeError('The LAN upload did not return HTTP 200.')
        response.read()
    # This request tells the app the host received the preceding PUT response.
    with opener.open(root, timeout=20) as response:
        if response.status != 200:
            raise ProbeError('The post-upload LAN confirmation did not return HTTP 200.')
        response.read()
    return len(data)


def stop_owned_process(process: subprocess.Popen) -> None:
    try:
        # start_new_session gives this invocation its own process group, including
        # build helpers that may outlive the Flutter parent's failure.
        os.killpg(process.pid, signal.SIGTERM)
        if process.poll() is None:
            process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=15)
    except ProcessLookupError:
        pass


def probe_bundle_id(repository: Path) -> str:
    project = (repository / 'ios/Runner.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
    values = set(re.findall(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([A-Za-z0-9_.-]+)\s*;', project))
    values = {value for value in values if not value.endswith('.RunnerTests')}
    if len(values) != 1:
        raise ProbeError('Cannot uniquely identify the probe app bundle from its Xcode project.')
    return values.pop()


def run_probe(args: argparse.Namespace) -> None:
    repository = Path(__file__).resolve().parents[1]
    bundle_id = probe_bundle_id(repository)
    source = repository / 'assets/demo/Introduction.mp3'
    if not source.is_file():
        raise ProbeError('The bundled Introduction.mp3 is missing.')
    inventory = simulator_inventory('devices', 'available')
    device = select_simulator(inventory, args.device)
    print(f"Using existing simulator: {device['name']} ({device['runtime']})", flush=True)
    if device['state'] != 'Booted':
        checked(['xcrun', 'simctl', 'boot', device['udid']], 60)
    checked(['xcrun', 'simctl', 'bootstatus', device['udid'], '-b'], 180)
    command = [args.flutter, 'test', '--verbose', '--no-pub', '--reporter', 'expanded',
               '--concurrency=1', '-d', device['udid'],
               'integration_test/transfer_waveform_test.dart']
    log_path = repository / args.log
    log_path.parent.mkdir(parents=True, exist_ok=True)
    process = subprocess.Popen(command, cwd=repository, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, encoding='utf-8',
                               errors='replace', bufsize=1, start_new_session=True)
    lines: queue.Queue[str | None] = queue.Queue(maxsize=5000)
    recovery = VmDiscoveryRecovery()

    def read_output():
        assert process.stdout is not None
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
    started = time.time()
    recent = deque(maxlen=100)
    uploaded = False
    verified = False
    ended = False
    building = False
    try:
        with log_path.open('w', encoding='utf-8') as log:
            while not ended:
                if time.monotonic() >= deadline:
                    raise ProbeError('Timed out waiting for the real iOS runtime probe.')
                if not building and time.monotonic() - last_output >= 180:
                    raise ProbeError('Flutter produced no output for 180 seconds; inspect this simulator diagnostic log.')
                if not building:
                    relaunch_probe_once(recovery, device['udid'], bundle_id, checked, time.monotonic())
                try:
                    line = lines.get(timeout=1)
                except queue.Empty:
                    if process.poll() is not None and not reader.is_alive():
                        break
                    continue
                if line is None:
                    ended = True
                    continue
                last_output = time.monotonic()
                plain = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', line)
                building = xcode_build_in_progress(plain, building)
                clean = sanitize_output(redact(plain))
                log.write(clean)
                log.flush()
                recent.append(clean)
                print(clean, end='', flush=True)
                marker = re.search(r'TDB_WIFI_E2E_URL=(http://[^\s]+)', plain)
                if marker and not uploaded:
                    root = lan_root(marker.group(1))
                    try:
                        count = host_upload(root, source)
                    except urllib.error.HTTPError as error:
                        raise ProbeError(f'The LAN HTTP request failed with status {error.code}.') from None
                    except urllib.error.URLError:
                        raise ProbeError('The host could not reach the exact LAN URL published by the app.') from None
                    uploaded = True
                    print(f'Host confirmed HTTP 200 and uploaded {count} original bytes.', flush=True)
                if 'TDB_WIFI_E2E_OK ' in line:
                    verified = True
            remaining = max(1, int(deadline - time.monotonic()))
            code = process.wait(timeout=remaining)
            if code != 0 or not uploaded or not verified:
                raise ProbeError(f'iOS runtime probe failed (flutter exit={code}, uploaded={uploaded}, verified={verified}).')
        print('Verified simulator Darwin LAN HTTP, original-byte persistence, TransferWake channel, and native nonzero waveform.', flush=True)
        print('Physical iPhone and a separate PC on the same Wi-Fi remain unverified.', flush=True)
    except (Exception, KeyboardInterrupt):
        print('Sanitized probe diagnostics:\n' + ''.join(recent), file=sys.stderr)
        try:
            collect_diagnostics(device['udid'], bundle_id, started, log_path)
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            print('Read-only diagnostics unavailable: ' + type(error).__name__, file=sys.stderr)
        raise
    finally:
        try:
            stop_owned_process(process)
        finally:
            # Flutter may be interrupted before the Dart test finally executes.
            # Stop only the probe app we launched on this exact simulator.
            subprocess.run(['xcrun', 'simctl', 'terminate', device['udid'],
                            bundle_id],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=15, check=False)
            if process.stdout is not None:
                process.stdout.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', help='Existing available iPhone simulator UDID; never creates a device.')
    parser.add_argument('--flutter', default='flutter')
    parser.add_argument('--timeout', type=int, default=1500, help='Flutter build/test timeout in seconds.')
    parser.add_argument('--log', default='build/ios-runtime-probe.log', help='Sanitized runtime log.')
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    previous_signal = signal.signal(signal.SIGTERM, interrupted)
    try:
        run_probe(args)
    except (ProbeError, OSError, subprocess.SubprocessError, ValueError) as error:
        print('Probe failed: ' + redact(str(error)), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('Probe interrupted; stopped its owned Flutter process.', file=sys.stderr)
        return 130
    finally:
        signal.signal(signal.SIGTERM, previous_signal)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
