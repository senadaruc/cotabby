"""Microsoft Teams chats, read from the new Teams client's local cache.

Where the messages are: new Teams (`com.microsoft.teams2`) is a web app in a WebView, and keeps the
chats it has shown in Chromium IndexedDB under its container
(`.../EBWebView/WV2Profile_*/IndexedDB/https_teams.microsoft.com_0.indexeddb.leveldb`). Three of
its databases matter:

- `Teams:conversation-manager:*` / `conversations`: one row per chat, meeting chat or channel, with
  its topic, a display title ("Ali Pakkan, Senad Aruc") and its members' ids (`8:orgid:<guid>`).
- `Teams:replychain-manager:*` / `replychains`, `replychains-2`: messages grouped in reply chains,
  each with its sender's id and display name, arrival time (ms) and HTML content.
- `Teams:profiles:*` / `profiles`: display names for member ids, used when a message lacks one.

How it gets here: the container is protected by macOS and this service holds none of Cotabby's
permissions, so Cotabby copies the folder into the service's private `staging/` directory and calls
`records.import_staged`; the copy is deleted as soon as it has been read (see service.py).

What it is not: complete. Teams caches what it has displayed and synced, typically the recent
months of active chats; older history exists only in Microsoft 365. The schema is undocumented and
can change with any Teams update, so every field is read defensively and an unreadable cache is a
`ConnectorError` the pane shows, never a crash.
"""

from __future__ import annotations

import html
import re
from collections import Counter
from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

from ..records import MessageRecord
from .base import ConnectorError, Requirement
from .pushed import FULL_DISK_ACCESS, PushedSource

SOURCE_ID = "teams"

# Message kinds that carry something a person wrote. Calls, membership changes, topic updates,
# app installs and recordings are thread activity, not conversation.
_TEXT_TYPES = {"richtext/html", "text", "richtext"}

# Conversation ids for Teams' own feeds (notifications, call logs), not chats.
_SYSTEM_PREFIXES = ("48:",)


def source() -> PushedSource:
    return PushedSource(
        SOURCE_ID, "Microsoft Teams",
        "Chats, meeting chats and channels the Teams app has cached on this Mac (usually the recent "
        "months; older history stays in Microsoft 365).",
        ("com.microsoft.teams2", "com.microsoft.teams"),
        (FULL_DISK_ACCESS,),
    )


@dataclass(frozen=True)
class TeamsConversation:
    conversation_id: str
    topic: str
    members: tuple[str, ...]


def read_cache(folders: Iterable[Path], after_ms: float) -> tuple[list[MessageRecord], float]:
    """Reads every staged IndexedDB folder (one per Teams account profile) and returns the messages
    that arrived after `after_ms`, with the newest arrival time seen (the next cursor)."""
    from ..vendor.ccl_chromium import ccl_chromium_indexeddb as idb

    conversations: list[dict[str, Any]] = []
    messages: list[dict[str, Any]] = []
    profiles: dict[str, str] = {}
    read_any = False
    for folder in folders:
        blob = folder.with_name(folder.name.removesuffix(".leveldb") + ".blob")
        try:
            database = idb.WrappedIndexDB(str(folder), str(blob) if blob.exists() else None)
            names = {database[d.dbid_no].name: d.dbid_no for d in database.database_ids}
        except Exception as error:  # noqa: BLE001 - an unreadable cache must not break other sources
            raise ConnectorError(f"Cotabby could not read the Teams cache ({error}).") from error
        read_any = True
        for name, number in names.items():
            if not isinstance(name, str):
                continue
            if name.startswith("Teams:conversation-manager:"):
                conversations.extend(_values(database[number], ("conversations",)))
            elif name.startswith("Teams:replychain-manager:"):
                for chain in _values(database[number], ("replychains", "replychains-2")):
                    message_map = chain.get("messageMap")
                    if isinstance(message_map, dict):
                        messages.extend(m for m in message_map.values() if isinstance(m, dict))
            elif name.startswith("Teams:profiles:"):
                for profile in _values(database[number], ("profiles",)):
                    mri, display = profile.get("mri"), profile.get("displayName")
                    if isinstance(mri, str) and isinstance(display, str) and display.strip():
                        profiles[mri] = display.strip()
    if not read_any:
        raise ConnectorError("No Teams cache was found. Open Teams once so it caches your chats.")
    return records_from(conversations, messages, profiles, after_ms)


def _values(database, stores: tuple[str, ...]) -> Iterator[dict[str, Any]]:
    available = set(database.object_store_names)
    for store in stores:
        if store not in available:
            continue
        for record in database[store].iterate_records():
            if isinstance(record.value, dict):
                yield record.value


def records_from(conversations: list[dict[str, Any]], messages: list[dict[str, Any]],
                 profiles: dict[str, str], after_ms: float) -> tuple[list[MessageRecord], float]:
    """Maps Teams' cached rows to records. Pure, so it is tested with small dict fixtures.

    Who "me" is: the one member present in the most conversations, which needs no account id.

    Titles come only from data that names the conversation reliably: its topic; for a 1:1 chat the
    other person, whose id is part of the conversation id (`19:<a>_<b>@unq.gbl.spaces`), which is
    what the Teams window shows ("Chat | Ali Pakkan | ..."); otherwise the members' names. Teams'
    own cached `chatTitle` is not used as a title: it is computed from whichever members' avatars
    were loaded and names group chats after one person, which would let a group pass for a 1:1.
    """
    chats = {c.conversation_id: c for c in (_conversation(raw) for raw in conversations) if c}
    me = _me(chats.values(), messages)
    names = _names_by_mri(messages, profiles)

    # Who is in each conversation besides the user: its cached members, the two ids of a 1:1, and
    # everyone who wrote in it (the cached member list is often partial, and anyone who wrote
    # there was there). One set per conversation, so every message of a chat carries the same
    # participants (the "same people" rule compares them).
    writers: dict[str, set[str]] = {}
    for message in messages:
        creator = _mri(_text(message.get("creator")))
        if creator:
            writers.setdefault(_text(message.get("conversationId")), set()).add(creator)

    def participants_of(conversation_id: str) -> tuple[str, ...]:
        chat = chats.get(conversation_id)
        people = set(chat.members) if chat and chat.members else set()
        people |= set(_one_to_one_members(conversation_id))
        people |= writers.get(conversation_id, set())
        return tuple(sorted(p for p in people if p and p != me))

    titles: dict[str, str] = {}

    def title_of(conversation_id: str, participants: tuple[str, ...]) -> str:
        if conversation_id not in titles:
            chat = chats.get(conversation_id)
            if chat and chat.topic:
                titles[conversation_id] = chat.topic
            else:
                titles[conversation_id] = ", ".join(sorted(names[p] for p in participants if p in names))
        return titles[conversation_id]

    records: list[MessageRecord] = []
    newest = after_ms
    for message in messages:
        conversation_id = _text(message.get("conversationId"))
        if not conversation_id or conversation_id.startswith(_SYSTEM_PREFIXES):
            continue
        if _text(message.get("messageType")).lower() not in _TEXT_TYPES or message.get("deletionInfo"):
            continue
        arrived = _milliseconds(message.get("originalArrivalTime")) or _milliseconds(message.get("clientArrivalTime"))
        if arrived is None:
            continue
        newest = max(newest, arrived)
        if arrived <= after_ms:
            continue
        text = html_to_text(_text(message.get("content")))
        if not text:
            continue
        creator = _mri(_text(message.get("creator")))
        participants = participants_of(conversation_id)
        sender = (names.get(creator) or _text(message.get("imDisplayName")).strip()
                  or _text(message.get("fromDisplayNameInToken")).strip())
        records.append(MessageRecord(
            source=SOURCE_ID,
            source_message_id=f"{conversation_id}/{_text(message.get('id')) or int(arrived)}",
            conversation_id=conversation_id,
            conversation_title=title_of(conversation_id, participants),
            sender=sender,
            is_from_me=bool(me) and creator == me,
            timestamp=arrived / 1000,
            text=text,
            participants=participants,
        ))
    return records, newest


_ONE_TO_ONE = re.compile(r"^19:([0-9a-fA-F-]{36})_([0-9a-fA-F-]{36})@unq\.gbl\.spaces$")


def _one_to_one_members(conversation_id: str) -> tuple[str, ...]:
    match = _ONE_TO_ONE.match(conversation_id)
    return tuple(f"8:orgid:{guid.lower()}" for guid in match.groups()) if match else ()


def _conversation(raw: dict[str, Any]) -> TeamsConversation | None:
    conversation_id = _text(raw.get("id"))
    if not conversation_id:
        return None
    properties = raw.get("threadProperties") if isinstance(raw.get("threadProperties"), dict) else {}
    members = raw.get("members") if isinstance(raw.get("members"), list) else []
    return TeamsConversation(
        conversation_id=conversation_id,
        topic=_text(properties.get("topic")).strip(),
        members=tuple(sorted({_mri(_text(m.get("id"))) for m in members if isinstance(m, dict) and m.get("id")})),
    )


def _me(chats: Iterable[TeamsConversation], messages: list[dict[str, Any]]) -> str:
    """The member in the most conversations. Ties (one chat cached) fall back to the most frequent
    sender among those members, since the user writes in every chat they have open."""
    counts: Counter[str] = Counter()
    for chat in chats:
        counts.update(chat.members)
    for message in messages:
        counts.update(_one_to_one_members(_text(message.get("conversationId"))))
    if not counts:
        return ""
    top = counts.most_common()
    best = [mri for mri, count in top if count == top[0][1]]
    if len(best) == 1:
        return best[0]
    senders = Counter(_mri(_text(m.get("creator"))) for m in messages)
    return max(best, key=lambda mri: senders.get(mri, 0))


def _names_by_mri(messages: list[dict[str, Any]], profiles: dict[str, str]) -> dict[str, str]:
    """A display name per person: their directory profile, else the name most of their messages
    carry (a few carry someone else's, such as messages sent on another's behalf)."""
    seen: dict[str, Counter[str]] = {}
    for message in messages:
        creator = _mri(_text(message.get("creator")))
        name = _text(message.get("imDisplayName")).strip()
        if creator and name:
            seen.setdefault(creator, Counter())[name] += 1
    names = {mri: counter.most_common(1)[0][0] for mri, counter in seen.items()}
    names.update({mri: name for mri, name in profiles.items() if name})
    return names


def _mri(value: str) -> str:
    """Senders appear both as `8:orgid:<guid>` and as a contacts URL ending in it."""
    return value.rsplit("/", 1)[-1].strip()


def _text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def _milliseconds(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and value > 0:
        return float(value) if value > 1e11 else float(value) * 1000
    if isinstance(value, str) and value.strip():
        stripped = value.strip()
        if re.fullmatch(r"\d+(\.\d+)?", stripped):
            return _milliseconds(float(stripped))
        from datetime import datetime

        try:
            return datetime.fromisoformat(stripped.replace("Z", "+00:00")).timestamp() * 1000
        except ValueError:
            return None
    return None


class _TextExtractor(HTMLParser):
    """Teams message HTML to plain text: block elements become line breaks, quoted replies
    (`<blockquote itemtype=".../Reply">`) are dropped like quoted mail, and everything else keeps
    its text (mentions keep the person's name)."""

    _BLOCKS = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"}
    _SKIPPED = {"blockquote", "script", "style"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._skipping = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in self._SKIPPED:
            self._skipping += 1
        elif tag in self._BLOCKS and not self._skipping:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in self._SKIPPED:
            self._skipping = max(0, self._skipping - 1)
        elif tag in self._BLOCKS and not self._skipping:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if not self._skipping:
            self.parts.append(data)


def html_to_text(content: str) -> str:
    if not content:
        return ""
    if "<" not in content:
        return html.unescape(content).strip()
    extractor = _TextExtractor()
    try:
        extractor.feed(content)
        extractor.close()
    except Exception:  # noqa: BLE001 - malformed HTML falls back to tag stripping
        return re.sub(r"<[^>]+>", " ", html.unescape(content)).strip()
    text = "".join(extractor.parts).replace("\xa0", " ").replace("\r", "")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r" *\n *", "\n", text)
    # Each block tag both opens and closes a line, so adjacent blocks leave runs of breaks.
    return re.sub(r"\n{2,}", "\n", text).strip()
