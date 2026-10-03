"""Keeps one LEANN index in step with the message store, and answers scoped searches.

Why one index for every source: each loaded LEANN searcher keeps its own embedding model and
helper process, and searching one index is one round trip. The source is metadata on every
passage, so per-source views are filters, not separate indexes.

How the index stays current:
- New messages are appended with `LeannBuilder.update_index` (HNSW, non-compact storage).
- A full rebuild happens when nothing has been built yet, when the build settings changed (a new
  embedding model or chunking), or when messages were deleted or edited (exclusions, retention,
  a source removed), because LEANN's HNSW backend cannot remove passages.

How a scoped search works: LEANN applies metadata filters after picking its nearest neighbours,
so a filter on one conversation can come back nearly empty. The search therefore over-fetches
from LEANN and filters, and fuses that with the store's FTS5 keyword search, which filters first
and also covers messages that arrived after the last build. Results never include a message
outside the requested conversations, whichever path found it.
"""

from __future__ import annotations

import hashlib
import json
import logging
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from .config import IndexConfig
from .store import MessageStore, StoredMessage

log = logging.getLogger("cotabby_memory.index")

ProgressCallback = Callable[[float, str], None]


@dataclass(frozen=True)
class SearchHit:
    message: StoredMessage
    score: float
    via: str  # "vector", "keyword" or "both"


class IndexManager:
    """Owns `indexes/memory.leann` and the searcher over it. Thread-safe: builds and searches are
    serialized against each other, but searches never wait on a build for longer than it takes to
    swap the searcher (a build writes to a temporary directory first)."""

    INDEX_NAME = "memory.leann"
    # LEANN post-filters, so a scoped vector search asks for this many neighbours before filtering.
    SCOPED_OVERFETCH = 300

    def __init__(self, data_dir: Path, store: MessageStore):
        self.root = data_dir / "indexes"
        self.root.mkdir(parents=True, exist_ok=True)
        self.store = store
        self._lock = threading.RLock()
        self._searcher = None
        self._searcher_config: IndexConfig | None = None
        self._state_path = self.root / "state.json"

    @property
    def index_path(self) -> Path:
        return self.root / "current" / self.INDEX_NAME

    # MARK: - State

    def _state(self) -> dict:
        try:
            return json.loads(self._state_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def _write_state(self, state: dict) -> None:
        self._state_path.write_text(json.dumps(state, indent=2), encoding="utf-8")

    @staticmethod
    def fingerprint(config: IndexConfig) -> str:
        """What a built index depends on. Search-time settings (top-k, complexity, weights) are
        left out: changing them needs no rebuild."""
        parts = [config.backend, config.embedding_mode, config.embedding_model, config.chunk_size,
                 config.chunk_overlap, config.graph_degree, config.build_complexity, config.recompute,
                 config.compact]
        return hashlib.sha1(json.dumps(parts).encode()).hexdigest()[:16]

    def mark_needs_rebuild(self, reason: str) -> None:
        with self._lock:
            state = self._state()
            state["needs_rebuild"] = reason
            self._write_state(state)

    def status(self, config: IndexConfig) -> dict:
        state = self._state()
        built = self.index_path.with_name(self.INDEX_NAME + ".meta.json").exists()
        size = sum(p.stat().st_size for p in self.index_path.parent.glob("*") if p.is_file()) if built else 0
        return {
            "built": built,
            "built_at": state.get("built_at"),
            "passages": state.get("passages", 0),
            "size_bytes": size,
            "needs_rebuild": state.get("needs_rebuild")
            or (built and state.get("fingerprint") != self.fingerprint(config) and "settings changed")
            or None,
        }

    # MARK: - Building

    def sync(self, config: IndexConfig, sources: list[str], progress: ProgressCallback | None = None) -> dict:
        """Brings the index up to date with the store for `sources`: append when possible,
        rebuild when required. Returns a summary for the job log. Builds are serialized by the
        job queue; this method only takes the lock where it touches the live index."""
        report = progress or (lambda fraction, message: None)
        if config.vector_weight <= 0:
            # Keyword-only mode: search uses the store's FTS index, so LEANN (and its embedding
            # model) is never loaded. Messages stay unindexed, so raising the weight later builds
            # the vector index from everything.
            return {"mode": "keyword-only", "added": 0}
        state = self._state()
        built = self.index_path.with_name(self.INDEX_NAME + ".meta.json").exists()
        can_append = (
            built
            and not state.get("needs_rebuild")
            and state.get("fingerprint") == self.fingerprint(config)
            and config.backend == "hnsw"
            and not config.compact
        )
        if not can_append:
            return self._rebuild(config, sources, report)
        pending = [m for source in sources for m in self.store.iter_messages(source, only_unindexed=True)]
        if not pending:
            return {"mode": "none", "added": 0}
        report(0.1, f"Adding {len(pending)} new messages")
        builder = self._builder(config)
        added = sum(self._add(builder, message, config) for message in pending)
        # `update_index` rewrites the live index files in place, so no search may read them
        # meanwhile. Appends are deltas since the last sync, so this hold is short.
        with self._lock:
            self._drop_searcher()
            builder.update_index(str(self.index_path))
            state = self._state()
            state["passages"] = state.get("passages", 0) + added
            state["built_at"] = time.time()
            self._write_state(state)
        self.store.mark_indexed(m.record_id for m in pending)
        report(1.0, "Index updated")
        return {"mode": "append", "added": len(pending)}

    def _rebuild(self, config: IndexConfig, sources: list[str], report: ProgressCallback) -> dict:
        """Builds a fresh index in `building/` while searches keep using the current one, then
        swaps it in under the lock with two renames."""
        messages = [m for source in sources for m in self.store.iter_messages(source)]
        target = self.root / "building"
        _remove_tree(target)
        target.mkdir(parents=True)
        passages = 0
        if messages:
            report(0.05, f"Embedding {len(messages)} messages")
            builder = self._builder(config)
            for message in messages:
                passages += self._add(builder, message, config)
            builder.build_index(str(target / self.INDEX_NAME))
        report(0.95, "Swapping in the new index")
        with self._lock:
            self._drop_searcher()
            old = self.root / "previous"
            _remove_tree(old)
            if self.index_path.parent.exists():
                self.index_path.parent.rename(old)
            if messages:
                target.rename(self.index_path.parent)
            else:
                _remove_tree(target)
            _remove_tree(old)
            self._write_state({"fingerprint": self.fingerprint(config), "passages": passages,
                               "built_at": time.time()})
        for source in sources:
            self.store.mark_source_unindexed(source)
        self.store.mark_indexed(m.record_id for m in messages)
        report(1.0, "Index rebuilt")
        return {"mode": "rebuild", "added": len(messages)}

    def remove(self) -> None:
        with self._lock:
            self._drop_searcher()
            for name in ("current", "building", "previous"):
                _remove_tree(self.root / name)
            self._state_path.unlink(missing_ok=True)

    def _builder(self, config: IndexConfig):
        from leann import LeannBuilder

        return LeannBuilder(
            backend_name=config.backend,
            embedding_model=config.embedding_model,
            embedding_mode=config.embedding_mode,
            is_recompute=config.recompute,
            is_compact=config.compact,
            M=config.graph_degree,
            efConstruction=config.build_complexity,
        )

    @staticmethod
    def _add(builder, message: StoredMessage, config: IndexConfig) -> int:
        """Adds one message as one or more passages (long mails are chunked by words with
        overlap). Every chunk carries the message's metadata, so filters and the store lookup work
        on any chunk."""
        record = message.as_record()
        metadata = record.metadata()
        metadata["id"] = message.record_id
        chunks = chunk_words(record.passage_text(), config.chunk_size, config.chunk_overlap)
        for index, chunk in enumerate(chunks):
            chunk_metadata = dict(metadata)
            chunk_metadata["id"] = message.record_id if index == 0 else f"{message.record_id}#{index}"
            chunk_metadata["record_id"] = message.record_id
            builder.add_text(chunk, metadata=chunk_metadata)
        return len(chunks)

    # MARK: - Searching

    def _searcher_for(self, config: IndexConfig):
        if not self.index_path.with_name(self.INDEX_NAME + ".meta.json").exists():
            return None
        if self._searcher is None or self._searcher_config != config:
            from leann import LeannSearcher

            self._drop_searcher()
            self._searcher = LeannSearcher(str(self.index_path), recompute_embeddings=config.recompute)
            self._searcher_config = config
        return self._searcher

    def _drop_searcher(self) -> None:
        if self._searcher is not None:
            try:
                self._searcher.cleanup()
            except Exception:  # noqa: BLE001 - cleanup must never fail a build
                log.exception("searcher cleanup failed")
        self._searcher = None
        self._searcher_config = None

    def warm(self, config: IndexConfig) -> None:
        """Loads the searcher and the embedding model before the first real query needs them."""
        with self._lock:
            searcher = self._searcher_for(config)
            if searcher is not None:
                searcher.search("warm up", top_k=1)

    def search(self, query: str, config: IndexConfig, *, conversations: list[tuple[str, str]] | None,
               top_k: int) -> list[SearchHit]:
        """Hybrid search. With `conversations`, only messages from those (source, conversation)
        pairs are returned; with None the whole memory is searched (the Playground)."""
        query = query.strip()
        if not query:
            return []
        vector_ranked: list[str] = []
        with self._lock:
            searcher = self._searcher_for(config)
            if searcher is not None and config.vector_weight > 0:
                filters = None
                fetch = top_k * 3
                if conversations is not None:
                    if not conversations:
                        return []
                    filters = {"conversation_id": {"in": sorted({c for _, c in conversations})}}
                    fetch = self.SCOPED_OVERFETCH
                try:
                    results = searcher.search(
                        query, top_k=fetch, complexity=max(config.search_complexity, fetch),
                        metadata_filters=filters,
                    )
                except Exception:  # noqa: BLE001 - a broken index must not break suggestions
                    log.exception("vector search failed")
                    results = []
                allowed = set(conversations) if conversations is not None else None
                seen: set[str] = set()
                for result in results:
                    record_id = result.metadata.get("record_id") or result.metadata.get("id") or result.id
                    pair = (result.metadata.get("source"), result.metadata.get("conversation_id"))
                    if record_id in seen or (allowed is not None and pair not in allowed):
                        continue
                    seen.add(record_id)
                    vector_ranked.append(record_id)

        keyword_ranked: list[str] = []
        if config.vector_weight < 1:
            scope = conversations if conversations is not None else None
            if scope is None:
                keyword_hits = []  # Global keyword search is the Playground's job via LEANN's BM25.
            else:
                keyword_hits = self.store.keyword_search(query, scope, limit=top_k * 3)
            keyword_ranked = [m.record_id for m in keyword_hits]

        fused = reciprocal_rank_fusion(vector_ranked, keyword_ranked, config.vector_weight)
        hits: list[SearchHit] = []
        for record_id, score in fused[:top_k]:
            message = self.store.message(record_id)
            if message is None:
                continue  # Deleted since the index was built.
            if conversations is not None and (message.source, message.conversation_id) not in set(conversations):
                continue
            via = "both" if record_id in vector_ranked and record_id in keyword_ranked else (
                "vector" if record_id in vector_ranked else "keyword"
            )
            hits.append(SearchHit(message, score, via))
        return hits


def chunk_words(text: str, size: int, overlap: int) -> list[str]:
    """Splits text into windows of `size` words overlapping by `overlap`. Chat messages are
    almost always one chunk; long mails become several."""
    words = text.split()
    if len(words) <= size:
        return [text]
    step = max(1, size - min(overlap, size - 1))
    return [" ".join(words[start : start + size]) for start in range(0, len(words), step)
            if words[start : start + size]]


def reciprocal_rank_fusion(vector: list[str], keyword: list[str], vector_weight: float,
                           k: int = 60) -> list[tuple[str, float]]:
    """Weighted reciprocal rank fusion: robust to the two lists' incomparable score scales."""
    scores: dict[str, float] = {}
    for rank, item in enumerate(vector):
        scores[item] = scores.get(item, 0.0) + vector_weight / (k + rank + 1)
    for rank, item in enumerate(keyword):
        scores[item] = scores.get(item, 0.0) + (1 - vector_weight) / (k + rank + 1)
    return sorted(scores.items(), key=lambda pair: pair[1], reverse=True)


def _remove_tree(path: Path) -> None:
    import shutil

    shutil.rmtree(path, ignore_errors=True)
