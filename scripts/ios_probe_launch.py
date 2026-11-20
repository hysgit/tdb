"""One bounded pre-test relaunch for Flutter's simulator VM-log discovery wait.

This is a probe-only recovery, not proof of the suspected log subscription race.
Flags match Flutter 3.50 device.dart getIOSLaunchArguments; service auth stays on.
"""
from __future__ import annotations

from pathlib import Path
import re
import threading
from typing import Callable


DEBUG_ARGUMENTS = (
    '--enable-dart-profiling',
    '--disable-vm-service-publication',
    '--enable-checked-mode',
    '--verify-entry-points',
)


class VmDiscoveryRecovery:
    def __init__(self):
        self._lock = threading.Lock()
        self._waiting_since: float | None = None
        self._activity = False
        self._attempted = False

    def observe(self, line: str, now: float) -> None:
        # Called from the stdout reader, before queueing. A backlog in the main
        # log consumer must not hide a newly-arrived Dart test/start marker.
        plain = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', line)
        progress = (
            any(marker in plain for marker in (
                'TDB_AUDIO_E2E_START', 'TDB_AUDIO_E2E_FORMAT', 'TDB_AUDIO_E2E_OK',
                'TDB_WIFI_E2E_URL=', 'TDB_WIFI_E2E_OK',
                'All tests passed!', 'Some tests failed.',
                'Connecting to service protocol:', 'Connecting to VM Service at',
                'Connected to the VM Service', 'DDS is listening at',
            )) or
            re.search(r'"type"\s*:\s*"(?:testStart|testDone|done)"', plain) is not None or
            re.search(r'\b\d+:\d+\s+\+\d+(?:\s+~\d+)?\s+-[1-9]\d*', plain) is not None or
            re.search(r'\b\d+:\d+\s+\+[1-9]\d*\b', plain) is not None or
            re.search(r'\b\d+:\d+\s+\+\d+:\s+(?!loading\b)\S', plain) is not None
        )
        with self._lock:
            if progress:
                self._activity = True
            if ('Waiting for VM Service port to be available' in plain and
                    self._waiting_since is None):
                self._waiting_since = now

    @property
    def activity(self) -> bool:
        with self._lock:
            return self._activity

    def claim(self, now: float) -> bool:
        with self._lock:
            if (self._attempted or self._activity or self._waiting_since is None or
                    now - self._waiting_since < 20):
                return False
            # Claim before any subprocess call; errors cannot reopen this latch.
            self._attempted = True
            return True


def relaunch_probe_once(recovery: VmDiscoveryRecovery, udid: str, bundle_id: str,
                        checked: Callable[[list[str], int], str], now: float) -> bool:
    if not recovery.claim(now):
        return False
    if (not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', udid) or
            bundle_id != 'com.hysgit.tdb'):
        raise ValueError('VM recovery is limited to this exact simulator and com.hysgit.tdb probe app.')
    installed = checked(['xcrun', 'simctl', 'get_app_container', udid, bundle_id, 'app'], 20).strip()
    if not installed or Path(installed).suffix != '.app':
        raise ValueError('The selected simulator did not report the installed probe app.')
    if recovery.activity:
        print('VM discovery recovery skipped: test/service activity arrived during the read-only check.', flush=True)
        return False
    print('VM discovery wait reached 20s; relaunching this installed probe once while preserving Flutter/logstream.', flush=True)
    checked(['xcrun', 'simctl', 'terminate', udid, bundle_id], 20)
    if recovery.activity:
        raise ValueError('Dart activity appeared during termination; refusing a further launch. Inspect probe diagnostics.')
    checked(['xcrun', 'simctl', 'launch', udid, bundle_id, *DEBUG_ARGUMENTS], 20)
    return True
