# Vendored: Chromium IndexedDB reader

The subset of CCL Forensics' [ccl_chromium_reader](https://github.com/cclgroupltd/ccl_chromium_reader)
(commit `ef840de30221c4d65bc96d2f4d9057e9ef2f526d`) and
[ccl_simplesnappy](https://github.com/cclgroupltd/ccl_simplesnappy)
(commit `3d085230baa8c46cf2090ebba29bf6e8eab31087`) that reads a Chromium IndexedDB folder:
LevelDB tables and logs, Snappy blocks, IndexedDB key encoding, and V8/Blink value serialization.

Used by `connectors/teams.py` to read the new Teams client's local message cache. It is vendored rather
than installed because upstream publishes it only as git dependencies, which would make the memory
service's install need git. It is pure Python with no compiled parts.

Changes from upstream: imports made package-relative (`from . import ccl_simplesnappy`,
`from .profile_folder_protocols import ...`). Nothing else. MIT licensed, see `LICENSE`.
