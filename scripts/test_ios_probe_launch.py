import concurrent.futures
import contextlib
import io
import unittest
from unittest.mock import Mock

from ios_probe_launch import DEBUG_ARGUMENTS, VmDiscoveryRecovery, relaunch_probe_once


UDID = '12345678-1234-1234-1234-123456789ABC'
BUNDLE = 'com.hysgit.tdb'
WAIT = 'Waiting for VM Service port to be available...'


class VmRecoveryTests(unittest.TestCase):
    def test_requires_explicit_wait_and_full_twenty_seconds(self):
        gate = VmDiscoveryRecovery()
        self.assertFalse(gate.claim(100))
        gate.observe(WAIT, 100)
        gate.observe(WAIT, 110)
        self.assertFalse(gate.claim(119.99))
        self.assertTrue(gate.claim(120))
        self.assertFalse(gate.claim(10000))

    def test_loading_is_not_a_started_dart_test(self):
        gate = VmDiscoveryRecovery()
        gate.observe('00:00 +0: loading integration_test/audio_tools_test.dart', 1)
        gate.observe(WAIT, 2)
        self.assertTrue(gate.claim(22))

    def test_native_vm_listening_does_not_prove_flutter_connected(self):
        gate = VmDiscoveryRecovery()
        gate.observe(WAIT, 0)
        gate.observe('flutter: The Dart VM service is listening on [REDACTED_URL]', 2)
        self.assertTrue(gate.claim(20))

    def test_progress_permanently_prevents_relaunch(self):
        for marker in [
            'TDB_AUDIO_E2E_START generated_pcm_seconds=1',
            'TDB_AUDIO_E2E_FORMAT m4a', 'TDB_AUDIO_E2E_OK formats=m4a,mp3',
            'TDB_WIFI_E2E_URL=http://192.168.0.1/', 'TDB_WIFI_E2E_OK bytes=1',
            '00:00 +0: iOS AVFoundation exports retimed AAC',
            '00:01 +1: All tests passed!', '00:00 +0 -1: failed [E]',
            '{"type":"testStart"}', 'Connecting to service protocol: URI',
        ]:
            with self.subTest(marker=marker):
                gate = VmDiscoveryRecovery()
                gate.observe(WAIT, 1)
                gate.observe(marker, 5)
                gate.observe(WAIT, 10)
                self.assertFalse(gate.claim(100))

    def test_reader_thread_can_block_before_main_log_consumer_catches_up(self):
        gate = VmDiscoveryRecovery()
        gate.observe(WAIT, 0)
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            executor.submit(gate.observe, 'TDB_WIFI_E2E_URL=local', 19).result()
        self.assertFalse(gate.claim(21))

    def test_latch_is_atomic_under_concurrent_claims(self):
        gate = VmDiscoveryRecovery()
        gate.observe(WAIT, 0)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            claimed = list(executor.map(gate.claim, [21] * 16))
        self.assertEqual(sum(claimed), 1)

    def test_relaunch_uses_only_exact_owned_app_and_verified_debug_arguments(self):
        gate = VmDiscoveryRecovery()
        gate.observe(WAIT, 0)
        checked = Mock(side_effect=['/owned/Runner.app', '', 'probe: 123'])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(relaunch_probe_once(gate, UDID, BUNDLE, checked, 21))
        self.assertEqual([call.args for call in checked.call_args_list], [
            (['xcrun', 'simctl', 'get_app_container', UDID, BUNDLE, 'app'], 20),
            (['xcrun', 'simctl', 'terminate', UDID, BUNDLE], 20),
            (['xcrun', 'simctl', 'launch', UDID, BUNDLE, *DEBUG_ARGUMENTS], 20),
        ])
        self.assertFalse(relaunch_probe_once(gate, UDID, BUNDLE, checked, 999))
        self.assertEqual(checked.call_count, 3)
        self.assertNotIn('--disable-service-auth-codes', DEBUG_ARGUMENTS)

    def test_command_failure_consumes_the_only_attempt(self):
        gate = VmDiscoveryRecovery()
        gate.observe(WAIT, 0)
        checked = Mock(side_effect=OSError('simctl failed'))
        with self.assertRaises(OSError):
            relaunch_probe_once(gate, UDID, BUNDLE, checked, 21)
        self.assertFalse(relaunch_probe_once(gate, UDID, BUNDLE, checked, 100))
        self.assertEqual(checked.call_count, 1)

    def test_progress_during_container_check_prevents_both_mutations(self):
        gate = VmDiscoveryRecovery()
        gate.observe(WAIT, 0)

        def arrived(command, timeout):
            gate.observe('TDB_AUDIO_E2E_START generated_pcm_seconds=1', 22)
            return '/owned/Runner.app'

        checked = Mock(side_effect=arrived)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(relaunch_probe_once(gate, UDID, BUNDLE, checked, 21))
        self.assertEqual(checked.call_count, 1)

    def test_other_bundle_is_never_touched(self):
        gate = VmDiscoveryRecovery()
        gate.observe(WAIT, 0)
        checked = Mock()
        with self.assertRaises(ValueError):
            relaunch_probe_once(gate, UDID, 'unrelated.app', checked, 21)
        checked.assert_not_called()


if __name__ == '__main__':
    unittest.main()
