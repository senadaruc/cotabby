"""A folder of notes and documents as a memory source.

The simplest connector, and the one Phase 0 proves the whole pipeline with: every paragraph of
every text file in a folder becomes a record, its file is its conversation. Useful on its own for
reference notes (pricing, product facts) that suggestions in any app may draw on when the user
scopes a field to it, and as a template for richer connectors.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from ..records import MessageRecord
from .base import CheckResult, Connector, ConnectorError, FetchResult, Progress, Requirement

_TEXT_SUFFIXES = {".txt", ".md", ".markdown", ".text", ".org", ".rst"}
_MAX_FILE_BYTES = 2_000_000


class DocumentsConnector(Connector):
    id = "documents"
    title = "Documents Folder"
    description = "Plain-text and Markdown files in a folder you choose."
    kind = "local"
    requirements = (Requirement("folder", "Folder", "The folder whose .txt and .md files are remembered."),)
    options_schema = {"folder": "Folder"}

    def _folder(self, options: dict[str, Any]) -> Path:
        raw = str(options.get("folder") or "").strip()
        if not raw:
            raise ConnectorError("Choose a folder for this source.")
        return Path(os.path.expanduser(raw))

    def check(self, options: dict[str, Any]) -> CheckResult:
        try:
            folder = self._folder(options)
        except ConnectorError as error:
            return CheckResult(False, str(error))
        if not folder.is_dir():
            return CheckResult(False, f"{folder} is not a folder.")
        if not os.access(folder, os.R_OK):
            return CheckResult(False, f"Cotabby cannot read {folder}.")
        return CheckResult(True, f"Reading {folder}")

    def fetch(self, options: dict[str, Any], cursor: str | None, since: float | None,
              progress: Progress) -> FetchResult:
        folder = self._folder(options)
        if not folder.is_dir():
            raise ConnectorError(f"{folder} is not a folder.")
        # Cursor: the newest modification time already read. Files changed since are re-read
        # whole; their paragraphs keep stable ids, so unchanged ones are no-ops in the store.
        after = float(cursor) if cursor else 0.0
        files = [p for p in folder.rglob("*") if p.suffix.lower() in _TEXT_SUFFIXES and p.is_file()]
        records: list[MessageRecord] = []
        newest = after
        for number, path in enumerate(sorted(files)):
            stat = path.stat()
            if stat.st_mtime <= after or stat.st_size > _MAX_FILE_BYTES:
                continue
            newest = max(newest, stat.st_mtime)
            text = path.read_text(encoding="utf-8", errors="replace")
            relative = str(path.relative_to(folder))
            for paragraph_number, paragraph in enumerate(_paragraphs(text)):
                records.append(
                    MessageRecord(
                        source=self.id,
                        source_message_id=f"{relative}#{paragraph_number}",
                        conversation_id=relative,
                        conversation_title=path.stem,
                        sender=path.stem,
                        is_from_me=True,
                        timestamp=stat.st_mtime,
                        text=paragraph,
                    )
                )
            progress((number + 1) / max(len(files), 1), f"Read {relative}")
        return FetchResult(records, str(newest))


def _paragraphs(text: str) -> list[str]:
    blocks = [" ".join(block.split()) for block in text.split("\n\n")]
    return [block for block in blocks if len(block) >= 20]
