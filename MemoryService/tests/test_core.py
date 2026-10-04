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
from cotabby_memory.vault import KeyMismatch, Vault

KEY = bytes(range(32))


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


def test_titles_match_without_badges_case_direction_marks_or_reply_prefixes():
    assert title_key("(3) \u200eAyşe  Yılmaz") == title_key("ayşe yılmaz")
    assert title_key("Re: Fwd: POC results") == title_key("POC results") == title_key("YNT: POC results")


def test_participants_never_include_the_user(tmp_path: Path):
    store = MessageStore(tmp_path / "m.sqlite", Vault(KEY))
    store.upsert([record("c1", "hello there friend", sender="Me", me=True, participants=("Ayşe",)),
                  record("c1", "hi back to you", sender="Ayşe")])
    conversation = store.conversation("chat", "c1")
    assert conversation.participants == ("ayşe",)


def test_upsert_is_idempotent_and_reindexes_edits(tmp_path: Path):
    store = MessageStore(tmp_path / "m.sqlite", Vault(KEY))
    first = record("c1", "original text here", message_id="m1")
    assert store.upsert([first]) == 1
    store.mark_indexed([first.record_id])
    assert store.upsert([first]) == 0
    edited = record("c1", "edited text here", message_id="m1")
    assert store.upsert([edited]) == 1
    assert [m.text for m in store.iter_messages("chat", only_unindexed=True)] == ["edited text here"]


def test_keyword_search_never_leaves_the_given_conversations(tmp_path: Path):
    store = MessageStore(tmp_path / "m.sqlite", Vault(KEY))
    store.upsert([record("c1", "the invoice is paid"), record("c2", "the invoice is late", sender="Can")])
    hits = store.keyword_search("invoice", [("chat", "c1")], limit=10)
    assert [h.conversation_id for h in hits] == ["c1"]


def test_purge_removes_excluded_people_and_expired_messages(tmp_path: Path):
    store = MessageStore(tmp_path / "m.sqlite", Vault(KEY))
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
    service = MemoryService(tmp_path / "data", KEY, connectors={"chat": FakeConnector(records)})
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

    own = service.search({"query": "invoice September", "scope": {"title": "Ayşe", "sources": ["chat"]}, "top_k": 1})
    assert own["scope"] == "conversation"
    assert [h["conversation_id"] for h in own["hits"]] == ["whatsapp-ayse"]

    wider = service.search({"query": "invoice September", "scope": {"title": "Ayşe", "sources": ["chat"]}, "top_k": 3})
    assert wider["scope"] == "person"
    assert {h["conversation_id"] for h in wider["hits"]} == {"whatsapp-ayse", "mail-ayse"}


def test_a_group_chat_never_draws_on_a_members_private_chat(tmp_path: Path):
    """Writing to Ali and Can together must not surface what Ali said to the user alone: Can was
    not there. Writing to Ali alone may draw on the group, because Ali was in it."""
    service = make_service(tmp_path, [
        record("group", "the budget for the trip is fixed", title="Trip", sender="Ali", participants=("Ali", "Can")),
        record("ali", "the budget for my private project is secret", title="Ali", sender="Ali"),
    ])
    run_sync(service)

    in_group = service.search({"query": "budget", "scope": {"title": "Trip", "sources": ["chat"]}, "top_k": 5})
    assert {h["conversation_id"] for h in in_group["hits"]} == {"group"}

    with_ali = service.search({"query": "budget", "scope": {"title": "Ali", "sources": ["chat"]}, "top_k": 5})
    assert with_ali["scope"] == "person"
    assert {h["conversation_id"] for h in with_ali["hits"]} == {"ali", "group"}


def test_a_title_without_the_apps_sources_resolves_nothing(tmp_path: Path):
    service = make_service(tmp_path, [record("c1", "the invoice is paid", title="Ayşe")])
    run_sync(service)
    assert service.search({"query": "invoice", "scope": {"title": "Ayşe"}})["scope"] == "none"


def test_an_unknown_conversation_returns_nothing_rather_than_global_results(tmp_path: Path):
    service = make_service(tmp_path, [record("c1", "the invoice is paid", title="Ayşe")])
    run_sync(service)
    result = service.search({"query": "invoice", "scope": {"title": "Someone Else", "sources": ["chat"]}})
    assert result == {**result, "scope": "none", "hits": []}


def test_disabled_sources_are_never_searched(tmp_path: Path):
    service = make_service(tmp_path, [record("c1", "the invoice is paid", title="Ayşe")])
    run_sync(service)
    service.sources_configure({"id": "chat", "enabled": False})
    assert service.search({"query": "invoice", "scope": {"title": "Ayşe", "sources": ["chat"]}})["hits"] == []


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


# MARK: - Encryption at rest


def test_nothing_personal_is_readable_from_the_data_folder(tmp_path: Path):
    marker = "Zyxwvut-secret-plan"
    service = make_service(tmp_path, [
        record("whatsapp-ayse", f"the {marker} is ready", title="Ayşe Yılmaz", sender="Ayşe Yılmaz",
               participants=("ayse@example.com",)),
    ])
    run_sync(service)
    assert service.search({"query": marker, "scope": {"title": "Ayşe Yılmaz", "sources": ["chat"]}})["hits"]
    service.close()
    for path in (tmp_path / "data").rglob("*"):
        if path.is_file():
            data = path.read_bytes()
            for secret in (marker, "Ayşe", "ayse@example.com", "whatsapp-ayse"):
                assert secret.encode() not in data, f"{secret!r} readable in {path.name}"


def test_a_store_opened_with_another_key_is_refused(tmp_path: Path):
    MessageStore(tmp_path / "m.sqlite", Vault(KEY)).close()
    with pytest.raises(KeyMismatch):
        MessageStore(tmp_path / "m.sqlite", Vault(bytes(32)))


def test_keyword_search_matches_word_prefixes(tmp_path: Path):
    store = MessageStore(tmp_path / "m.sqlite", Vault(KEY))
    store.upsert([record("c1", "the invoice is paid"), record("c1", "lunch tomorrow")])
    assert [m.text for m in store.keyword_search("invo", [("chat", "c1")], limit=5)] == ["the invoice is paid"]


def test_migrating_a_plaintext_store_leaves_no_plaintext_in_the_file(tmp_path: Path):
    """A schema-1 (plaintext) store is dropped on upgrade; its pages must not linger in the file."""
    import sqlite3

    path = tmp_path / "m.sqlite"
    old = sqlite3.connect(path)
    old.execute("PRAGMA journal_mode = WAL")
    old.execute("CREATE TABLE messages (record_id TEXT PRIMARY KEY, text TEXT)")
    old.executemany("INSERT INTO messages VALUES (?, ?)", [(str(i), f"Plaintext-marker-{i} " * 20) for i in range(200)])
    old.commit()
    old.close()
    MessageStore(path, Vault(KEY)).close()
    for file in tmp_path.iterdir():
        assert b"Plaintext-marker" not in file.read_bytes(), file.name


def test_an_interrupted_build_leaves_no_plaintext_behind(tmp_path: Path):
    """Text LEANN wrote before redaction (a crash mid-build) is removed on the next start."""
    from cotabby_memory.index import IndexManager

    store = MessageStore(tmp_path / "m.sqlite", Vault(KEY))
    building = tmp_path / "indexes" / "building"
    building.mkdir(parents=True)
    (building / "memory.leann.passages.jsonl").write_text('{"id": "1", "text": "Leaked-marker", "metadata": {}}\n')
    IndexManager(tmp_path, store)
    assert not building.exists()


# MARK: - Records pushed by Cotabby


def pushed_service(tmp_path: Path) -> MemoryService:
    service = MemoryService(tmp_path / "data", KEY)
    service.config.apply({"index": {"vector_weight": 0.0}, "sources": {"whatsapp": {"enabled": True}}})
    return service


def test_ingested_records_pass_the_same_pipeline_and_become_searchable(tmp_path: Path):
    service = pushed_service(tmp_path)
    result = service.records_ingest({
        "source": "whatsapp",
        "cursor": "42",
        "records": [
            {"source_message_id": "1", "conversation_id": "905551112233@s.whatsapp.net", "conversation_title": "Ayşe",
             "sender": "Ayşe", "is_from_me": False, "timestamp": time.time(), "text": "the invoice is paid",
             "participants": ["905551112233@s.whatsapp.net"]},
            {"source_message_id": "2", "conversation_id": "905551112233@s.whatsapp.net", "conversation_title": "Ayşe",
             "sender": "Ayşe", "is_from_me": False, "timestamp": time.time(), "text": "Your code is 123456"},
        ],
    })
    assert (result["stored"], result["dropped"]) == (1, 1)
    assert service.store.cursor("whatsapp") == "42"
    hits = service.search({"query": "invoice", "scope": {"title": "Ayşe", "sources": ["whatsapp"]}})["hits"]
    assert [h["text"] for h in hits] == ["the invoice is paid"]


def test_mail_records_lose_their_quoted_history(tmp_path: Path):
    service = MemoryService(tmp_path / "data", KEY)
    service.config.apply({"index": {"vector_weight": 0.0}, "sources": {"apple_mail": {"enabled": True}}})
    service.records_ingest({"source": "apple_mail", "records": [{
        "source_message_id": "9", "conversation_id": "thread-1", "conversation_title": "POC results",
        "sender": "ayse@x.com", "is_from_me": False, "timestamp": time.time(), "subject": "POC results",
        "text": "Numbers look great.\n\nOn Mon, Can wrote:\n> please send the numbers",
    }]})
    assert [m.text for m in service.store.iter_messages("apple_mail")] == ["Numbers look great."]


def test_ingest_is_refused_for_disabled_or_service_read_sources(tmp_path: Path):
    service = MemoryService(tmp_path / "data", KEY)
    with pytest.raises(RequestError) as disabled:
        service.records_ingest({"source": "whatsapp", "records": []})
    assert disabled.value.code == "source_disabled"
    with pytest.raises(RequestError) as not_pushed:
        service.records_ingest({"source": "documents", "records": []})
    assert not_pushed.value.code == "not_pushed"
    with pytest.raises(RequestError) as sync:
        service.sources_sync({"id": "whatsapp"})
    assert sync.value.code == "pushed_source"
