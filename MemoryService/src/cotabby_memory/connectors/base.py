"""The contract every message source implements.

A connector knows one thing: how to read its source into `MessageRecord`s, starting after a cursor
it defined itself. Scrubbing, exclusions, retention, storage and indexing are applied by the
service afterwards, the same way for every source, so a connector cannot forget them.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from ..records import MessageRecord


class ConnectorError(Exception):
    """A failure the user can act on (missing permission, signed out, file not found). Its message
    is shown in the Memory pane as is, so it must say what to do."""


@dataclass(frozen=True)
class Requirement:
    """Something the user must provide before a source can sync."""

    kind: str  # "full_disk_access", "microsoft_sign_in", "slack_token", "folder", "file"
    title: str
    detail: str = ""


@dataclass(frozen=True)
class CheckResult:
    ok: bool
    message: str


@dataclass
class FetchResult:
    records: list[MessageRecord]
    cursor: str | None
    # Human-readable notes for the job log ("skipped 12 media-only messages").
    notes: list[str] = field(default_factory=list)


Progress = Callable[[float, str], None]


class Connector(ABC):
    id: str = ""
    title: str = ""
    description: str = ""
    # "local" sources read files on this Mac; "cloud" sources call a service the user signed into.
    kind: str = "local"
    # Bundle identifiers of the apps whose fields this source's memory serves. Cotabby maps the
    # focused app to sources with this list (see `sources.list`).
    app_bundle_ids: tuple[str, ...] = ()
    requirements: tuple[Requirement, ...] = ()
    # Option keys the pane may edit, with a short label each.
    options_schema: dict[str, str] = {}

    @abstractmethod
    def check(self, options: dict[str, Any]) -> CheckResult:
        """Cheap readiness check (file present and readable, signed in). Never fetches messages."""

    @abstractmethod
    def fetch(self, options: dict[str, Any], cursor: str | None, since: float | None,
              progress: Progress) -> FetchResult:
        """Reads messages newer than `cursor` (or everything since `since` when there is no
        cursor) and returns them with the cursor to resume from next time."""

    def describe(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "description": self.description,
            "kind": self.kind,
            "app_bundle_ids": list(self.app_bundle_ids),
            "requirements": [r.__dict__ for r in self.requirements],
            "options_schema": self.options_schema,
        }
