# cotabby-memory

Cotabby's local conversation memory service. Cotabby creates its virtual environment, starts it,
and talks to it over a Unix socket; you never run it by hand in normal use.

It reads message history (WhatsApp, Apple Mail, Microsoft 365, Slack, a documents folder, ...)
into its own SQLite store, indexes it with [LEANN](https://github.com/StarTrail-org/LEANN), and answers
retrieval queries scoped to one conversation or one person. Everything stays on the Mac.

## Development

```sh
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -e '.[dev]'
.venv/bin/python -m pytest -q                                   # fast, no model needed
COTABBY_MEMORY_LEANN_TESTS=1 .venv/bin/python -m pytest -q      # also builds real LEANN indexes
.venv/bin/python -m cotabby_memory --data-dir /tmp/cm --verbose # run the server by hand
```

Protocol: one JSON object per line over `<data-dir>/memory.sock`,
`{"id": 1, "method": "status", "params": {}}` → `{"id": 1, "result": {...}}`. See
`src/cotabby_memory/service.py` for every method.

## Defaults and why

- Embeddings: `Qwen/Qwen3-Embedding-0.6B` through sentence-transformers (multilingual; 17 ms per
  query p50 on 1k messages on an M5 Max). LEANN 0.3.8's `mlx` mode pools a causal LM's vocabulary
  logits, which does not give usable embeddings for embedding models, so it is not the default.
- No recompute: stored embeddings searched in ~17 ms versus ~2.1 s with LEANN's recompute, and
  non-compact HNSW is what allows appending new messages without a rebuild.
- LEANN filters metadata after nearest-neighbour search, so scoped searches over-fetch and are
  fused with the store's filter-first FTS5 keyword search.
