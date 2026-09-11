#!/usr/bin/env python3
"""Verify that the local Mosh server discards unsupported OSC events, not text."""
import os
import fcntl
import struct
import termios
import pty
import re
import select
import shutil
import signal
import subprocess
import time
import unittest


@unittest.skipUnless(shutil.which('mosh-server') and shutil.which('mosh-client'), 'Mosh is not installed')
class TerminalMoshTests(unittest.TestCase):
    def test_unsupported_osc_does_not_become_visible_text(self):
        env = dict(os.environ, TERM='xterm-256color', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8')
        # Own a temporary server and keep it alive until both surrounding markers
        # reach the client. Never print its temporary authentication key.
        script = ("printf 'BEFORE_OSC_TEST\\r\\n'; "
                  "printf '\\033]9;HIDDEN_NOTIFICATION_BODY\\007'; "
                  "printf '\\033]777;notify;HIDDEN_NOTIFICATION_TITLE;HIDDEN_MESSAGE\\033\\\\'; "
                  "printf '\\033]9;4;1;50\\033\\\\'; "
                  "printf 'AFTER_OSC_TEST\\r\\n'; sleep 10")
        launcher = subprocess.run(['mosh-server', 'new', '-i', '127.0.0.1',
                                   '--', '/bin/sh', '-c', script], env=env,
                                  capture_output=True, timeout=5)
        output = (launcher.stdout + launcher.stderr).decode(errors='replace')
        pid_match = re.search(r'pid\s*(?:=\s*)?(\d+)', output)
        credentials = re.search(r'MOSH CONNECT (\d+) (\S+)', output)
        server_pid = int(pid_match[1]) if pid_match else None
        client = None
        master = None
        try:
            self.assertEqual(launcher.returncode, 0, 'Mosh server could not start')
            self.assertIsNotNone(server_pid, 'Mosh did not report its owned server PID')
            self.assertIsNotNone(credentials, 'Mosh did not provide connection data')
            env['MOSH_KEY'] = credentials[2]
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
            client = subprocess.Popen(['mosh-client', '127.0.0.1', credentials[1]],
                                      stdin=slave, stdout=slave, stderr=slave, env=env)
            os.close(slave)
            received = b''
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and b'AFTER_OSC_TEST' not in received:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    received += os.read(master, 65536)
            self.assertIn(b'BEFORE_OSC_TEST', received)
            self.assertIn(b'AFTER_OSC_TEST', received)
            for hidden in (b'HIDDEN_NOTIFICATION_BODY', b'HIDDEN_NOTIFICATION_TITLE', b'HIDDEN_MESSAGE',
                           b'\x1b]9;', b'\x1b]777;'):
                self.assertNotIn(hidden, received)
        finally:
            if client:
                client.terminate()
                try:
                    client.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    client.kill()
                    client.wait()
            if master is not None:
                os.close(master)
            if server_pid:
                try:
                    os.kill(server_pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass


if __name__ == '__main__':
    unittest.main()
