"""Runs the service's long work (syncing sources, building the index) one job at a time.

Why serialized: every job ends by writing the same LEANN index and the same store, and an
embedding pass already uses the whole GPU, so two at once would only contend. Searches do not go
through here; they run on the request threads and are never queued behind a build.

Jobs report progress and can be cancelled. Cancellation is cooperative: the job function checks
`job.cancelled` between phases (after a fetch, before embedding), never mid-write.
"""

from __future__ import annotations

import itertools
import logging
import threading
import time
import traceback
from collections import deque
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger("cotabby_memory.jobs")


class JobCancelled(Exception):
    pass


@dataclass
class Job:
    id: int
    kind: str
    title: str
    status: str = "queued"  # queued, running, done, failed, cancelled
    progress: float = 0.0
    message: str = ""
    created_at: float = field(default_factory=time.time)
    started_at: float | None = None
    finished_at: float | None = None
    result: Any = None
    error: str | None = None
    cancelled: bool = False

    def report(self, fraction: float, message: str) -> None:
        if self.cancelled:
            raise JobCancelled()
        self.progress = max(0.0, min(1.0, fraction))
        self.message = message

    def snapshot(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind,
            "title": self.title,
            "status": self.status,
            "progress": round(self.progress, 3),
            "message": self.message,
            "created_at": self.created_at,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "result": self.result,
            "error": self.error,
        }


class JobManager:
    # Finished jobs kept for the pane's history.
    HISTORY = 30

    def __init__(self) -> None:
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="memory-job")
        self._ids = itertools.count(1)
        self._lock = threading.Lock()
        self._jobs: deque[Job] = deque()

    def submit(self, kind: str, title: str, work: Callable[[Job], Any]) -> Job:
        """Queues `work`. A job of the same kind already queued is reused instead of duplicated,
        so repeated "Sync now" clicks collapse into one sync."""
        with self._lock:
            for existing in self._jobs:
                if existing.kind == kind and existing.status == "queued":
                    return existing
            job = Job(id=next(self._ids), kind=kind, title=title)
            self._jobs.append(job)
            while len(self._jobs) > self.HISTORY and self._jobs[0].status not in ("queued", "running"):
                self._jobs.popleft()
        self._executor.submit(self._run, job, work)
        return job

    def _run(self, job: Job, work: Callable[[Job], Any]) -> None:
        if job.cancelled:
            job.status = "cancelled"
            job.finished_at = time.time()
            return
        job.status = "running"
        job.started_at = time.time()
        try:
            job.result = work(job)
            job.status = "done"
            job.progress = 1.0
        except JobCancelled:
            job.status = "cancelled"
        except Exception as error:  # noqa: BLE001 - every failure is reported to the pane
            job.status = "failed"
            job.error = str(error) or error.__class__.__name__
            log.error("job %s (%s) failed: %s\n%s", job.id, job.kind, job.error, traceback.format_exc())
        finally:
            job.finished_at = time.time()

    def cancel(self, job_id: int) -> bool:
        with self._lock:
            for job in self._jobs:
                if job.id == job_id and job.status in ("queued", "running"):
                    job.cancelled = True
                    return True
        return False

    def list(self) -> list[dict[str, Any]]:
        with self._lock:
            return [job.snapshot() for job in reversed(self._jobs)]

    def busy(self) -> bool:
        with self._lock:
            return any(job.status in ("queued", "running") for job in self._jobs)

    def shutdown(self) -> None:
        with self._lock:
            for job in self._jobs:
                job.cancelled = True
        self._executor.shutdown(wait=False, cancel_futures=True)
