"""The wire protocol, through a real server process on a real Unix socket."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

import base64

import pytest

KEY_LINE = json.dumps({"key": base64.b64encode(bytes(range(32))).decode()}) + "\n"


def start(data_dir: Path, parent_pid: int, key_line: str = KEY_LINE, socket_path: Path | None = None) -> subprocess.Popen:
    extra = ["--socket", str(socket_path)] if socket_path else []
    process = subprocess.Popen(
        [sys.executable, "-m", "cotabby_memory", "--data-dir", str(data_dir), "--parent-pid", str(parent_pid), *extra],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        env={**os.environ, "PYTHONPATH": str(Path(__file__).parents[1] / "src")},
    )
    process.stdin.write(key_line)
    process.stdin.close()
    return process


@pytest.fixture()
def server():
    # Socket paths are length-limited on macOS, so use a short temp dir instead of pytest's.
    data_dir = Path(tempfile.mkdtemp(prefix="cm-"))
    process = start(data_dir, os.getpid())
    ready = json.loads(process.stdout.readline())
    assert ready["event"] == "ready"
    yield data_dir, Path(ready["socket"])
    process.terminate()
    process.wait(timeout=10)


def call(sock_path: Path, method: str, params: dict | None = None, request_id: int = 1) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(str(sock_path))
        client.sendall(json.dumps({"id": request_id, "method": method, "params": params or {}}).encode() + b"\n")
        data = b""
        while not data.endswith(b"\n"):
            chunk = client.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data)


def test_socket_is_private_and_answers_status(server):
    data_dir, sock_path = server
    assert oct(os.stat(sock_path).st_mode & 0o777) == "0o600"
    assert oct(os.stat(data_dir).st_mode & 0o777) == "0o700"
    response = call(sock_path, "status")
    assert response["id"] == 1
    assert response["result"]["protocol_version"] == 1


def test_errors_are_structured(server):
    _, sock_path = server
    assert call(sock_path, "nope")["error"]["code"] == "unknown_method"
    assert call(sock_path, "sources.sync", {"id": "missing"})["error"]["code"] == "unknown_source"


def test_config_round_trips_over_the_wire(server):
    _, sock_path = server
    result = call(sock_path, "config.set", {"patch": {"index": {"top_k": 6, "backend": "bogus"}}})["result"]
    assert result["rejected"] == ["index.backend"]
    assert call(sock_path, "config.get")["result"]["index"]["top_k"] == 6


def test_other_processes_are_refused(server):
    """Only the launching process may connect: a different process gets `forbidden`."""
    _, sock_path = server
    probe = subprocess.run(
        [sys.executable, "-c", (
            "import json, socket, sys\n"
            "c = socket.socket(socket.AF_UNIX); c.connect(sys.argv[1])\n"
            "c.sendall(b'{\"id\": 1, \"method\": \"status\"}\\n')\n"
            "print(c.recv(65536).decode())"
        ), str(sock_path)],
        capture_output=True, text=True, timeout=10,
    )
    assert json.loads(probe.stdout)["error"]["code"] == "forbidden"


def test_the_service_exits_with_its_parent(tmp_path):
    data_dir = Path(tempfile.mkdtemp(prefix="cm-"))
    parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    process = start(data_dir, parent.pid)
    assert json.loads(process.stdout.readline())["event"] == "ready"
    parent.kill()
    parent.wait()
    assert process.wait(timeout=15) == 0


def test_a_stopping_service_leaves_a_newer_services_socket_alone():
    """If a newer service has bound the socket path by the time an older one shuts down, the older
    one must not delete it. (On one data folder the data lock already orders them; this covers a
    shared socket path.)"""
    sock_path = Path(tempfile.mkdtemp(prefix="cm-")) / "shared.sock"
    old = start(Path(tempfile.mkdtemp(prefix="cm-")), os.getpid(), socket_path=sock_path)
    assert json.loads(old.stdout.readline())["event"] == "ready"
    new = start(Path(tempfile.mkdtemp(prefix="cm-")), os.getpid(), socket_path=sock_path)
    assert json.loads(new.stdout.readline())["event"] == "ready"
    old.terminate()
    old.wait(timeout=10)
    assert sock_path.exists()
    assert call(sock_path, "status")["result"]["protocol_version"] == 1
    new.terminate()
    new.wait(timeout=10)


def test_the_service_refuses_to_start_with_the_wrong_key():
    data_dir = Path(tempfile.mkdtemp(prefix="cm-"))
    first = start(data_dir, os.getpid())
    assert json.loads(first.stdout.readline())["event"] == "ready"
    first.terminate()
    first.wait(timeout=10)
    wrong = start(data_dir, os.getpid(), json.dumps({"key": base64.b64encode(bytes(32)).decode()}) + "\n")
    assert json.loads(wrong.stdout.readline())["code"] == "key_mismatch"
    assert wrong.wait(timeout=10) == 3


def test_a_second_service_on_the_same_data_waits_for_the_first_to_exit():
    """Two services must never write the same index: the second waits for the data lock."""
    data_dir = Path(tempfile.mkdtemp(prefix="cm-"))
    first = start(data_dir, os.getpid())
    assert json.loads(first.stdout.readline())["event"] == "ready"
    second = start(data_dir, os.getpid())
    # The second cannot become ready while the first holds the lock...
    import select
    ready, _, _ = select.select([second.stdout], [], [], 1.5)
    assert not ready
    # ...and becomes ready as soon as the first exits.
    first.terminate()
    assert first.wait(timeout=10) == 0
    assert json.loads(second.stdout.readline())["event"] == "ready"
    second.terminate()
    second.wait(timeout=10)
