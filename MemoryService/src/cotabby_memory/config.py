"""The service's settings, as Cotabby's Memory pane edits them.

Every LEANN knob the pane exposes lives here with its default and its valid range, so the pane,
the index builder and the searcher read one source of truth. The file is JSON in the data
directory, written atomically; unknown keys are ignored and out-of-range values fall back to their
defaults, so a hand-edited or older file can never stop the service from starting.
"""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path
from typing import Any


@dataclass
class IndexConfig:
    backend: str = "hnsw"
    # Multilingual by default: the user writes English and Turkish, and LEANN's own default
    # (facebook/contriever) is English-only. Through sentence-transformers (Metal on Apple
    # Silicon), Qwen3-Embedding-0.6B measured 17 ms per query (p50) on 1k messages. LEANN 0.3.8's
    # "mlx" mode is not offered as a default: it mean-pools a causal LM's vocabulary logits, so an
    # embedding model like Qwen3-Embedding comes out as a 151,669-wide vector that is not a usable
    # embedding (607 MB for 1k messages).
    embedding_mode: str = "sentence-transformers"
    embedding_model: str = "Qwen/Qwen3-Embedding-0.6B"
    chunk_size: int = 256
    chunk_overlap: int = 32
    graph_degree: int = 32
    build_complexity: int = 64
    # Storing embeddings (no recompute) measured 17 ms per search against 2.1 s with recompute,
    # for under 5 MB per 1k messages; recompute would sit on the suggestion's critical path.
    # Non-compact storage is also what lets new messages be appended without a rebuild.
    recompute: bool = False
    compact: bool = False
    search_complexity: int = 32
    top_k: int = 4
    # 1.0 = pure vector search, 0.0 = pure keyword search.
    vector_weight: float = 0.7

    _CHOICES = {
        "backend": ("hnsw", "diskann"),
        "embedding_mode": ("mlx", "sentence-transformers", "ollama", "openai"),
    }
    _RANGES = {
        "chunk_size": (64, 2048),
        "chunk_overlap": (0, 512),
        "graph_degree": (8, 128),
        "build_complexity": (16, 512),
        "search_complexity": (8, 512),
        "top_k": (1, 20),
        "vector_weight": (0.0, 1.0),
    }


@dataclass
class SourceConfig:
    enabled: bool = False
    # Connector-specific options (a documents folder, a Graph client id, ...). Secrets are never
    # stored here: tokens live in the Keychain, owned by the connector.
    options: dict[str, Any] = field(default_factory=dict)


@dataclass
class PrivacyConfig:
    # Conversation ids and participant names never indexed (and purged when added).
    excluded_conversations: list[str] = field(default_factory=list)
    excluded_participants: list[str] = field(default_factory=list)
    # Messages older than this are not ingested (and are purged); 0 keeps everything.
    retention_days: int = 365


@dataclass
class MemoryConfig:
    index: IndexConfig = field(default_factory=IndexConfig)
    sources: dict[str, SourceConfig] = field(default_factory=dict)
    privacy: PrivacyConfig = field(default_factory=PrivacyConfig)

    def to_json(self) -> dict[str, Any]:
        return {
            "index": {f.name: getattr(self.index, f.name) for f in fields(IndexConfig)},
            "sources": {key: asdict(value) for key, value in self.sources.items()},
            "privacy": asdict(self.privacy),
        }

    @classmethod
    def from_json(cls, raw: dict[str, Any]) -> "MemoryConfig":
        config = cls()
        config.apply(raw)
        return config

    def apply(self, patch: dict[str, Any]) -> list[str]:
        """Merges a partial update (the shape `to_json` produces). Returns the keys that were
        rejected, so the pane can say which value it could not use."""
        rejected: list[str] = []
        for key, value in (patch.get("index") or {}).items():
            if not _apply_index_value(self.index, key, value):
                rejected.append(f"index.{key}")
        for source_id, source_patch in (patch.get("sources") or {}).items():
            current = self.sources.setdefault(source_id, SourceConfig())
            if "enabled" in source_patch:
                current.enabled = bool(source_patch["enabled"])
            if isinstance(source_patch.get("options"), dict):
                current.options.update(source_patch["options"])
        privacy = patch.get("privacy") or {}
        if isinstance(privacy.get("excluded_conversations"), list):
            self.privacy.excluded_conversations = [str(v) for v in privacy["excluded_conversations"]]
        if isinstance(privacy.get("excluded_participants"), list):
            self.privacy.excluded_participants = [str(v) for v in privacy["excluded_participants"]]
        if "retention_days" in privacy:
            try:
                self.privacy.retention_days = max(0, int(privacy["retention_days"]))
            except (TypeError, ValueError):
                rejected.append("privacy.retention_days")
        return rejected


def _apply_index_value(index: IndexConfig, key: str, value: Any) -> bool:
    known = {f.name: f for f in fields(IndexConfig)}
    if key not in known:
        return False
    default = getattr(IndexConfig(), key)
    try:
        if isinstance(default, bool):
            coerced: Any = bool(value)
        elif isinstance(default, int):
            coerced = int(value)
        elif isinstance(default, float):
            coerced = float(value)
        else:
            coerced = str(value)
    except (TypeError, ValueError):
        return False
    choices = IndexConfig._CHOICES.get(key)
    if choices and coerced not in choices:
        return False
    bounds = IndexConfig._RANGES.get(key)
    if bounds and not (bounds[0] <= coerced <= bounds[1]):
        return False
    setattr(index, key, coerced)
    return True


class ConfigStore:
    """Loads and saves `MemoryConfig` as `config.json` in the data directory."""

    def __init__(self, data_dir: Path):
        self.path = data_dir / "config.json"

    def load(self) -> MemoryConfig:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            return MemoryConfig()
        return MemoryConfig.from_json(raw if isinstance(raw, dict) else {})

    def save(self, config: MemoryConfig) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # Write to a temp file in the same directory and rename, so a crash mid-write never leaves
        # a truncated config behind.
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=".config.", suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(config.to_json(), handle, indent=2, ensure_ascii=False)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        except BaseException:
            Path(tmp).unlink(missing_ok=True)
            raise
