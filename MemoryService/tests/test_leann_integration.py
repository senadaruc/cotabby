"""End to end through LEANN: build, scoped vector search, append, rebuild after forgetting.

Needs the embedding model (downloaded on first use), so it only runs with
COTABBY_MEMORY_LEANN_TESTS=1. Uses the small multilingual e5 model to stay quick.
"""

from __future__ import annotations

import os
import time
from pathlib import Path

import pytest

from cotabby_memory.service import MemoryService

from .test_core import KEY, FakeConnector, record

pytestmark = pytest.mark.skipif(os.environ.get("COTABBY_MEMORY_LEANN_TESTS") != "1",
                                reason="set COTABBY_MEMORY_LEANN_TESTS=1 to build real LEANN indexes")


def wait(service: MemoryService, job: dict) -> dict:
    deadline = time.time() + 600
    while time.time() < deadline:
        current = next(j for j in service.jobs.list() if j["id"] == job["id"])
        if current["status"] not in ("queued", "running"):
            assert current["status"] == "done", current["error"]
            return current["result"]
        time.sleep(0.05)
    raise AssertionError("job timed out")


def test_vector_search_is_scoped_and_new_messages_are_appended(tmp_path: Path):
    messages = [
        record("ayse", "The September invoice was paid by bank transfer.", title="Ayşe", sender="Ayşe"),
        record("ayse", "Yarın saat üçte toplantı var.", title="Ayşe", sender="Ayşe"),
        record("can", "My invoice for September is still unpaid.", title="Can", sender="Can"),
    ]
    connector = FakeConnector(messages)
    service = MemoryService(tmp_path / "data", KEY, connectors={"chat": connector})
    service.config.apply({"index": {"embedding_model": "intfloat/multilingual-e5-small",
                                    "embedding_mode": "sentence-transformers", "vector_weight": 0.7},
                          "sources": {"chat": {"enabled": True}}})

    first = wait(service, service.sources_sync({"id": "chat"}))
    assert first["index"]["mode"] == "rebuild"

    # Semantic match ("payment" never appears) inside Ayşe's chat only.
    result = service.search({"query": "was the payment made?", "scope": {"title": "Ayşe", "sources": ["chat"]}, "top_k": 2})
    assert result["scope"] == "conversation"
    assert result["hits"] and all(h["conversation_id"] == "ayse" for h in result["hits"])
    assert result["hits"][0]["text"].startswith("The September invoice")

    connector.records = messages + [record("ayse", "The October invoice is due next week.", title="Ayşe", sender="Ayşe")]
    second = wait(service, service.sources_sync({"id": "chat"}))
    assert second["index"] == {"mode": "append", "added": 1}
    october = service.search({"query": "October invoice due", "scope": {"title": "Ayşe", "sources": ["chat"]}, "top_k": 1})
    assert "October" in october["hits"][0]["text"]

    # LEANN's files hold embeddings and ids only: no message text, names or conversation ids.
    for path in (tmp_path / "data" / "indexes").rglob("*"):
        if path.is_file():
            data = path.read_bytes()
            for secret in (b"September invoice", b"October", "Ayşe".encode(), b"ayse"):
                assert secret not in data, f"{secret!r} readable in {path.name}"

    wait(service, service.sources_forget({"id": "chat"}))
    assert service.index.status(service.config.index)["built"] is False
    service.close()


def test_a_rebuild_reuses_embeddings_and_embeds_only_what_is_new(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    import leann.api

    embedded: list[str] = []
    real = leann.api.compute_embeddings

    def counting(texts, *args, **kwargs):
        embedded.extend(texts)
        return real(texts, *args, **kwargs)

    monkeypatch.setattr(leann.api, "compute_embeddings", counting)
    messages = [
        record("ayse", "The September invoice was paid by bank transfer.", title="Ayşe", sender="Ayşe"),
        record("can", "My invoice for September is still unpaid.", title="Can", sender="Can"),
    ]
    connector = FakeConnector(messages)
    service = MemoryService(tmp_path / "data", KEY, connectors={"chat": connector})
    service.config.apply({"index": {"embedding_model": "intfloat/multilingual-e5-small",
                                    "embedding_mode": "sentence-transformers", "vector_weight": 0.7},
                          "sources": {"chat": {"enabled": True}}})
    wait(service, service.sources_sync({"id": "chat"}))
    assert len(embedded) == 2

    # A rebuild (a deletion, an exclusion) embeds nothing it has seen before.
    embedded.clear()
    wait(service, service.index_rebuild({}))
    assert embedded == []
    result = service.search({"query": "was the payment made?", "scope": {"title": "Ayşe", "sources": ["chat"]}, "top_k": 1})
    assert result["hits"][0]["text"].startswith("The September invoice")

    # An edited message is embedded again; an unchanged one is not.
    connector.records = [record("ayse", "The September invoice was paid in cash.", title="Ayşe", sender="Ayşe",
                                message_id="ayse:The September invoice was paid by bank transfer."), messages[1]]
    service.store.set_cursor("chat", "0")
    service.index.mark_needs_rebuild("test")
    wait(service, service.sources_sync({"id": "chat"}))
    assert len(embedded) == 1 and "cash" in embedded[0]

    # Forgetting everything leaves no vectors behind.
    wait(service, service.sources_forget({"id": "chat"}))
    assert not (tmp_path / "data" / "indexes" / "embedding-cache").exists()
    service.close()
