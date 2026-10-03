"""The one message shape every connector produces.

Why a shared record: WhatsApp rows, Mail messages, Teams chat messages and Slack events all
describe the same thing (someone said something in a conversation at a time), and retrieval only
works if they are stored, indexed and filtered the same way. Connectors translate their source
into `MessageRecord`; the store, the index and the scope rules never see a source-specific shape.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from datetime import datetime, timezone


@dataclass(frozen=True)
class MessageRecord:
    """One message, normalized.

    `record_id` is stable across syncs (derived from the source's own id), so re-reading a source
    replaces rows instead of duplicating them. `conversation_id` is the source's own conversation
    key (a WhatsApp chat JID, a Mail thread, a Teams chat id); `participants` are the people in it,
    as display names or addresses, used for the "same person" scope.
    """

    source: str
    source_message_id: str
    conversation_id: str
    conversation_title: str
    sender: str
    is_from_me: bool
    timestamp: float
    text: str
    participants: tuple[str, ...] = field(default_factory=tuple)
    subject: str | None = None

    @property
    def record_id(self) -> str:
        digest = hashlib.sha1(f"{self.source}\x1f{self.source_message_id}".encode()).hexdigest()
        return f"{self.source}:{digest[:20]}"

    def passage_text(self) -> str:
        """The text LEANN embeds: the date and speaker give the model and the reader context
        ("[2026-09-12] Ayşe: the invoice is paid"), and a mail subject anchors short replies."""
        when = datetime.fromtimestamp(self.timestamp, tz=timezone.utc).strftime("%Y-%m-%d")
        speaker = "You" if self.is_from_me else (self.sender or "Someone")
        subject = f" (re: {self.subject})" if self.subject else ""
        return f"[{when}] {speaker}{subject}: {self.text}"

    def metadata(self) -> dict[str, object]:
        """Metadata stored with the passage and used by LEANN's metadata filters."""
        return {
            "id": self.record_id,
            "source": self.source,
            "conversation_id": self.conversation_id,
            "sender": self.sender,
            "is_from_me": self.is_from_me,
            "timestamp": self.timestamp,
        }


def normalize_participant(name: str) -> str:
    """Participants are compared case-insensitively with surrounding space and mail brackets
    dropped, so "Ayşe Yılmaz <ayse@x.com>" in Mail and "ayse@x.com" in Graph can meet."""
    cleaned = name.strip().lower()
    if "<" in cleaned and cleaned.endswith(">"):
        cleaned = cleaned[cleaned.rindex("<") + 1 : -1]
    return cleaned.strip()
