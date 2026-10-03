"""Core behaviour without LEANN: config, scrubbing, the store, scope rules, the documents source.

With no index built (or `vector_weight` 0), search is the store's filter-first keyword search, so
these tests pin the scope guarantees exactly and run in milliseconds.
"""

from __future__ import annotations

import os
import time
from pathlib import Path

import pytest

from cotabby_memory.config import ConfigStore, MemoryConfig
from cotabby_memory.connectors.base import CheckResult, Connector, FetchResult
from cotabby_memory.connectors.documents import DocumentsConnector
from cotabby_memory.records import MessageRecord, normalize_participant
from cotabby_memory.scrub import scrub, strip_mail_quotes
from cotabby_memory.service import MemoryService, RequestError
from cotabby_memory.store import MessageStore, title_key


def record(conversation: str, text: str, *, sender: str = "Ayşe", me: bool = False, title: str | None = None,
           participants: tuple[str, ...] = (), ts: float | None = None, source: str = "chat",
           message_id: str | None = None) -> MessageRecord:
    return MessageRecord(
        source=source,
        source_message_id=message_id or f"{conversation}:{text}",
        conversation_id=conversation,
        conversation_title=title if title is not None else conversation,
        sender=sender,
        is_from_me=me,
        timestamp=ts if ts is not None else time.time(),
        text=text,
        participants=participants,
    )


class FakeConnector(Connector):
    """Serves a fixed list of records, honouring the cursor as "records after index N"."""

    id = "chat"
    title = "Chat"

    def __init__(self, records: list[MessageRecord]):
        self.records = records

    def check(self, options):
        return CheckResult(True, "ok")

    def fetch(self, options, cursor, since, progress):
        start = int(cursor or 0)
        return FetchResult(self.records[start:], str(len(self.records)))


# MARK: - Config


def test_config_rejects_out_of_range_values_and_keeps_defaults(tmp_path: Path):
    config = MemoryConfig()
    rejected = config.apply({"index": {"top_k": 999, "backend": "faiss", "chunk_size": 512, "nope": 1}})
    assert set(rejected) == {"index.top_k", "index.backend", "index.nope"}
    assert config.index.top_k == 4 and config.index.backend == "hnsw" and config.index.chunk_size == 512


def test_config_round_trips_through_disk_with_private_permissions(tmp_path: Path):
    store = ConfigStore(tmp_path)
    config = MemoryConfig()
    config.apply({"sources": {"documents": {"enabled": True, "options": {"folder": "~/Notes"}}},
                  "privacy": {"retention_days": 30, "excluded_participants": ["Boss"]}})
    store.save(config)
    assert oct(os.stat(store.path).st_mode & 0o777) == "0o600"
    loaded = store.load()
    assert loaded.sources["documents"].enabled and loaded.sources["documents"].options["folder"] == "~/Notes"
    assert loaded.privacy.retention_days == 30 and loaded.privacy.excluded_participants == ["Boss"]


def test_config_survives_a_corrupt_file(tmp_path: Path):
    (tmp_path / "config.json").write_text("{not json")
    assert ConfigStore(tmp_path).load().index.backend == "hnsw"


# MARK: - Scrubbing


def test_scrub_redacts_secrets_and_drops_one_time_codes():
    assert scrub("Your verification code is 482913") is None
    assert scrub("Doğrulama kodu: 4829") is None
    cleaned = scrub("card 4111 1111 1111 1111 and password: hunter2 ok")
    assert "4111" not in cleaned and "hunter2" not in cleaned and "ok" in cleaned
    assert scrub("   ") is None


def test_strip_mail_quotes_keeps_only_the_new_text():
    body = "Sounds good, see you then.\n\nOn Mon, 3 Oct 2026, Ayşe wrote:\n> Shall we meet?\n> Thanks"
    assert strip_mail_quotes(body) == "Sounds good, see you then."


# MARK: - Store


def test_titles_match_without_badges_case_or_direction_marks():
    assert title_key("(3) ‎Ayşe  Yılmaz") == title_key("ayşe yılmaz")


def test_participants_never_include_the_user(tmp_path: Path):
    store = MessageStore(tmp_path / "m.sqlite")
    store.upsert([record("c1", "hello there friend", sender="Me", me=True, participants=("Ayşe",)),
                  record("c1", "hi back to you", sender="Ayşe")])
    conversation = store.conversation("chat", "c1")
    assert conversation.participants == ("ayşe",)


def test_upsert_is_idempotent_and_reindexes_edits(tmp_path: Path):
    store = MessageStore(tmp_path / "m.sqlite")
    first = record("c1", "original text here", message_id="m1")
    assert store.upsert([first]) == 1
    store.mark_indexed([first.record_id])
    assert store.upsert([first]) == 0
    edited = record("c1", "edited text here", message_id="m1")
    assert store.upsert([edited]) == 1
    assert [m.text for m in store.iter_messages("chat", only_unindexed=True)] == ["edited text here"]


def test_keyword_search_never_leaves_the_given_conversations(tmp_path: Path):
    store = MessageStore(tmp_path / "m.sqlite")
    store.upsert([record("c1", "the invoice is paid"), record("c2", "the invoice is late", sender="Can")])
    hits = store.keyword_search("invoice", [("chat", "c1")], limit=10)
    assert [h.conversation_id for h in hits] == ["c1"]


def test_purge_removes_excluded_people_and_expired_messages(tmp_path: Path):
    store = MessageStore(tmp_path / "m.sqlite")
    old = time.time() - 400 * 86400
    store.upsert([record("c1", "from the boss today", sender="Boss"), record("c2", "an old message here", ts=old),
                  record("c3", "a fresh message here")])
    removed = store.purge(excluded_conversations=[], excluded_participants=["boss"], older_than=time.time() - 365 * 86400)
    assert removed == 2
    assert [m.conversation_id for m in store.iter_messages("chat")] == ["c3"]


def test_normalize_participant_reads_mail_addresses():
    assert normalize_participant("Ayşe Yılmaz <AYSE@x.com>") == "ayse@x.com"


# MARK: - Service scope rules


def make_service(tmp_path: Path, records: list[MessageRecord]) -> MemoryService:
    service = MemoryService(tmp_path / "data", connectors={"chat": FakeConnector(records)})
    service.config.apply({"index": {"vector_weight": 0.0}, "sources": {"chat": {"enabled": True}}})
    return service


def run_sync(service: MemoryService) -> dict:
    job = service.jobs.submit("sync", "sync", lambda job: service._sync(job, ["chat"]))
    deadline = time.time() + 10
    while job.status in ("queued", "running") and time.time() < deadline:
        time.sleep(0.01)
    assert job.status == "done", job.error
    return job.result


def test_search_stays_in_the_conversation_then_the_same_person(tmp_path: Path):
    service = make_service(tmp_path, [
        record("whatsapp-ayse", "the invoice for September is paid", title="Ayşe", sender="Ayşe"),
        record("mail-ayse", "invoice attached for September", title="Invoice", sender="Ayşe"),
        record("whatsapp-can", "my invoice is still open", title="Can", sender="Can"),
    ])
    run_sync(service)

    own = service.search({"query": "invoice September", "scope": {"title": "Ayşe"}, "top_k": 1})
    assert own["scope"] == "conversation"
    assert [h["conversation_id"] for h in own["hits"]] == ["whatsapp-ayse"]

    wider = service.search({"query": "invoice September", "scope": {"title": "Ayşe"}, "top_k": 3})
    assert wider["scope"] == "person"
    assert {h["conversation_id"] for h in wider["hits"]} == {"whatsapp-ayse", "mail-ayse"}


def test_an_unknown_conversation_returns_nothing_rather_than_global_results(tmp_path: Path):
    service = make_service(tmp_path, [record("c1", "the invoice is paid", title="Ayşe")])
    run_sync(service)
    result = service.search({"query": "invoice", "scope": {"title": "Someone Else"}})
    assert result == {**result, "scope": "none", "hits": []}


def test_disabled_sources_are_never_searched(tmp_path: Path):
    service = make_service(tmp_path, [record("c1", "the invoice is paid", title="Ayşe")])
    run_sync(service)
    service.sources_configure({"id": "chat", "enabled": False})
    assert service.search({"query": "invoice", "scope": {"title": "Ayşe"}})["hits"] == []


def test_sync_drops_secrets_and_excluded_conversations(tmp_path: Path):
    service = make_service(tmp_path, [
        record("c1", "your code is 123456 for login", title="Bank"),
        record("c2", "meeting notes for tomorrow", title="Private"),
        record("c3", "lunch on friday at noon", title="Ayşe"),
    ])
    service.config.apply({"privacy": {"excluded_conversations": ["c2"]}})
    summary = run_sync(service)
    assert summary["chat"]["dropped"] == 2 and summary["chat"]["stored"] == 1
    assert service.store.cursor("chat") == "3"


def test_unknown_source_is_a_request_error(tmp_path: Path):
    service = make_service(tmp_path, [])
    with pytest.raises(RequestError):
        service.sources_sync({"id": "nope"})


# MARK: - Documents source


def test_documents_connector_reads_paragraphs_and_resumes_from_its_cursor(tmp_path: Path):
    folder = tmp_path / "notes"
    folder.mkdir()
    (folder / "pricing.md").write_text("Imperum POC pricing is 4000 EUR per month.\n\nshort\n\nSupport is included for 30 days.")
    connector = DocumentsConnector()
    assert connector.check({"folder": str(folder)}).ok
    first = connector.fetch({"folder": str(folder)}, None, None, lambda *_: None)
    assert [r.text for r in first.records] == ["Imperum POC pricing is 4000 EUR per month.",
                                               "Support is included for 30 days."]
    again = connector.fetch({"folder": str(folder)}, first.cursor, None, lambda *_: None)
    assert again.records == []
