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

from .test_core import FakeConnector, record

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
    service = MemoryService(tmp_path / "data", connectors={"chat": connector})
    service.config.apply({"index": {"embedding_model": "intfloat/multilingual-e5-small",
                                    "embedding_mode": "sentence-transformers", "vector_weight": 0.7},
                          "sources": {"chat": {"enabled": True}}})

    first = wait(service, service.sources_sync({"id": "chat"}))
    assert first["index"]["mode"] == "rebuild"

    # Semantic match ("payment" never appears) inside Ayşe's chat only.
    result = service.search({"query": "was the payment made?", "scope": {"title": "Ayşe"}, "top_k": 2})
    assert result["scope"] == "conversation"
    assert result["hits"] and all(h["conversation_id"] == "ayse" for h in result["hits"])
    assert result["hits"][0]["text"].startswith("The September invoice")

    connector.records = messages + [record("ayse", "The October invoice is due next week.", title="Ayşe", sender="Ayşe")]
    second = wait(service, service.sources_sync({"id": "chat"}))
    assert second["index"] == {"mode": "append", "added": 1}
    october = service.search({"query": "October invoice due", "scope": {"title": "Ayşe"}, "top_k": 1})
    assert "October" in october["hits"][0]["text"]

    wait(service, service.sources_forget({"id": "chat"}))
    assert service.index.status(service.config.index)["built"] is False
    service.close()
