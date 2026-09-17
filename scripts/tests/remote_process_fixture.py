#!/usr/bin/env python3
"""Loopback-only SSH process fixture. Requires paramiko==4.0.0 in a test venv."""
import argparse
import json
import os
import secrets
import signal
import socket
import subprocess
import threading
import tempfile
import time
from pathlib import Path

import paramiko


def serve_channel(channel, command):
    if command in (b"__fixture_no_exit__", b"__fixture_signal__"):
        channel.sendall(b"fixture")
        if command == b"__fixture_signal__":
            message = paramiko.Message()
            message.add_byte(paramiko.common.cMSG_CHANNEL_REQUEST)
            message.add_int(channel.remote_chanid)
            message.add_string("exit-signal")
            message.add_boolean(False)
            message.add_string("TERM")
            message.add_boolean(False)
            message.add_string("")
            message.add_string("")
            channel.transport._send_user_message(message)
        channel.shutdown_write()
        channel.close()
        return
    process = subprocess.Popen(command.decode(), shell=True, executable="/bin/sh",
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)

    def copy_output(source, send):
        try:
            while chunk := os.read(source.fileno(), 32768):
                send(chunk)
        except (OSError, EOFError):
            pass

    def copy_input():
        try:
            while chunk := channel.recv(32768):
                process.stdin.write(chunk)
                process.stdin.flush()
        except (OSError, EOFError):
            pass
        finally:
            try:
                process.stdin.close()
            except OSError:
                pass

    readers = [threading.Thread(target=copy_output, args=(process.stdout, channel.sendall), daemon=True),
               threading.Thread(target=copy_output, args=(process.stderr, channel.sendall_stderr), daemon=True)]
    for reader in readers:
        reader.start()
    threading.Thread(target=copy_input, daemon=True).start()
    while process.poll() is None:
        if channel.closed or not channel.transport.is_active():
            os.killpg(process.pid, signal.SIGKILL)
            break
        time.sleep(0.01)
    status = process.wait()
    for reader in readers:
        reader.join(timeout=2)
    if not channel.closed:
        channel.send_exit_status(status)
        channel.shutdown_write()
        channel.close()


class Server(paramiko.ServerInterface):
    def __init__(self, password):
        self.password = password

    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if username == "vvterm-test" and secrets.compare_digest(password, self.password) else paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return "password"

    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, *args):
        return True

    def check_channel_exec_request(self, channel, command):
        if command == b"__fixture_drop_before_ack__":
            channel.transport.close()
            return False
        # Reply to exec before emitting channel output.
        threading.Timer(0.01, serve_channel, args=(channel, command)).start()
        return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready", type=Path, required=True)
    args = parser.parse_args()
    def stop(_signal, _frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    temporary = tempfile.TemporaryDirectory(prefix="vvterm-process-fixture-")
    argument_script = Path(temporary.name) / "arguments.ps1"
    argument_script.write_text("ConvertTo-Json -Compress -InputObject @($args)")
    password = secrets.token_urlsafe(32)
    key = paramiko.RSAKey.generate(2048)
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    args.ready.touch(mode=0o600)
    args.ready.write_text(json.dumps({"port": listener.getsockname()[1], "password": password, "argumentScript": str(argument_script)}))
    transports = []
    try:
        while True:
            connection, _ = listener.accept()
            transport = paramiko.Transport(connection)
            transport.add_server_key(key)
            transport.start_server(server=Server(password))
            transports.append(transport)
    finally:
        for transport in transports:
            transport.close()
        listener.close()
        args.ready.unlink(missing_ok=True)
        temporary.cleanup()


if __name__ == "__main__":
    main()
