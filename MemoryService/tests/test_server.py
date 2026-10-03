"""The wire protocol, through a real server process on a real Unix socket."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest


@pytest.fixture()
def server():
    # Socket paths are length-limited on macOS, so use a short temp dir instead of pytest's.
    data_dir = Path(tempfile.mkdtemp(prefix="cm-"))
    process = subprocess.Popen(
        [sys.executable, "-m", "cotabby_memory", "--data-dir", str(data_dir), "--parent-pid", str(os.getpid())],
        stdout=subprocess.PIPE,
        env={**os.environ, "PYTHONPATH": str(Path(__file__).parents[1] / "src")},
        text=True,
    )
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


def test_the_service_exits_with_its_parent(tmp_path):
    data_dir = Path(tempfile.mkdtemp(prefix="cm-"))
    parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    process = subprocess.Popen(
        [sys.executable, "-m", "cotabby_memory", "--data-dir", str(data_dir), "--parent-pid", str(parent.pid)],
        stdout=subprocess.PIPE, text=True,
        env={**os.environ, "PYTHONPATH": str(Path(__file__).parents[1] / "src")},
    )
    assert json.loads(process.stdout.readline())["event"] == "ready"
    parent.kill()
    parent.wait()
    assert process.wait(timeout=15) == 0
