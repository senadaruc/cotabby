"""The service's own copy of every ingested message, in SQLite.

Why keep a copy when LEANN stores passages too:
- Rebuilding an index (new embedding model, new chunking) must not re-read WhatsApp, Mail, Graph
  and Slack; it reads from here.
- Scope rules need structured queries LEANN does not offer: which conversation does the title
  "Ayşe Yılmaz" belong to, which other conversations share her as a participant.
- A keyword index (FTS5) over the same rows serves messages that arrived after the last LEANN
  build, and gives exact, filter-first matches inside one conversation.
- Exclusions and retention are enforced by deleting rows here; the next build drops them from
  LEANN as well.

The database lives in the 0700 data directory with 0600 permissions. It holds message text, so it
is as sensitive as the sources themselves.
"""

from __future__ import annotations

import os
import sqlite3
import threading
import time
from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from pathlib import Path

from .records import MessageRecord, normalize_participant

_SCHEMA = """
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS messages (
    record_id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    sender TEXT NOT NULL,
    is_from_me INTEGER NOT NULL,
    timestamp REAL NOT NULL,
    subject TEXT,
    text TEXT NOT NULL,
    indexed INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS messages_conversation ON messages(source, conversation_id, timestamp);
CREATE INDEX IF NOT EXISTS messages_unindexed ON messages(source, indexed);
CREATE TABLE IF NOT EXISTS conversations (
    source TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    title TEXT NOT NULL,
    title_key TEXT NOT NULL,
    last_timestamp REAL NOT NULL DEFAULT 0,
    PRIMARY KEY (source, conversation_id)
);
CREATE INDEX IF NOT EXISTS conversations_title ON conversations(title_key);
CREATE TABLE IF NOT EXISTS participants (
    source TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    participant TEXT NOT NULL,
    PRIMARY KEY (source, conversation_id, participant)
);
CREATE INDEX IF NOT EXISTS participants_name ON participants(participant);
CREATE TABLE IF NOT EXISTS cursors (
    source TEXT PRIMARY KEY,
    cursor TEXT NOT NULL,
    updated_at REAL NOT NULL
);
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    text, content='messages', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, text) VALUES (new.rowid, new.text);
END;
CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
END;
CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE OF text ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
    INSERT INTO messages_fts(rowid, text) VALUES (new.rowid, new.text);
END;
"""


@dataclass(frozen=True)
class StoredMessage:
    record_id: str
    source: str
    conversation_id: str
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
    import re

    cleaned = re.sub(r"[‎‏‪-‮⁦-⁩]", "", title)
    cleaned = re.sub(r"^\(\d+\+?\)\s*", "", cleaned.strip())
    return " ".join(cleaned.lower().split())


class MessageStore:
    def __init__(self, path: Path):
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(path.parent, 0o700)
        # One connection shared by the server's worker threads, serialized by a lock: SQLite is
        # fast enough here that a single writer is simpler than a pool and avoids lock errors.
        self._lock = threading.RLock()
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        os.chmod(path, 0o600)
        with self._lock:
            self._db.executescript(_SCHEMA)

    def close(self) -> None:
        with self._lock:
            self._db.close()

    # MARK: - Writing

    def upsert(self, records: Iterable[MessageRecord]) -> int:
        """Inserts or replaces records and their conversations. Returns how many rows changed."""
        changed = 0
        with self._lock, self._db:
            for record in records:
                cursor = self._db.execute(
                    """INSERT INTO messages(record_id, source, conversation_id, sender, is_from_me,
                                            timestamp, subject, text, indexed)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                       ON CONFLICT(record_id) DO UPDATE SET
                         text = excluded.text, sender = excluded.sender, subject = excluded.subject,
                         timestamp = excluded.timestamp, indexed = 0
                       WHERE messages.text != excluded.text OR messages.sender != excluded.sender""",
                    (
                        record.record_id,
                        record.source,
                        record.conversation_id,
                        record.sender,
                        int(record.is_from_me),
                        record.timestamp,
                        record.subject,
                        record.text,
                    ),
                )
                changed += cursor.rowcount
                self._db.execute(
                    """INSERT INTO conversations(source, conversation_id, title, title_key, last_timestamp)
                       VALUES (?, ?, ?, ?, ?)
                       ON CONFLICT(source, conversation_id) DO UPDATE SET
                         title = CASE WHEN excluded.title != '' THEN excluded.title ELSE conversations.title END,
                         title_key = CASE WHEN excluded.title_key != '' THEN excluded.title_key ELSE conversations.title_key END,
                         last_timestamp = MAX(conversations.last_timestamp, excluded.last_timestamp)""",
                    (
                        record.source,
                        record.conversation_id,
                        record.conversation_title,
                        title_key(record.conversation_title),
                        record.timestamp,
                    ),
                )
                # The other people in the conversation: its listed participants plus whoever sent
                # a message that is not the user's own. The user is never a participant of their
                # own conversations, or "same person" would match every chat.
                people = set(record.participants)
                if not record.is_from_me and record.sender:
                    people.add(record.sender)
                for participant in people:
                    normalized = normalize_participant(participant)
                    if normalized:
                        self._db.execute(
                            "INSERT OR IGNORE INTO participants(source, conversation_id, participant) VALUES (?, ?, ?)",
                            (record.source, record.conversation_id, normalized),
                        )
        return changed

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

    def purge(self, *, excluded_conversations: Iterable[str], excluded_participants: Iterable[str],
              older_than: float | None) -> int:
        """Deletes excluded and expired messages. Returns how many were removed; the caller
        rebuilds the affected shards so LEANN forgets them too."""
        removed = 0
        conversations = list(excluded_conversations)
        participants = [normalize_participant(p) for p in excluded_participants]
        with self._lock, self._db:
            for conversation in conversations:
                removed += self._db.execute("DELETE FROM messages WHERE conversation_id = ?", (conversation,)).rowcount
            for participant in participants:
                rows = self._db.execute(
                    "SELECT source, conversation_id FROM participants WHERE participant = ?", (participant,)
                ).fetchall()
                for row in rows:
                    removed += self._db.execute(
                        "DELETE FROM messages WHERE source = ? AND conversation_id = ?",
                        (row["source"], row["conversation_id"]),
                    ).rowcount
            if older_than is not None:
                removed += self._db.execute("DELETE FROM messages WHERE timestamp < ?", (older_than,)).rowcount
        return removed

    def set_cursor(self, source: str, cursor: str) -> None:
        with self._lock, self._db:
            self._db.execute(
                "INSERT INTO cursors(source, cursor, updated_at) VALUES (?, ?, ?) "
                "ON CONFLICT(source) DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at",
                (source, cursor, time.time()),
            )

    # MARK: - Reading

    def cursor(self, source: str) -> str | None:
        with self._lock:
            row = self._db.execute("SELECT cursor FROM cursors WHERE source = ?", (source,)).fetchone()
        return row["cursor"] if row else None

    def source_stats(self, source: str) -> dict[str, object]:
        with self._lock:
            row = self._db.execute(
                "SELECT COUNT(*) AS n, SUM(indexed = 0) AS pending, COUNT(DISTINCT conversation_id) AS conversations, "
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
            yield _stored(row)

    def conversation(self, source: str, conversation_id: str) -> Conversation | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM conversations WHERE source = ? AND conversation_id = ?", (source, conversation_id)
            ).fetchone()
            if not row:
                return None
            people = self._db.execute(
                "SELECT participant FROM participants WHERE source = ? AND conversation_id = ?",
                (source, conversation_id),
            ).fetchall()
        return Conversation(row["source"], row["conversation_id"], row["title"],
                            tuple(p["participant"] for p in people), row["last_timestamp"])

    def find_conversations(self, title: str, sources: Iterable[str] | None = None) -> list[Conversation]:
        """Conversations whose title matches `title` exactly (normalized), most recent first."""
        key = title_key(title)
        if not key:
            return []
        wanted = list(sources or [])
        with self._lock:
            rows = self._db.execute(
                "SELECT source, conversation_id FROM conversations WHERE title_key = ? ORDER BY last_timestamp DESC",
                (key,),
            ).fetchall()
        found = [self.conversation(r["source"], r["conversation_id"]) for r in rows]
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
        names = sorted({normalize_participant(p) for p in audience if normalize_participant(p)})
        if not names:
            return []
        placeholders = ",".join("?" for _ in names)
        with self._lock:
            rows = self._db.execute(
                f"""SELECT p.source, p.conversation_id FROM participants p
                    JOIN conversations c ON c.source = p.source AND c.conversation_id = p.conversation_id
                    WHERE p.participant IN ({placeholders})
                    GROUP BY p.source, p.conversation_id
                    HAVING COUNT(DISTINCT p.participant) = ?
                    ORDER BY MAX(c.last_timestamp) DESC LIMIT ?""",
                (*names, len(names), limit),
            ).fetchall()
        pairs = [(r["source"], r["conversation_id"]) for r in rows]
        return [p for p in pairs if p != exclude]

    def keyword_search(self, query: str, conversations: list[tuple[str, str]], limit: int) -> list[StoredMessage]:
        """FTS5 search restricted to the given conversations. Filter-first, so it never returns a
        message from outside the scope no matter how relevant."""
        terms = _fts_terms(query)
        if not terms or not conversations:
            return []
        clauses = " OR ".join("(m.source = ? AND m.conversation_id = ?)" for _ in conversations)
        params: list[object] = [terms]
        for source, conversation_id in conversations:
            params.extend([source, conversation_id])
        params.append(limit)
        with self._lock:
            rows = self._db.execute(
                f"""SELECT m.* FROM messages_fts f JOIN messages m ON m.rowid = f.rowid
                    WHERE messages_fts MATCH ? AND ({clauses}) ORDER BY bm25(messages_fts) LIMIT ?""",
                params,
            ).fetchall()
        return [_stored(row) for row in rows]

    def recent_messages(self, conversations: list[tuple[str, str]], limit: int) -> list[StoredMessage]:
        """The latest messages of the given conversations, newest first."""
        if not conversations:
            return []
        clauses = " OR ".join("(source = ? AND conversation_id = ?)" for _ in conversations)
        params: list[object] = []
        for source, conversation_id in conversations:
            params.extend([source, conversation_id])
        params.append(limit)
        with self._lock:
            rows = self._db.execute(
                f"SELECT * FROM messages WHERE {clauses} ORDER BY timestamp DESC LIMIT ?", params
            ).fetchall()
        return [_stored(row) for row in rows]

    def message(self, record_id: str) -> StoredMessage | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM messages WHERE record_id = ?", (record_id,)).fetchone()
        return _stored(row) if row else None


def _stored(row: sqlite3.Row) -> StoredMessage:
    return StoredMessage(
        record_id=row["record_id"],
        source=row["source"],
        conversation_id=row["conversation_id"],
        sender=row["sender"],
        is_from_me=bool(row["is_from_me"]),
        timestamp=row["timestamp"],
        subject=row["subject"],
        text=row["text"],
    )


def _fts_terms(query: str) -> str:
    """An FTS5 MATCH expression that ORs the query's words as quoted prefix terms, so user text
    with quotes, hyphens or operators can never form an invalid or unintended FTS query."""
    import re

    words = [w for w in re.findall(r"\w+", query.lower()) if len(w) > 1][:24]
    return " OR ".join(f'"{w}"*' for w in words)
