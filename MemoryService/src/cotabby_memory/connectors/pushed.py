"""Sources Cotabby reads itself and pushes to the service.

Why some sources are not read here: their stores are protected by macOS (Full Disk Access, or
App Data protection for another app's group container), and the service deliberately runs without
any of Cotabby's permissions (it is spawned with responsibility disclaimed, see
`IsolatedProcessSpawner.swift`). Cotabby's signed code reads them and sends the messages with
`records.ingest`; the service applies the same scrubbing, exclusions, retention, encryption and
indexing as for any other source. These connector objects only describe the source for the
Memory pane and refuse a service-side fetch.
"""

from __future__ import annotations

from typing import Any

from .base import CheckResult, Connector, ConnectorError, FetchResult, Progress, Requirement


class PushedSource(Connector):
    kind = "local"
    pushed = True

    def __init__(self, source_id: str, title: str, description: str, app_bundle_ids: tuple[str, ...],
                 requirements: tuple[Requirement, ...]):
        self.id = source_id
        self.title = title
        self.description = description
        self.app_bundle_ids = app_bundle_ids
        self.requirements = requirements
        self.options_schema = {}

    def check(self, options: dict[str, Any]) -> CheckResult:
        # Whether Cotabby can read the store is known only to Cotabby, which shows it in the pane.
        return CheckResult(True, "Read by Cotabby on this Mac")

    def fetch(self, options: dict[str, Any], cursor: str | None, since: float | None,
              progress: Progress) -> FetchResult:
        raise ConnectorError(f"{self.title} is synced by Cotabby, not by the memory service.")

    def describe(self) -> dict[str, Any]:
        description = super().describe()
        description["pushed"] = True
        return description


FULL_DISK_ACCESS = Requirement(
    "full_disk_access", "Full Disk Access",
    "Cotabby needs Full Disk Access to read this app's local history.",
)


def pushed_sources() -> list[PushedSource]:
    return [
        PushedSource(
            "whatsapp", "WhatsApp",
            "Chats from WhatsApp for Mac, read from its local database.",
            ("net.whatsapp.WhatsApp",), (FULL_DISK_ACCESS,),
        ),
        PushedSource(
            "apple_mail", "Apple Mail",
            "Mail from all accounts in the Mail app, read from its local store.",
            ("com.apple.mail",), (FULL_DISK_ACCESS,),
        ),
    ]
