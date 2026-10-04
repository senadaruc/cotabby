"""The service's own copy of every ingested message, encrypted, in SQLite.

Why keep a copy when LEANN has an index:
- Rebuilding an index (new embedding model, new chunking) must not re-read WhatsApp, Mail, Graph
  and Slack; it reads from here.
- Scope rules need structured lookups LEANN does not offer: which conversation the title "Ayşe"
  belongs to, which conversations every current reader took part in.
- A keyword search over the same rows serves messages that arrived after the last LEANN build and
  gives exact, filter-first matches inside one conversation.
- Exclusions and retention are enforced by deleting rows here; the next build drops them from
  LEANN as well.

Encryption at rest (see `vault.py`): message text, sender, subject, conversation titles and
conversation ids are stored sealed (AES-GCM); titles, participants and conversation keys are also
stored as HMAC tags so they can be matched without plaintext. There is deliberately no SQLite FTS
index, because FTS keeps its terms in plaintext; keyword search decrypts only the messages of the
conversations in scope and scores them in memory. Nothing personal is readable from this file
without the key in Cotabby's Keychain.
"""

from __future__ import annotations

import math
import os
import re
import sqlite3
import threading
import time
from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from pathlib import Path

from .records import MessageRecord, normalize_participant
from .vault import Vault

SCHEMA_VERSION = 2

_SCHEMA = """
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS messages (
    record_id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    conv_key TEXT NOT NULL,
    sender BLOB NOT NULL,
    is_from_me INTEGER NOT NULL,
    timestamp REAL NOT NULL,
    subject BLOB,
    text BLOB NOT NULL,
    text_tag TEXT NOT NULL,
    indexed INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS messages_conversation ON messages(source, conv_key, timestamp);
CREATE INDEX IF NOT EXISTS messages_unindexed ON messages(source, indexed);
CREATE TABLE IF NOT EXISTS conversations (
    source TEXT NOT NULL,
    conv_key TEXT NOT NULL,
    conversation_id BLOB NOT NULL,
    title BLOB NOT NULL,
    title_tag TEXT NOT NULL,
    last_timestamp REAL NOT NULL DEFAULT 0,
    PRIMARY KEY (source, conv_key)
);
CREATE INDEX IF NOT EXISTS conversations_title ON conversations(title_tag);
CREATE TABLE IF NOT EXISTS participants (
    source TEXT NOT NULL,
    conv_key TEXT NOT NULL,
    participant_tag TEXT NOT NULL,
    participant BLOB NOT NULL,
    PRIMARY KEY (source, conv_key, participant_tag)
);
CREATE INDEX IF NOT EXISTS participants_tag ON participants(participant_tag);
CREATE TABLE IF NOT EXISTS cursors (
    source TEXT PRIMARY KEY,
    cursor BLOB NOT NULL,
    updated_at REAL NOT NULL
);
"""


@dataclass(frozen=True)
class StoredMessage:
    record_id: str
    source: str
    conversation_id: str
    conversation_key: str
    sender: str
    is_from_me: bool
    timestamp: float
    subject: str | None
    text: str

    def as_record(self, title: str = "") -> MessageRecord:
        return MessageRecord(
            source=self.source,
            source_message_id=self.record_id,
            conversation_id=self.conversation_id,
            conversation_title=title,
            sender=self.sender,
            is_from_me=self.is_from_me,
            timestamp=self.timestamp,
            text=self.text,
            subject=self.subject,
        )


@dataclass(frozen=True)
class Conversation:
    source: str
    conversation_id: str
    title: str
    participants: tuple[str, ...]
    last_timestamp: float


def title_key(title: str) -> str:
    """Titles are matched case- and space-insensitively, without direction marks or a leading
    unread badge ("(3) "), the same normalization Cotabby applies to window titles."""
    cleaned = re.sub(r"[‎‏‪-‮⁦-⁩]", "", title)
    cleaned = re.sub(r"^\(\d+\+?\)\s*", "", cleaned.strip())
    return " ".join(cleaned.lower().split())


class MessageStore:
    # Keyword search decrypts at most this many of a scope's most recent messages per query.
    KEYWORD_CANDIDATES = 5000

    def __init__(self, path: Path, vault: Vault):
        self.path = path
        self.vault = vault
        path.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(path.parent, 0o700)
        # One connection shared by the server's worker threads, serialized by a lock: SQLite is
        # fast enough here that a single writer is simpler than a pool and avoids lock errors.
        self._lock = threading.RLock()
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        os.chmod(path, 0o600)
        # Deleted and overwritten rows are zeroed on disk instead of lingering in free pages, so a
        # purge, an exclusion or "Delete All" actually removes the bytes.
        self._db.execute("PRAGMA secure_delete = ON")
        with self._lock:
            self._migrate()
            self._db.executescript(_SCHEMA)
            self._check_key()
        # Conversations' decrypted ids and titles, keyed by (source, conv_key). Small, and read on
        # every scoped search.
        self._conversation_cache: dict[tuple[str, str], tuple[str, str]] = {}

    def _migrate(self) -> None:
        """A store written before encryption (schema 1, plaintext columns) cannot be upgraded in
        place without decrypting nothing into something; it is dropped, and the next sync rebuilds
        it from the sources."""
        tables = {row[0] for row in self._db.execute("SELECT name FROM sqlite_master WHERE type IN ('table')")}
        if "messages" in tables:
            columns = {row[1] for row in self._db.execute("PRAGMA table_info(messages)")}
            if "conv_key" not in columns:
                for table in ("messages_fts", "messages", "conversations", "participants", "cursors"):
                    self._db.execute(f"DROP TABLE IF EXISTS {table}")
                self._db.commit()
                # The dropped plaintext pages stay in the file's free list (and the WAL) until the
                # file is rebuilt; VACUUM rewrites it and the checkpoint empties the WAL.
                self._db.execute("VACUUM")
                self._db.execute("PRAGMA wal_checkpoint(TRUNCATE)")

    def _check_key(self) -> None:
        row = self._db.execute("SELECT value FROM meta WHERE key = 'key_check'").fetchone()
        if row is None:
            with self._db:
                self._db.execute("INSERT INTO meta(key, value) VALUES ('key_check', ?)", (self.vault.check_value(),))
                self._db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('schema', ?)", (str(SCHEMA_VERSION).encode(),))
            return
        self.vault.verify(row["value"])

    def close(self) -> None:
        with self._lock:
            self._db.close()

    # MARK: - Keys

    def conversation_key(self, source: str, conversation_id: str) -> str:
        return self.vault.tag(f"conv\x1f{source}\x1f{conversation_id}")

    def _title_tag(self, title: str) -> str:
        return self.vault.tag(f"title\x1f{title_key(title)}")

    def _participant_tag(self, participant: str) -> str:
        return self.vault.tag(f"person\x1f{normalize_participant(participant)}")

    # MARK: - Writing

    def upsert(self, records: Iterable[MessageRecord]) -> int:
        """Inserts or replaces records and their conversations. Returns how many rows changed."""
        changed = 0
        with self._lock, self._db:
            for record in records:
                conv_key = self.conversation_key(record.source, record.conversation_id)
                # Unchanged messages are detected by a tag of their content, since the sealed
                # bytes differ on every write (random nonce).
                text_tag = self.vault.tag(f"msg\x1f{record.sender}\x1f{record.subject or ''}\x1f{record.text}")
                existing = self._db.execute(
                    "SELECT text_tag FROM messages WHERE record_id = ?", (record.record_id,)
                ).fetchone()
                if existing is None or existing["text_tag"] != text_tag:
                    self._db.execute(
                        """INSERT INTO messages(record_id, source, conv_key, sender, is_from_me, timestamp,
                                                subject, text, text_tag, indexed)
                           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                           ON CONFLICT(record_id) DO UPDATE SET
                             sender = excluded.sender, subject = excluded.subject, text = excluded.text,
                             text_tag = excluded.text_tag, timestamp = excluded.timestamp, indexed = 0""",
                        (
                            record.record_id,
                            record.source,
                            conv_key,
                            self.vault.seal(record.sender),
                            int(record.is_from_me),
                            record.timestamp,
                            self.vault.seal(record.subject),
                            self.vault.seal(record.text),
                            text_tag,
                        ),
                    )
                    changed += 1
                self._upsert_conversation(record, conv_key)
        return changed

    def _upsert_conversation(self, record: MessageRecord, conv_key: str) -> None:
        current = self._db.execute(
            "SELECT title, last_timestamp FROM conversations WHERE source = ? AND conv_key = ?",
            (record.source, conv_key),
        ).fetchone()
        title = record.conversation_title
        if current is None:
            self._db.execute(
                """INSERT INTO conversations(source, conv_key, conversation_id, title, title_tag, last_timestamp)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (record.source, conv_key, self.vault.seal(record.conversation_id), self.vault.seal(title),
                 self._title_tag(title), record.timestamp),
            )
        else:
            if title and self.vault.open(current["title"]) != title:
                self._db.execute(
                    "UPDATE conversations SET title = ?, title_tag = ? WHERE source = ? AND conv_key = ?",
                    (self.vault.seal(title), self._title_tag(title), record.source, conv_key),
                )
                self._conversation_cache.pop((record.source, conv_key), None)
            if record.timestamp > current["last_timestamp"]:
                self._db.execute(
                    "UPDATE conversations SET last_timestamp = ? WHERE source = ? AND conv_key = ?",
                    (record.timestamp, record.source, conv_key),
                )
        # The other people in the conversation: its listed participants plus whoever sent a
        # message that is not the user's own. The user is never a participant of their own
        # conversations, or the audience rule would match every chat.
        people = set(record.participants)
        if not record.is_from_me and record.sender:
            people.add(record.sender)
        for person in people:
            normalized = normalize_participant(person)
            if normalized:
                self._db.execute(
                    "INSERT OR IGNORE INTO participants(source, conv_key, participant_tag, participant) VALUES (?, ?, ?, ?)",
                    (record.source, conv_key, self._participant_tag(normalized), self.vault.seal(normalized)),
                )

    def mark_indexed(self, record_ids: Iterable[str]) -> None:
        with self._lock, self._db:
            self._db.executemany("UPDATE messages SET indexed = 1 WHERE record_id = ?", ((rid,) for rid in record_ids))

    def mark_source_unindexed(self, source: str) -> None:
        with self._lock, self._db:
            self._db.execute("UPDATE messages SET indexed = 0 WHERE source = ?", (source,))

    def delete_source(self, source: str) -> None:
        with self._lock, self._db:
            for table in ("messages", "conversations", "participants", "cursors"):
                self._db.execute(f"DELETE FROM {table} WHERE source = ?", (source,))
        self._conversation_cache.clear()

    def purge(self, *, excluded_conversations: Iterable[str], excluded_participants: Iterable[str],
              older_than: float | None) -> int:
        """Deletes excluded and expired messages. Returns how many were removed; the caller
        rebuilds the index so LEANN forgets them too."""
        removed = 0
        wanted_ids = set(excluded_conversations)
        with self._lock, self._db:
            if wanted_ids:
                for row in self._db.execute("SELECT source, conv_key, conversation_id FROM conversations").fetchall():
                    if self.vault.open(row["conversation_id"]) in wanted_ids:
                        removed += self._db.execute(
                            "DELETE FROM messages WHERE source = ? AND conv_key = ?", (row["source"], row["conv_key"])
                        ).rowcount
            for person in excluded_participants:
                tag = self._participant_tag(person)
                for row in self._db.execute(
                    "SELECT source, conv_key FROM participants WHERE participant_tag = ?", (tag,)
                ).fetchall():
                    removed += self._db.execute(
                        "DELETE FROM messages WHERE source = ? AND conv_key = ?", (row["source"], row["conv_key"])
                    ).rowcount
            if older_than is not None:
                removed += self._db.execute("DELETE FROM messages WHERE timestamp < ?", (older_than,)).rowcount
        return removed

    def set_cursor(self, source: str, cursor: str) -> None:
        with self._lock, self._db:
            self._db.execute(
                "INSERT INTO cursors(source, cursor, updated_at) VALUES (?, ?, ?) "
                "ON CONFLICT(source) DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at",
                (source, self.vault.seal(cursor), time.time()),
            )

    # MARK: - Reading

    def cursor(self, source: str) -> str | None:
        with self._lock:
            row = self._db.execute("SELECT cursor FROM cursors WHERE source = ?", (source,)).fetchone()
        return self.vault.open(row["cursor"]) if row else None

    def source_stats(self, source: str) -> dict[str, object]:
        with self._lock:
            row = self._db.execute(
                "SELECT COUNT(*) AS n, SUM(indexed = 0) AS pending, COUNT(DISTINCT conv_key) AS conversations, "
                "MAX(timestamp) AS newest FROM messages WHERE source = ?",
                (source,),
            ).fetchone()
            cursor_row = self._db.execute("SELECT updated_at FROM cursors WHERE source = ?", (source,)).fetchone()
        return {
            "messages": row["n"] or 0,
            "pending": row["pending"] or 0,
            "conversations": row["conversations"] or 0,
            "newest_timestamp": row["newest"],
            "last_sync": cursor_row["updated_at"] if cursor_row else None,
        }

    def iter_messages(self, source: str, *, only_unindexed: bool = False) -> Iterator[StoredMessage]:
        query = "SELECT * FROM messages WHERE source = ?" + (" AND indexed = 0" if only_unindexed else "")
        with self._lock:
            rows = self._db.execute(query + " ORDER BY timestamp", (source,)).fetchall()
        for row in rows:
            yield self._stored(row)

    def _conversation_names(self, source: str, conv_key: str) -> tuple[str, str]:
        """(conversation_id, title) for a conversation, decrypted and cached."""
        key = (source, conv_key)
        cached = self._conversation_cache.get(key)
        if cached is not None:
            return cached
        with self._lock:
            row = self._db.execute(
                "SELECT conversation_id, title FROM conversations WHERE source = ? AND conv_key = ?", key
            ).fetchone()
        names = (self.vault.open(row["conversation_id"]), self.vault.open(row["title"])) if row else ("", "")
        self._conversation_cache[key] = names
        return names

    def _conversation_by_key(self, source: str, conv_key: str) -> Conversation | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM conversations WHERE source = ? AND conv_key = ?", (source, conv_key)
            ).fetchone()
            if not row:
                return None
            people = self._db.execute(
                "SELECT participant FROM participants WHERE source = ? AND conv_key = ?", (source, conv_key)
            ).fetchall()
        conversation_id, title = self._conversation_names(source, conv_key)
        return Conversation(source, conversation_id, title,
                            tuple(sorted(self.vault.open(p["participant"]) for p in people)), row["last_timestamp"])

    def conversation(self, source: str, conversation_id: str) -> Conversation | None:
        return self._conversation_by_key(source, self.conversation_key(source, conversation_id))

    def conversation_title(self, source: str, conversation_id: str) -> str:
        return self._conversation_names(source, self.conversation_key(source, conversation_id))[1]

    def find_conversations(self, title: str, sources: Iterable[str] | None = None) -> list[Conversation]:
        """Conversations whose title matches `title` exactly (normalized), most recent first."""
        if not title_key(title):
            return []
        wanted = list(sources or [])
        with self._lock:
            rows = self._db.execute(
                "SELECT source, conv_key FROM conversations WHERE title_tag = ? ORDER BY last_timestamp DESC",
                (self._title_tag(title),),
            ).fetchall()
        found = [self._conversation_by_key(r["source"], r["conv_key"]) for r in rows]
        return [c for c in found if c and (not wanted or c.source in wanted)]

    def conversations_seen_by(self, audience: Iterable[str], exclude: tuple[str, str] | None = None,
                              limit: int = 50) -> list[tuple[str, str]]:
        """(source, conversation_id) pairs in which EVERY member of `audience` took part, across
        sources, most recent first: the "same person" scope.

        The rule is about who will read the suggestion. Text from another conversation may only
        surface if everyone being written to now was in that conversation, so a suggestion never
        repeats something to a person who was not there: writing to Ayşe can draw on a group Ayşe
        was in, but writing to a group of Ali and Can cannot draw on a private chat with Ali.
        """
        tags = sorted({self._participant_tag(p) for p in audience if normalize_participant(p)})
        if not tags:
            return []
        placeholders = ",".join("?" for _ in tags)
        with self._lock:
            rows = self._db.execute(
                f"""SELECT p.source, p.conv_key FROM participants p
                    JOIN conversations c ON c.source = p.source AND c.conv_key = p.conv_key
                    WHERE p.participant_tag IN ({placeholders})
                    GROUP BY p.source, p.conv_key
                    HAVING COUNT(DISTINCT p.participant_tag) = ?
                    ORDER BY MAX(c.last_timestamp) DESC LIMIT ?""",
                (*tags, len(tags), limit),
            ).fetchall()
        pairs = [(r["source"], self._conversation_names(r["source"], r["conv_key"])[0]) for r in rows]
        return [p for p in pairs if p != exclude]

    def _scope_rows(self, conversations: list[tuple[str, str]], limit: int) -> list[sqlite3.Row]:
        if not conversations:
            return []
        keys = [(source, self.conversation_key(source, cid)) for source, cid in conversations]
        clauses = " OR ".join("(source = ? AND conv_key = ?)" for _ in keys)
        params: list[object] = [value for pair in keys for value in pair]
        params.append(limit)
        with self._lock:
            return self._db.execute(
                f"SELECT * FROM messages WHERE {clauses} ORDER BY timestamp DESC LIMIT ?", params
            ).fetchall()

    def keyword_search(self, query: str, conversations: list[tuple[str, str]], limit: int) -> list[StoredMessage]:
        """Keyword search restricted to the given conversations: decrypts their most recent
        messages and ranks them by a BM25-style score. Filter-first, so it never returns a message
        from outside the scope no matter how relevant."""
        terms = _terms(query)
        if not terms or not conversations:
            return []
        messages = [self._stored(row) for row in self._scope_rows(conversations, self.KEYWORD_CANDIDATES)]
        tokenized = [_terms(m.text + " " + (m.subject or "")) for m in messages]
        if not messages:
            return []
        average_length = sum(len(t) for t in tokenized) / len(tokenized) or 1.0

        def matches(term: str, tokens: list[str]) -> int:
            # Prefix match for words being typed ("invo" finds "invoice"), exact for short ones.
            return sum(1 for token in tokens if token == term or (len(term) >= 3 and token.startswith(term)))

        document_frequency = {term: sum(1 for tokens in tokenized if matches(term, tokens)) for term in set(terms)}
        scored: list[tuple[float, int]] = []
        for position, tokens in enumerate(tokenized):
            score = 0.0
            for term in set(terms):
                frequency = matches(term, tokens)
                if not frequency:
                    continue
                df = document_frequency[term]
                idf = math.log(1 + (len(messages) - df + 0.5) / (df + 0.5))
                score += idf * frequency * 2.2 / (frequency + 1.2 * (0.25 + 0.75 * len(tokens) / average_length))
            if score > 0:
                scored.append((score, position))
        scored.sort(key=lambda pair: (-pair[0], pair[1]))
        return [messages[position] for _, position in scored[:limit]]

    def recent_messages(self, conversations: list[tuple[str, str]], limit: int) -> list[StoredMessage]:
        """The latest messages of the given conversations, newest first."""
        return [self._stored(row) for row in self._scope_rows(conversations, limit)]

    def message(self, record_id: str) -> StoredMessage | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM messages WHERE record_id = ?", (record_id,)).fetchone()
        return self._stored(row) if row else None

    def _stored(self, row: sqlite3.Row) -> StoredMessage:
        conversation_id, _ = self._conversation_names(row["source"], row["conv_key"])
        return StoredMessage(
            record_id=row["record_id"],
            source=row["source"],
            conversation_id=conversation_id,
            conversation_key=row["conv_key"],
            sender=self.vault.open(row["sender"]) or "",
            is_from_me=bool(row["is_from_me"]),
            timestamp=row["timestamp"],
            subject=self.vault.open(row["subject"]),
            text=self.vault.open(row["text"]) or "",
        )


def _terms(text: str) -> list[str]:
    return [w for w in re.findall(r"\w+", text.lower()) if len(w) > 1]

