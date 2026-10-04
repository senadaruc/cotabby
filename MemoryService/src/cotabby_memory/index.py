"""Keeps one LEANN index in step with the message store, and answers scoped searches.

Why one index for every source: each loaded LEANN searcher keeps its own embedding model and
helper process, and searching one index is one round trip. The source is metadata on every
passage, so per-source views are filters, not separate indexes.

How the index stays current:
- New messages are appended with `LeannBuilder.update_index` (HNSW, non-compact storage).
- A full rebuild happens when nothing has been built yet, when the build settings changed (a new
  embedding model or chunking), or when messages were deleted or edited (exclusions, retention,
  a source removed), because LEANN's HNSW backend cannot remove passages.
- Rebuilds reuse embeddings (`EmbeddingCache`): every passage's vector is kept, keyed by an HMAC of
  its id and text, so a rebuild embeds only passages it has not seen and then builds the graph
  from precomputed vectors. Embedding is what takes the time (a mailbox is tens of minutes);
  graph construction takes seconds. The cache is written as the embedding progresses, so a
  rebuild interrupted by a restart resumes where it stopped.

What LEANN keeps on disk: only embeddings and ids. A rebuild hands LEANN the vectors and empty
passage text, so no message text is written at all; (Embeddings are not encrypted, since LEANN
memory-maps them; published inversion attacks can partially reconstruct text from embeddings, so
the index folder is still protected by 0700 permissions and FileVault rather than relied on as
ciphertext.) LEANN writes each passage's text into
`*.passages.jsonl` and a plaintext keyword index into `*.bm25.sqlite`; after every build and
append, `redact_passages` blanks the text, rewrites the offset table, and deletes the keyword
index (search uses vector similarity only at the LEANN level; keyword matching runs on the
encrypted store). Passage metadata carries ids, the source and the conversation's HMAC key, never
names or text, so the index directory holds nothing readable about the messages.

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
import os
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
    # Passages embedded per call during a rebuild: small enough to report progress and save the
    # cache often, large enough to keep the GPU busy.
    EMBED_BATCH = 256
    # Seconds between cache saves during a long rebuild.
    CACHE_SAVE_INTERVAL = 60
    # LEANN post-filters, so a scoped vector search asks for this many neighbours before filtering.
    SCOPED_OVERFETCH = 300
    # An append embeds inside the lock that searches also take, so only small deltas are appended;
    # larger ones (a first sync of a mailbox, tens of thousands of messages) rebuild in a side
    # folder while searches keep using the current index. Measured: about 50 messages a second.
    APPEND_LIMIT = 500

    def __init__(self, data_dir: Path, store: MessageStore):
        self.root = data_dir / "indexes"
        self.root.mkdir(parents=True, exist_ok=True)
        self.store = store
        self._lock = threading.RLock()
        self._searcher = None
        self._searcher_config: IndexConfig | None = None
        self._state_path = self.root / "state.json"
        self._clean_up_after_interruption()

    def _clean_up_after_interruption(self) -> None:
        """LEANN writes passage text and a plaintext keyword index before `redact_passages` runs.
        If the service stopped in between (a crash, a force quit mid-build), that text would stay
        on disk, so every start removes half-finished build folders and redacts the live index
        again (a no-op when it is already clean)."""
        for leftover in ("building", "previous"):
            _remove_tree(self.root / leftover)
        if self.index_path.with_name(self.INDEX_NAME + ".meta.json").exists():
            try:
                redact_passages(self.index_path)
            except Exception:  # noqa: BLE001 - a damaged index is rebuilt rather than blocking startup
                log.exception("could not redact the index; marking it for rebuild")
                self.mark_needs_rebuild("index files were damaged")

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
        if len(pending) > self.APPEND_LIMIT:
            return self._rebuild(config, sources, report)
        report(0.1, f"Adding {len(pending)} new messages")
        builder = self._builder(config)
        added = sum(self._add(builder, message, config) for message in pending)
        # `update_index` rewrites the live index files in place, so no search may read them
        # meanwhile. Appends are deltas since the last sync, so this hold is short.
        with self._lock:
            self._drop_searcher()
            builder.update_index(str(self.index_path))
            redact_passages(self.index_path)
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
            chunks = [chunk for message in messages for chunk in self._chunks(message, config)]
            vectors = self._embed(chunks, config, report)
            report(0.9, "Building the search graph")
            builder = self._builder(config)
            for _, _, metadata in chunks:
                # No text: the vectors are already computed, so LEANN has nothing to embed and
                # writes no message text into the build folder.
                builder.add_text("", metadata=metadata)
            builder.build_index_from_arrays(str(target / self.INDEX_NAME), [c[0] for c in chunks], vectors)
            redact_passages(target / self.INDEX_NAME)
            passages = len(chunks)
        else:
            # Nothing left to index (every source forgotten or off): no vector may outlive it.
            _remove_tree(self.root / EmbeddingCache.FOLDER)
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
            for name in ("current", "building", "previous", EmbeddingCache.FOLDER):
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

    def _embed(self, chunks: list[tuple[str, str, dict]], config: IndexConfig, report: ProgressCallback):
        """The vectors for `chunks`, in order: cached ones reused, the rest embedded in batches
        with progress, the cache saved as it grows and pruned to these chunks at the end (so a
        deleted message's vector does not outlive it)."""
        import numpy as np
        from leann.api import compute_embeddings

        cache = EmbeddingCache(self.root, config, self.store.vault)
        known = cache.load()
        keys = [cache.key(passage_id, text) for passage_id, text, _ in chunks]
        missing = [i for i, key in enumerate(keys) if key not in known]
        reused = len(chunks) - len(missing)
        report(0.05, f"Embedding {len(missing)} passages ({reused} reused)" if reused else f"Embedding {len(missing)} passages")
        last_save = time.monotonic()
        for start in range(0, len(missing), self.EMBED_BATCH):
            group = missing[start : start + self.EMBED_BATCH]
            vectors = compute_embeddings([chunks[i][1] for i in group], config.embedding_model,
                                         config.embedding_mode, use_server=False, is_build=True)
            for i, vector in zip(group, vectors):
                known[keys[i]] = np.asarray(vector, dtype=np.float32)
            done = start + len(group)
            report(0.05 + 0.85 * done / len(missing), f"Embedded {done} of {len(missing)} passages")
            if time.monotonic() - last_save > self.CACHE_SAVE_INTERVAL:
                cache.save(known)
                last_save = time.monotonic()
        wanted = set(keys)
        cache.save({key: vector for key, vector in known.items() if key in wanted})
        return np.stack([known[key] for key in keys]).astype(np.float32)

    @staticmethod
    def _chunks(message: StoredMessage, config: IndexConfig) -> list[tuple[str, str, dict]]:
        """One message as (passage id, text, metadata) passages; long mails are chunked by words
        with overlap. Every chunk carries the message's metadata, so filters and the store lookup
        work on any chunk."""
        metadata = {
            "record_id": message.record_id,
            "source": message.source,
            "conversation_key": message.conversation_key,
            "timestamp": message.timestamp,
        }
        chunks = chunk_words(message.as_record().passage_text(), config.chunk_size, config.chunk_overlap)
        result = []
        for index, chunk in enumerate(chunks):
            passage_id = message.record_id if index == 0 else f"{message.record_id}#{index}"
            result.append((passage_id, chunk, {**metadata, "id": passage_id}))
        return result

    @classmethod
    def _add(cls, builder, message: StoredMessage, config: IndexConfig) -> int:
        """Adds one message's passages to an append. LEANN embeds them in memory and writes their
        text into the live index, which `redact_passages` blanks right after."""
        chunks = cls._chunks(message, config)
        for _, text, metadata in chunks:
            builder.add_text(text, metadata=metadata)
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
                allowed_keys: set[tuple[str, str]] | None = None
                if conversations is not None:
                    if not conversations:
                        return []
                    allowed_keys = {(s, self.store.conversation_key(s, c)) for s, c in conversations}
                    filters = {"conversation_key": {"in": sorted({k for _, k in allowed_keys})}}
                    fetch = self.SCOPED_OVERFETCH
                try:
                    results = searcher.search(
                        query, top_k=fetch, complexity=max(config.search_complexity, fetch),
                        metadata_filters=filters,
                    )
                except Exception:  # noqa: BLE001 - a broken index must not break suggestions
                    log.exception("vector search failed")
                    results = []
                seen: set[str] = set()
                for result in results:
                    record_id = result.metadata.get("record_id") or result.metadata.get("id") or result.id
                    pair = (result.metadata.get("source"), result.metadata.get("conversation_key"))
                    if record_id in seen or (allowed_keys is not None and pair not in allowed_keys):
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


def redact_passages(index_path: Path) -> None:
    """Removes message text from LEANN's on-disk files for the index at `index_path`.

    LEANN stores each passage as a JSON line `{"id", "text", "metadata"}` in `<name>.passages.jsonl`
    with a pickled id -> byte-offset table in `<name>.passages.idx`, and a plaintext FTS5 keyword
    index in `<name>.bm25.sqlite`. The text is rewritten as empty and the offsets recomputed (so
    LEANN's own lookups and later appends keep working); the keyword index is deleted.
    """
    import json
    import pickle

    passages = index_path.with_name(index_path.name + ".passages.jsonl")
    offsets_file = index_path.with_name(index_path.name + ".passages.idx")
    if passages.exists():
        redacted = passages.with_name(passages.name + ".redacting")
        offsets: dict[str, int] = {}
        with passages.open("r", encoding="utf-8") as source, redacted.open("w", encoding="utf-8") as target:
            for line in source:
                if not line.strip():
                    continue
                entry = json.loads(line)
                entry["text"] = ""
                offsets[entry["id"]] = target.tell()
                target.write(json.dumps(entry, ensure_ascii=False) + "\n")
        os.replace(redacted, passages)
        with offsets_file.open("wb") as handle:
            pickle.dump(offsets, handle)
    for keyword_index in index_path.parent.glob(index_path.name + ".bm25.sqlite*"):
        keyword_index.unlink(missing_ok=True)


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


class EmbeddingCache:
    """Every indexed passage's vector, so rebuilds embed only what is new.

    Keys are HMAC tags of the passage id and its exact text (`Vault.tag`): an edited message gets
    a new key, and the file holds no ids or text anyone could read. One cache per embedding model
    and mode; a different model's vectors are never mixed in. Vectors are as private as LEANN's
    own index (which stores the same vectors), so the cache lives beside it under `indexes/`, is
    written with 0600 permissions, and is deleted with the index.
    """

    FOLDER = "embedding-cache"

    def __init__(self, root: Path, config: IndexConfig, vault):
        model = hashlib.sha1(json.dumps([config.embedding_mode, config.embedding_model]).encode()).hexdigest()[:16]
        self.directory = root / self.FOLDER
        self.vectors_path = self.directory / f"{model}.npy"
        self.keys_path = self.directory / f"{model}.keys.json"
        self._vault = vault

    def key(self, passage_id: str, text: str) -> str:
        return self._vault.tag(f"emb\x1f{passage_id}\x1f{text}")

    def load(self) -> dict:
        import numpy as np

        try:
            keys = json.loads(self.keys_path.read_text(encoding="utf-8"))
            vectors = np.load(self.vectors_path)
        except (FileNotFoundError, ValueError, OSError):
            return {}
        if len(keys) != len(vectors):
            log.warning("embedding cache is inconsistent; ignoring it")
            return {}
        return dict(zip(keys, vectors))

    def save(self, entries: dict) -> None:
        """Atomic: both files are written beside the old ones and renamed into place, keys last,
        so a reader never pairs new vectors with old keys (a mismatch is detected and ignored)."""
        import numpy as np

        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        keys = list(entries)
        vectors = np.stack([entries[k] for k in keys]).astype(np.float32) if keys else np.zeros((0, 0), np.float32)
        vectors_tmp = self.vectors_path.with_name(self.vectors_path.name + ".tmp")
        keys_tmp = self.keys_path.with_name(self.keys_path.name + ".tmp")
        with open(os.open(vectors_tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as handle:
            np.save(handle, vectors)
        with open(os.open(keys_tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as handle:
            json.dump(keys, handle)
        os.replace(vectors_tmp, self.vectors_path)
        os.replace(keys_tmp, self.keys_path)


def _remove_tree(path: Path) -> None:
    import shutil

    shutil.rmtree(path, ignore_errors=True)
