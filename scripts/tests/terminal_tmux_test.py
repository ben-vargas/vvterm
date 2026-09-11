#!/usr/bin/env python3
"""Exercise real tmux on isolated sockets; never attach to a user's server."""
import os
import pathlib
import pty
import select
import shutil
import subprocess
import time
import unittest
import uuid

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'test_terminal_events.sh'


@unittest.skipUnless(shutil.which('tmux'), 'tmux is not installed')
class TerminalTmuxTests(unittest.TestCase):
    def setUp(self):
        self.socket = 'vvterm-events-test-' + uuid.uuid4().hex
        self.base = ['tmux', '-L', self.socket, '-f', '/dev/null']
        self.env = dict(os.environ, TERM='xterm-256color')
        self.env.pop('TMUX', None)
        self.clients = []
        self.fds = []
        self.inner = None
        self.run_tmux('new-session', '-d', '-s', 'probe', '/bin/sh')
        self.run_tmux('set-option', '-w', '-t', 'probe:0', 'allow-passthrough', 'on')

    def tearDown(self):
        if self.inner:
            subprocess.run(self.inner + ['kill-server'], capture_output=True, env=self.env)
        subprocess.run(self.base + ['kill-server'], capture_output=True, env=self.env)
        for process in self.clients:
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for fd in self.fds:
            os.close(fd)

    def run_tmux(self, *args):
        return subprocess.check_output(self.base + list(args), env=self.env, stderr=subprocess.PIPE).decode().strip()

    def attach(self):
        master, slave = pty.openpty()
        process = subprocess.Popen(self.base + ['attach-session', '-t', 'probe'],
                                   stdin=slave, stdout=slave, stderr=slave, env=self.env)
        os.close(slave)
        self.clients.append(process)
        self.fds.append(master)
        self.read(master, 0.3)
        return master

    def read(self, master, seconds):
        result = b''
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            try:
                result += os.read(master, 65536)
            except OSError:
                break
        return result

    def output(self, payload, base=None):
        # Only controlled test bytes enter shell syntax, encoded as octal escapes.
        encoded = ''.join('\\%03o' % byte for byte in payload)
        command = "printf '%b' '" + encoded + "'"
        subprocess.check_call((base or self.base) + ['send-keys', '-t', 'probe:0.0', '-l', command], env=self.env)
        subprocess.check_call((base or self.base) + ['send-keys', '-t', 'probe:0.0', 'Enter'], env=self.env)

    def test_passthrough_emits_one_event(self):
        master = self.attach()
        payload = subprocess.check_output([str(SCRIPT), 'all', '--delay', '0', '--tmux-depth', '1'])
        self.output(payload)
        self.assert_events(self.read(master, 0.5))

    def test_nested_passthrough_emits_one_event(self):
        master = self.attach()
        self.inner = ['tmux', '-L', self.socket + '-inner', '-f', '/dev/null']
        command = ' '.join(self.inner) + ' new-session -s probe /bin/sh'
        self.run_tmux('send-keys', '-t', 'probe:0.0', '-l', command)
        self.run_tmux('send-keys', '-t', 'probe:0.0', 'Enter')
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if subprocess.run(self.inner + ['has-session', '-t', 'probe'], capture_output=True, env=self.env).returncode == 0:
                break
            time.sleep(0.05)
        subprocess.check_call(self.inner + ['set-option', '-w', '-t', 'probe:0', 'allow-passthrough', 'on'], env=self.env)
        self.read(master, 0.3)
        payload = subprocess.check_output([str(SCRIPT), 'all', '--delay', '0', '--tmux-depth', '2'])
        self.output(payload, self.inner)
        self.assert_events(self.read(master, 0.5))

    def assert_events(self, output):
        for state in (b'1;50', b'4;50', b'2;50', b'3', b'1;100', b'0'):
            self.assertEqual(output.count(b'\x1b]9;4;' + state + b'\x1b\\'), 1)
        self.assertEqual(output.count(b'\x1b]9;VVTerm OSC 9 test\x1b\\'), 1)
        self.assertEqual(output.count(b'\x1b]777;notify;VVTerm OSC 777 test;'), 1)

    def test_removal_blocks_global_value_for_new_processes(self):
        self.run_tmux('set-environment', '-g', 'VVTERM_TEST_CAPABILITY', 'old')
        self.run_tmux('set-environment', '-t', 'probe', 'VVTERM_TEST_CAPABILITY', 'current')
        for flag, expected in [('-u', 'old'), ('-r', 'missing')]:
            self.run_tmux('set-environment', flag, '-t', 'probe', 'VVTERM_TEST_CAPABILITY')
            self.run_tmux('new-window', '-d', '-t', 'probe', '/bin/sh', '-c',
                          'tmux set-option -g @probe-result "${VVTERM_TEST_CAPABILITY-missing}"; tmux wait-for -S result')
            subprocess.run(self.base + ['wait-for', 'result'], check=True, timeout=3, env=self.env)
            self.assertEqual(self.run_tmux('show-options', '-gqv', '@probe-result'), expected)


if __name__ == '__main__':
    if shutil.which('tmux'):
        print(subprocess.check_output(['tmux', '-V'], text=True).strip(), flush=True)
    unittest.main()
