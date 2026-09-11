#!/usr/bin/env python3
"""Check emitted protocol bytes without sending notifications to this terminal."""
import pathlib
import subprocess
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'test_terminal_events.sh'


class TerminalEventsTests(unittest.TestCase):
    def emit(self, *args):
        return subprocess.check_output([str(SCRIPT), *args, '--delay', '0'])

    def test_progress_states(self):
        output = self.emit('progress')
        for state in (b'1;50', b'4;50', b'2;50', b'3', b'1;100', b'0'):
            self.assertEqual(output.count(b'\x1b]9;4;' + state + b'\x1b\\'), 1)

    def test_notifications(self):
        output = self.emit('notify')
        self.assertIn(b'\x1b]9;VVTerm OSC 9 test\x1b\\', output)
        self.assertIn(b'\x1b]777;notify;', output)

    def test_nested_tmux(self):
        expected = b'\x1b]9;4;0\x1b\\'
        for depth in range(5):
            self.assertEqual(self.emit('clear', '--tmux-depth', str(depth)), expected)
            expected = b'\x1bPtmux;' + expected.replace(b'\x1b', b'\x1b\x1b') + b'\x1b\\'

    def test_invalid_arguments(self):
        for args in (['--tmux-depth', '999'], ['--delay'], ['--delay', '-1']):
            result = subprocess.run([str(SCRIPT), *args], capture_output=True)
            self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
