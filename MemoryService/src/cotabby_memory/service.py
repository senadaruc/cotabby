"""The memory service's methods, independent of the socket that carries them.

`MemoryService` owns the config, the message store, the index and the job queue, and implements
every protocol method as a plain Python method taking and returning JSON-shaped values. The
server only parses lines and dispatches here, so every behaviour is testable without a socket.

Scope rule for suggestions (`search` without `global`): results come from the conversation the
user is typing in, and, only when that has too few matches, from other conversations that every
current reader took part in (`MessageStore.conversations_seen_by`). A suggestion therefore never
repeats something to a person who was not there: not another person's chat, and not a member's
private chat inside a group. The conversation is found by title only within the focused app's
sources, so a same-named chat in another app is never picked.
"""

from __future__ import annotations

import logging
import platform
import time
from collections.abc import Callable
from importlib import metadata as importlib_metadata
from pathlib import Path
from typing import Any

from . import PROTOCOL_VERSION, __version__
from .config import ConfigStore, MemoryConfig
from .connectors import all_connectors
from .connectors.base import Connector, ConnectorError
from .index import IndexManager
from .jobs import Job, JobManager
from .records import MessageRecord, normalize_participant
from .scrub import scrub, strip_mail_quotes
from .store import Conversation, MessageStore
from .vault import Vault

log = logging.getLogger("cotabby_memory.service")


class RequestError(Exception):
    """A request the service understood but cannot satisfy; returned to the client as an error."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class MemoryService:
    def __init__(self, data_dir: Path, key: bytes, connectors: dict[str, Connector] | None = None,
                 log_tail: Callable[[int], list[str]] | None = None):
        """`key` is the 32-byte master key from Cotabby's Keychain. Raises `KeyMismatch` when the
        existing store was encrypted with a different key."""
        self.data_dir = data_dir
        data_dir.mkdir(parents=True, exist_ok=True)
        data_dir.chmod(0o700)
        self.config_store = ConfigStore(data_dir)
        self.config: MemoryConfig = self.config_store.load()
        self.store = MessageStore(data_dir / "messages.sqlite", Vault(key))
        self.index = IndexManager(data_dir, self.store)
        self.jobs = JobManager()
        self.connectors = connectors if connectors is not None else all_connectors()
        self._log_tail = log_tail or (lambda lines: [])
        self.started_at = time.time()

    def close(self) -> None:
        self.jobs.shutdown()
        self.store.close()

    # MARK: - Dispatch

    def methods(self) -> dict[str, Callable[[dict[str, Any]], Any]]:
        return {
            "status": self.status,
            "config.get": lambda params: self.config.to_json(),
            "config.set": self.config_set,
            "sources.list": self.sources_list,
            "sources.configure": self.sources_configure,
            "sources.sync": self.sources_sync,
            "sources.forget": self.sources_forget,
            "sources.cursor": lambda params: {"cursor": self.store.cursor(str(params.get("id", "")))},
            "records.ingest": self.records_ingest,
            "jobs.list": lambda params: self.jobs.list(),
            "jobs.cancel": lambda params: {"cancelled": self.jobs.cancel(int(params.get("id", 0)))},
            "index.status": lambda params: self.index.status(self.config.index),
            "index.rebuild": self.index_rebuild,
            "index.remove": self.index_remove,
            "index.warm": self.index_warm,
            "conversations.find": self.conversations_find,
            "search": self.search,
            "privacy.purge": self.privacy_purge,
            "privacy.delete_all": self.privacy_delete_all,
            "logs.tail": lambda params: {"lines": self._log_tail(int(params.get("lines", 200)))},
        }

    # MARK: - Status and config

    def status(self, params: dict[str, Any]) -> dict[str, Any]:
        return {
            "service_version": __version__,
            "protocol_version": PROTOCOL_VERSION,
            "leann_version": _package_version("leann"),
            "python": platform.python_version(),
            "data_dir": str(self.data_dir),
            "uptime_seconds": round(time.time() - self.started_at, 1),
            "busy": self.jobs.busy(),
            "index": self.index.status(self.config.index),
            "enabled_sources": self._enabled_sources(),
        }

    def config_set(self, params: dict[str, Any]) -> dict[str, Any]:
        before = IndexManager.fingerprint(self.config.index)
        rejected = self.config.apply(params.get("patch") or {})
        self.config_store.save(self.config)
        if IndexManager.fingerprint(self.config.index) != before:
            self.index.mark_needs_rebuild("settings changed")
        return {"config": self.config.to_json(), "rejected": rejected}

    # MARK: - Sources

    def _connector(self, source_id: str) -> Connector:
        connector = self.connectors.get(source_id)
        if connector is None:
            raise RequestError("unknown_source", f"Unknown source: {source_id}")
        return connector

    def _enabled_sources(self) -> list[str]:
        return [sid for sid, cfg in self.config.sources.items() if cfg.enabled and sid in self.connectors]

    def sources_list(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        listed = []
        for source_id, connector in self.connectors.items():
            source_config = self.config.sources.get(source_id)
            options = dict(source_config.options) if source_config else {}
            try:
                check = connector.check(options)
                check_json = {"ok": check.ok, "message": check.message}
            except Exception as error:  # noqa: BLE001 - one broken source must not hide the others
                check_json = {"ok": False, "message": str(error)}
            entry = connector.describe()
            entry.update({
                "enabled": bool(source_config and source_config.enabled),
                "options": options,
                "check": check_json,
                "stats": self.store.source_stats(source_id),
            })
            listed.append(entry)
        return listed

    def sources_configure(self, params: dict[str, Any]) -> dict[str, Any]:
        source_id = str(params.get("id", ""))
        self._connector(source_id)
        patch: dict[str, Any] = {}
        if "enabled" in params:
            patch["enabled"] = bool(params["enabled"])
        if isinstance(params.get("options"), dict):
            patch["options"] = params["options"]
        was_enabled = source_id in self._enabled_sources()
        self.config.apply({"sources": {source_id: patch}})
        self.config_store.save(self.config)
        if was_enabled and source_id not in self._enabled_sources():
            # A disabled source's messages stay in the store (re-enabling is instant) but leave
            # the index, so they can no longer be retrieved.
            self.index.mark_needs_rebuild(f"{source_id} disabled")
        return {"ok": True}

    def sources_sync(self, params: dict[str, Any]) -> dict[str, Any]:
        requested = params.get("id")
        sources = [str(requested)] if requested else [
            s for s in self._enabled_sources() if not self.connectors[s].pushed
        ]
        for source_id in sources:
            if self._connector(source_id).pushed:
                raise RequestError("pushed_source", f"{source_id} is synced by Cotabby; use records.ingest.")
        title = f"Sync {', '.join(sources) or 'nothing'}"
        job = self.jobs.submit(f"sync:{','.join(sorted(sources))}", title, lambda job: self._sync(job, sources))
        return job.snapshot()

    def sources_forget(self, params: dict[str, Any]) -> dict[str, Any]:
        """Deletes everything stored from one source and rebuilds the index without it."""
        source_id = str(params.get("id", ""))
        self._connector(source_id)
        self.store.delete_source(source_id)
        self.index.mark_needs_rebuild(f"{source_id} forgotten")
        job = self.jobs.submit("index", "Rebuild index", lambda job: self._index_only(job))
        return job.snapshot()

    def _sync(self, job: Job, sources: list[str]) -> dict[str, Any]:
        summary: dict[str, Any] = {}
        since = self._retention_cutoff()
        for position, source_id in enumerate(sources):
            connector = self._connector(source_id)
            options = self.config.sources.get(source_id).options if source_id in self.config.sources else {}
            base = position / max(len(sources), 1)
            span = 0.6 / max(len(sources), 1)

            def report(fraction: float, message: str, base=base, span=span, source_id=source_id) -> None:
                job.report(base + span * fraction, f"{source_id}: {message}")

            try:
                result = connector.fetch(options, self.store.cursor(source_id), since, report)
            except ConnectorError as error:
                summary[source_id] = {"error": str(error)}
                continue
            changed, dropped = self._ingest(result.records)
            if result.cursor is not None:
                self.store.set_cursor(source_id, result.cursor)
            summary[source_id] = {"read": len(result.records), "stored": changed, "dropped": dropped,
                                  "notes": result.notes}
        job.report(0.65, "Updating the index")
        summary["index"] = self.index.sync(self.config.index, self._enabled_sources(),
                                           lambda fraction, message: job.report(0.65 + 0.35 * fraction, message))
        return summary

    def _retention_cutoff(self) -> float | None:
        retention = self.config.privacy.retention_days
        return time.time() - retention * 86400 if retention else None

    def _ingest(self, records: list[MessageRecord]) -> tuple[int, int]:
        """The pipeline every message passes, whichever side read it: exclusions, retention, mail
        quote stripping, secret scrubbing, then the encrypted store. Returns (stored, dropped)."""
        since = self._retention_cutoff()
        excluded_conversations = set(self.config.privacy.excluded_conversations)
        excluded_people = {normalize_participant(p) for p in self.config.privacy.excluded_participants}
        kept: list[MessageRecord] = []
        dropped = 0
        for record in records:
            if record.conversation_id in excluded_conversations:
                dropped += 1
                continue
            if excluded_people & {normalize_participant(p) for p in (*record.participants, record.sender)}:
                dropped += 1
                continue
            if since is not None and record.timestamp < since:
                dropped += 1
                continue
            text = strip_mail_quotes(record.text) if record.subject is not None else record.text
            cleaned = scrub(text)
            if cleaned is None:
                dropped += 1
                continue
            kept.append(_with_text(record, cleaned))
        return self.store.upsert(kept), dropped

    def records_ingest(self, params: dict[str, Any]) -> dict[str, Any]:
        """Messages Cotabby read from a protected store (see connectors/pushed.py). Batches arrive
        in order; `cursor` is stored after the batch, and `final` queues the index update once."""
        source_id = str(params.get("source", ""))
        connector = self._connector(source_id)
        if not connector.pushed:
            raise RequestError("not_pushed", f"{source_id} is read by the memory service itself.")
        if source_id not in self._enabled_sources():
            raise RequestError("source_disabled", f"{source_id} is turned off.")
        records: list[MessageRecord] = []
        for raw in params.get("records") or []:
            try:
                records.append(MessageRecord(
                    source=source_id,
                    source_message_id=str(raw["source_message_id"]),
                    conversation_id=str(raw["conversation_id"]),
                    conversation_title=str(raw.get("conversation_title") or ""),
                    sender=str(raw.get("sender") or ""),
                    is_from_me=bool(raw.get("is_from_me")),
                    timestamp=float(raw["timestamp"]),
                    text=str(raw.get("text") or ""),
                    participants=tuple(str(p) for p in raw.get("participants") or ()),
                    subject=None if raw.get("subject") is None else str(raw["subject"]),
                ))
            except (KeyError, TypeError, ValueError) as error:
                raise RequestError("bad_record", f"Malformed record: {error}") from error
        stored, dropped = self._ingest(records)
        if params.get("cursor") is not None:
            self.store.set_cursor(source_id, str(params["cursor"]))
        job = None
        if params.get("final"):
            job = self.jobs.submit("index", "Update index", self._index_only).snapshot()
        return {"stored": stored, "dropped": dropped, "job": job}

    # MARK: - Index

    def _index_only(self, job: Job) -> dict[str, Any]:
        return self.index.sync(self.config.index, self._enabled_sources(), job.report)

    def index_rebuild(self, params: dict[str, Any]) -> dict[str, Any]:
        self.index.mark_needs_rebuild("requested")
        return self.jobs.submit("index", "Rebuild index", self._index_only).snapshot()

    def index_remove(self, params: dict[str, Any]) -> dict[str, Any]:
        self.index.remove()
        for source_id in self.connectors:
            self.store.mark_source_unindexed(source_id)
        return {"ok": True}

    def index_warm(self, params: dict[str, Any]) -> dict[str, Any]:
        started = time.perf_counter()
        self.index.warm(self.config.index)
        return {"ms": round((time.perf_counter() - started) * 1000, 1)}

    # MARK: - Retrieval

    def conversations_find(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        sources = params.get("sources") or None
        return [_conversation_json(c) for c in self.store.find_conversations(str(params.get("title", "")), sources)]

    def _resolve(self, scope: dict[str, Any]) -> Conversation | None:
        """The conversation a request is about: by explicit id, else by its title (the chat name
        or mail subject Cotabby read from the focused window) within the focused app's sources.

        A title alone is ambiguous across apps (two different people called "Ali" in WhatsApp and
        Slack), so title matching requires the app's sources; without them nothing is resolved."""
        if scope.get("conversation_id") and scope.get("source"):
            return self.store.conversation(str(scope["source"]), str(scope["conversation_id"]))
        sources = [s for s in (scope.get("sources") or []) if s in self.connectors]
        if not sources:
            return None
        for key in ("title", "subject"):
            title = str(scope.get(key) or "").strip()
            if title:
                found = self.store.find_conversations(title, sources)
                if found:
                    return found[0]
        return None

    def search(self, params: dict[str, Any]) -> dict[str, Any]:
        started = time.perf_counter()
        query = str(params.get("query", ""))
        scope = params.get("scope") or {}
        top_k = int(params.get("top_k") or self.config.index.top_k)
        top_k = max(1, min(top_k, 20))
        enabled = set(self._enabled_sources())

        if scope.get("global"):
            hits = self.index.search(query, self.config.index, conversations=None, top_k=top_k)
            hits = [h for h in hits if h.message.source in enabled]
            return self._search_result("global", None, hits, started)

        conversation = self._resolve(scope)
        if conversation is None or conversation.source not in enabled:
            return self._search_result("none", None, [], started)

        own = [(conversation.source, conversation.conversation_id)]
        hits = self.index.search(query, self.config.index, conversations=own, top_k=top_k)
        scope_name = "conversation"
        if len(hits) < top_k and conversation.participants:
            # Only conversations every current reader took part in (see `conversations_seen_by`).
            related = [pair for pair in self.store.conversations_seen_by(conversation.participants, exclude=own[0])
                       if pair[0] in enabled]
            if related:
                more = self.index.search(query, self.config.index, conversations=related, top_k=top_k - len(hits))
                seen = {h.message.record_id for h in hits}
                extra = [h for h in more if h.message.record_id not in seen]
                if extra:
                    scope_name = "person"
                    hits = hits + extra
        return self._search_result(scope_name, conversation, hits, started)

    def _search_result(self, scope: str, conversation: Conversation | None, hits: list, started: float) -> dict[str, Any]:
        titles: dict[tuple[str, str], str] = {}

        def title_for(source: str, conversation_id: str) -> str:
            key = (source, conversation_id)
            if key not in titles:
                titles[key] = self.store.conversation_title(source, conversation_id)
            return titles[key]

        return {
            "scope": scope,
            "conversation": _conversation_json(conversation) if conversation else None,
            "elapsed_ms": round((time.perf_counter() - started) * 1000, 1),
            "hits": [
                {
                    "record_id": hit.message.record_id,
                    "source": hit.message.source,
                    "conversation_id": hit.message.conversation_id,
                    "conversation_title": title_for(hit.message.source, hit.message.conversation_id),
                    "sender": hit.message.sender,
                    "is_from_me": hit.message.is_from_me,
                    "timestamp": hit.message.timestamp,
                    "subject": hit.message.subject,
                    "text": hit.message.text,
                    "score": round(hit.score, 6),
                    "via": hit.via,
                }
                for hit in hits
            ],
        }

    # MARK: - Privacy

    def privacy_purge(self, params: dict[str, Any]) -> dict[str, Any]:
        retention = self.config.privacy.retention_days
        removed = self.store.purge(
            excluded_conversations=self.config.privacy.excluded_conversations,
            excluded_participants=self.config.privacy.excluded_participants,
            older_than=time.time() - retention * 86400 if retention else None,
        )
        if removed:
            self.index.mark_needs_rebuild("messages purged")
            self.jobs.submit("index", "Rebuild index", self._index_only)
        return {"removed": removed}

    def privacy_delete_all(self, params: dict[str, Any]) -> dict[str, Any]:
        """Forgets everything: the index, every stored message and every cursor. Settings stay."""
        self.index.remove()
        for source_id in list(self.connectors):
            self.store.delete_source(source_id)
        return {"ok": True}


def _with_text(record: MessageRecord, text: str) -> MessageRecord:
    from dataclasses import replace

    return replace(record, text=text)


def _conversation_json(conversation: Conversation) -> dict[str, Any]:
    return {
        "source": conversation.source,
        "conversation_id": conversation.conversation_id,
        "title": conversation.title,
        "participants": list(conversation.participants),
        "last_timestamp": conversation.last_timestamp,
    }


def _package_version(name: str) -> str | None:
    try:
        return importlib_metadata.version(name)
    except importlib_metadata.PackageNotFoundError:
        return None
