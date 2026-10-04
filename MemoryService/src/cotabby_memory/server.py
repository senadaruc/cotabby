"""The memory service's process: a JSON-lines RPC server on a Unix domain socket.

Wire format, one JSON object per line in each direction:
    request   {"id": 7, "method": "search", "params": {...}}
    response  {"id": 7, "result": ...}  or  {"id": 7, "error": {"code": "...", "message": "..."}}

Why a Unix socket: only processes of this user can open it (the socket is 0600 inside a 0700
directory), there is no port another app could reach, and Swift can speak it with Foundation
alone. Requests run on a small thread pool so a slow status call never delays a search; builds run
on the job queue and never block either.

The process exits when Cotabby does: `--parent-pid` is polled, so a crashed or force-quit Cotabby
never leaves an orphaned service holding the GPU and the index.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import logging
import logging.handlers
import os
import signal
import sys
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

from .service import MemoryService, RequestError
from .vault import KeyMismatch

MAX_REQUEST_BYTES = 1_000_000
# getsockopt(SOL_LOCAL, LOCAL_PEERPID) from <sys/un.h>; Python's socket module does not name them.
SOL_LOCAL = 0
LOCAL_PEERPID = 0x002
log = logging.getLogger("cotabby_memory.server")


class _TailHandler(logging.Handler):
    """Keeps the most recent log lines for `logs.tail`, so the pane can show them without
    reading files."""

    def __init__(self, capacity: int = 1000):
        super().__init__()
        self.lines: deque[str] = deque(maxlen=capacity)

    def emit(self, record: logging.LogRecord) -> None:
        self.lines.append(self.format(record))


def configure_logging(data_dir: Path, verbose: bool) -> _TailHandler:
    logs = data_dir / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    file_handler = logging.handlers.RotatingFileHandler(logs / "service.log", maxBytes=2_000_000, backupCount=2)
    file_handler.setFormatter(formatter)
    tail = _TailHandler()
    tail.setFormatter(formatter)
    root = logging.getLogger()
    root.handlers[:] = [file_handler, tail]
    root.setLevel(logging.DEBUG if verbose else logging.INFO)
    # LEANN and its model libraries are chatty at INFO; keep their warnings only.
    for noisy in ("leann", "leann_backend_hnsw", "sentence_transformers", "transformers", "httpx", "urllib3"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
    return tail


class Server:
    def __init__(self, service: MemoryService, socket_path: Path, parent_pid: int | None):
        self.service = service
        self.socket_path = socket_path
        self.parent_pid = parent_pid
        self.methods = service.methods()
        self.pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="memory-rpc")
        self._stopping = asyncio.Event()
        self._pending: set[asyncio.Task] = set()

    async def run(self) -> None:
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(self.socket_path.parent, 0o700)
        self.socket_path.unlink(missing_ok=True)
        # Create the socket under a restrictive umask so it is never briefly world-accessible.
        previous = os.umask(0o177)
        try:
            server = await asyncio.start_unix_server(self._client, path=str(self.socket_path),
                                                     limit=MAX_REQUEST_BYTES)
        finally:
            os.umask(previous)
        # Remember which socket file is ours: a newer service started by a relaunched Cotabby can
        # bind the same path before this one notices its parent is gone, and shutting down must not
        # delete that newer service's socket.
        self._socket_inode = os.stat(self.socket_path).st_ino
        loop = asyncio.get_running_loop()
        for signum in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(signum, self._stopping.set)
        watcher = asyncio.create_task(self._watch_parent())
        log.info("listening on %s", self.socket_path)
        # Tell the supervisor the socket is ready (it waits for this line on stdout).
        print(json.dumps({"event": "ready", "socket": str(self.socket_path)}), flush=True)
        async with server:
            await self._stopping.wait()
        watcher.cancel()
        self._remove_own_socket()
        self.pool.shutdown(wait=False, cancel_futures=True)
        self.service.close()
        log.info("stopped")

    def _remove_own_socket(self) -> None:
        try:
            if os.stat(self.socket_path).st_ino == self._socket_inode:
                self.socket_path.unlink()
        except FileNotFoundError:
            pass

    async def _watch_parent(self) -> None:
        while not self._stopping.is_set():
            await asyncio.sleep(2)
            if self.parent_pid and not _process_alive(self.parent_pid):
                log.info("parent %s exited; stopping", self.parent_pid)
                self._stopping.set()

    def _peer_allowed(self, writer: asyncio.StreamWriter) -> bool:
        """Only Cotabby may talk to the service.

        The socket's 0600 mode keeps other users out, but every app running as this user could
        still connect, and the memory aggregates history that macOS protects at its source (a
        WhatsApp or Mail store needs Full Disk Access). Without this check any same-user process
        could read that history through the service: a confused deputy. The kernel reports the
        connecting process's pid; it must be the parent that launched the service.
        """
        if self.parent_pid is None:
            return True  # Started by hand for development; there is no app to verify against.
        sock = writer.get_extra_info("socket")
        try:
            raw = sock.getsockopt(SOL_LOCAL, LOCAL_PEERPID, 4)
        except OSError:
            return False
        peer = int.from_bytes(raw, "little")
        if peer != self.parent_pid:
            log.warning("refused a connection from pid %s (only %s may connect)", peer, self.parent_pid)
            return False
        return True

    async def _client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        if not self._peer_allowed(writer):
            await self._send(writer, {"id": None, "error": {"code": "forbidden", "message": "Only Cotabby may use the memory service."}})
            writer.close()
            return
        try:
            while not reader.at_eof():
                try:
                    line = await reader.readline()
                except (asyncio.LimitOverrunError, ValueError):
                    await self._send(writer, {"id": None, "error": {"code": "too_large", "message": "Request too large."}})
                    break
                if not line:
                    break
                task = asyncio.create_task(self._handle(line, writer))
                self._pending.add(task)
                task.add_done_callback(self._pending.discard)
        except ConnectionResetError:
            pass
        finally:
            # Close our side once the client hangs up (after its in-flight answers are sent):
            # since Python 3.12 `Server.wait_closed` waits for every connection, so a connection
            # left half-open would keep the service from ever shutting down.
            pending = [task for task in self._pending if not task.done()]
            if pending:
                await asyncio.gather(*pending, return_exceptions=True)
            writer.close()

    async def _handle(self, line: bytes, writer: asyncio.StreamWriter) -> None:
        request_id: Any = None
        try:
            request = json.loads(line)
            request_id = request.get("id")
            method = self.methods.get(request.get("method", ""))
            if method is None:
                raise RequestError("unknown_method", f"Unknown method: {request.get('method')}")
            params = request.get("params") or {}
            if not isinstance(params, dict):
                raise RequestError("bad_params", "params must be an object")
            if request.get("method") == "service.stop":
                self._stopping.set()
                result: Any = {"ok": True}
            else:
                result = await asyncio.get_running_loop().run_in_executor(self.pool, method, params)
            response = {"id": request_id, "result": result}
        except RequestError as error:
            response = {"id": request_id, "error": {"code": error.code, "message": str(error)}}
        except json.JSONDecodeError:
            response = {"id": None, "error": {"code": "bad_json", "message": "Request is not valid JSON."}}
        except Exception as error:  # noqa: BLE001 - every failure becomes an error response
            log.exception("request %s failed", request_id)
            response = {"id": request_id, "error": {"code": "internal", "message": str(error) or type(error).__name__}}
        await self._send(writer, response)

    @staticmethod
    async def _send(writer: asyncio.StreamWriter, payload: dict[str, Any]) -> None:
        try:
            writer.write(json.dumps(payload, ensure_ascii=False).encode() + b"\n")
            await writer.drain()
        except (ConnectionResetError, BrokenPipeError):
            pass


def _process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _acquire_data_lock(data_dir: Path, timeout: float):
    """An exclusive flock on `<data>/service.lock`, held for the process lifetime (the kernel
    releases it when the process exits, however it exits). Returns the open file, or None if
    another process still held it after `timeout` seconds."""
    import fcntl
    import time

    handle = open(data_dir / "service.lock", "w")
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return handle
        except BlockingIOError:
            if time.monotonic() >= deadline:
                handle.close()
                return None
            time.sleep(0.2)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="cotabby-memory")
    parser.add_argument("--data-dir", required=True, type=Path)
    parser.add_argument("--socket", type=Path, help="defaults to <data-dir>/memory.sock")
    parser.add_argument("--parent-pid", type=int)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    data_dir: Path = args.data_dir.expanduser()
    data_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(data_dir, 0o700)
    # One service per data folder: a second one (Cotabby relaunched while the previous service is
    # still exiting) waits for the lock rather than writing the same index and store concurrently.
    lock = _acquire_data_lock(data_dir, timeout=15)
    if lock is None:
        print(json.dumps({"event": "error", "code": "busy",
                          "message": "Another memory service is still using this data."}), flush=True)
        return 4
    tail = configure_logging(data_dir, args.verbose)
    # LEANN appends every query (the user's typed text) to this file when the variable is set.
    os.environ.pop("LEANN_QUERY_LOG", None)

    # The encryption key arrives as the first stdin line, `{"key": "<base64 of 32 bytes>"}`. Not an
    # argument or environment variable: other processes of the same user can read those (`ps`).
    try:
        key = base64.b64decode(json.loads(sys.stdin.readline())["key"])
        if len(key) != 32:
            raise ValueError("key must be 32 bytes")
    except Exception as error:  # noqa: BLE001 - any malformed key is the same failure to the caller
        print(json.dumps({"event": "error", "code": "no_key", "message": f"No valid key on stdin: {error}"}), flush=True)
        return 2
    try:
        service = MemoryService(data_dir, key, log_tail=lambda lines: list(tail.lines)[-lines:])
    except KeyMismatch as error:
        print(json.dumps({"event": "error", "code": "key_mismatch", "message": str(error)}), flush=True)
        return 3
    socket_path = (args.socket or data_dir / "memory.sock").expanduser()
    # Unix socket paths are limited to ~104 bytes on macOS; fail with a clear message.
    if len(str(socket_path).encode()) > 100:
        print(json.dumps({"event": "error", "message": f"Socket path too long: {socket_path}"}), flush=True)
        return 2
    asyncio.run(Server(service, socket_path, args.parent_pid).run())
    logging.shutdown()
    # Exit now, without waiting for worker threads: a job thread can be minutes into an embedding
    # pass on the GPU, and the interpreter would otherwise wait for it while a relaunched Cotabby's
    # new service starts on the same data. An interrupted build is discarded on the next start
    # (`IndexManager._clean_up_after_interruption`) and store writes are SQLite transactions.
    sys.stdout.flush()
    os._exit(0)


if __name__ == "__main__":
    sys.exit(main())
