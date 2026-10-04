"""Teams: mapping the cached rows to records, and the staged import that carries the cache here.

The mapping is pinned with small dict fixtures shaped like Teams' IndexedDB values (what
`ccl_chromium_indexeddb` yields), so the title and participant rules that decide which messages a
suggestion may see are tested without a LevelDB.
"""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from cotabby_memory import service as service_module
from cotabby_memory.connectors import teams
from cotabby_memory.records import MessageRecord
from cotabby_memory.service import MemoryService, RequestError

KEY = bytes(range(32))
ME = "8:orgid:aaaaaaaa-0000-0000-0000-000000000001"
ALI = "8:orgid:bbbbbbbb-0000-0000-0000-000000000002"
VALON = "8:orgid:cccccccc-0000-0000-0000-000000000003"
ONE_TO_ONE = "19:aaaaaaaa-0000-0000-0000-000000000001_bbbbbbbb-0000-0000-0000-000000000002@unq.gbl.spaces"
GROUP = "19:group0001@thread.v2"
T0 = 1_790_000_000_000  # Teams arrival times are epoch milliseconds.
MEETING = "19:meeting_abc@thread.v2"


def message(conversation: str, creator: str, name: str, content: str, at_ms: float, *, kind: str = "RichText/Html",
            message_id: str | None = None, deleted: bool = False) -> dict:
    return {
        "id": message_id or str(int(at_ms)), "conversationId": conversation, "creator": creator,
        "imDisplayName": name, "content": content, "messageType": kind, "originalArrivalTime": at_ms,
        "deletionInfo": {"deletedTime": 1} if deleted else None,
    }


def fixture() -> tuple[list[dict], list[dict], dict[str, str]]:
    conversations = [
        {"id": ONE_TO_ONE, "type": "Chat", "members": [{"id": ME}, {"id": ALI}],
         "chatTitle": {"longTitle": "Ali Pakkan, Senad Aruc"}},
        # Teams' cached title names this group after one member; its members list is partial.
        {"id": GROUP, "type": "Chat", "members": [{"id": ME}, {"id": ALI}],
         "chatTitle": {"longTitle": "Ali Pakkan, Senad Aruc"}},
        {"id": MEETING, "type": "Meeting", "threadProperties": {"topic": "POC Planning"},
         "members": [{"id": ME}, {"id": ALI}, {"id": VALON}]},
    ]
    messages = [
        message(ONE_TO_ONE, ALI, "Ali Pakkan", "<p>The <b>POC</b> passed&nbsp;today</p>", T0 + 1_000),
        message(ONE_TO_ONE, ME, "Senad Aruc", "<p>Great news</p><blockquote itemtype=\"http://schema.skype.com/Reply\">"
                "The POC passed today</blockquote>", T0 + 2_000),
        message(GROUP, VALON, "Valon Dauti", "Budget is approved", T0 + 3_000, kind="Text"),
        message(GROUP, ME, "Senad Aruc", "Thanks Valon", T0 + 4_000),
        message(MEETING, ME, "Senad Aruc", "Agenda is in the invite", T0 + 5_000),
        message(ONE_TO_ONE, ALI, "Ali Pakkan", "", T0 + 6_000, kind="Event/Call"),
        message(ONE_TO_ONE, ALI, "Ali Pakkan", "removed", T0 + 7_000, deleted=True),
        message("48:notifications", ALI, "Ali Pakkan", "You were mentioned", T0 + 8_000),
        # A message the user sent on someone's behalf carries that person's name.
        message(MEETING, ME, "Valon Dauti", "Forwarded note", T0 + 9_000),
    ]
    profiles = {ALI: "Ali Pakkan"}
    return conversations, messages, profiles


def by_conversation(records: list[MessageRecord]) -> dict[str, list[MessageRecord]]:
    grouped: dict[str, list[MessageRecord]] = {}
    for record in records:
        grouped.setdefault(record.conversation_id, []).append(record)
    return grouped


def test_teams_titles_come_from_topics_and_the_one_to_one_id_never_from_cached_titles():
    records, newest = teams.records_from(*fixture(), after_ms=0)
    grouped = by_conversation(records)
    assert grouped[ONE_TO_ONE][0].conversation_title == "Ali Pakkan"
    assert grouped[MEETING][0].conversation_title == "POC Planning"
    # The group is titled by everyone in it, so it can never pass for the 1:1 with Ali.
    assert grouped[GROUP][0].conversation_title == "Ali Pakkan, Valon Dauti"
    assert newest == T0 + 9_000


def test_teams_participants_include_everyone_who_wrote_and_never_the_user():
    records, _ = teams.records_from(*fixture(), after_ms=0)
    grouped = by_conversation(records)
    assert grouped[ONE_TO_ONE][0].participants == (ALI,)
    assert grouped[GROUP][0].participants == (ALI, VALON)
    assert all(r.participants == grouped[GROUP][0].participants for r in grouped[GROUP])
    assert [r.is_from_me for r in grouped[ONE_TO_ONE]] == [False, True]


def test_teams_keeps_only_what_people_wrote():
    records, _ = teams.records_from(*fixture(), after_ms=0)
    texts = [r.text for r in records]
    assert "The POC passed today" in texts
    assert "Great news" in texts, "quoted replies are dropped"
    assert not any("removed" in t or "mentioned" in t for t in texts), "deleted and system feeds are skipped"
    assert len(records) == 6


def test_teams_resumes_after_the_cursor():
    records, newest = teams.records_from(*fixture(), after_ms=T0 + 4_000)
    assert sorted(r.timestamp for r in records) == [(T0 + 5_000) / 1000, (T0 + 9_000) / 1000]
    assert newest == T0 + 9_000


def test_teams_sender_names_follow_the_person_not_one_message():
    records, _ = teams.records_from(*fixture(), after_ms=0)
    forwarded = next(r for r in records if r.text == "Forwarded note")
    assert forwarded.is_from_me
    assert forwarded.sender == "Senad Aruc"


def test_html_to_text_keeps_line_breaks_and_mentions():
    assert teams.html_to_text('<div>Hi <span itemtype="http://schema.skype.com/Mention">Ali</span>,</div><div>see you</div>') == "Hi Ali,\nsee you"
    assert teams.html_to_text("plain &amp; simple") == "plain & simple"
    assert teams.html_to_text("") == ""


# MARK: - Staged import


def staged_service(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, reader) -> MemoryService:
    monkeypatch.setitem(service_module.STAGED_READERS, "teams", reader)
    service = MemoryService(tmp_path / "data", KEY)
    service.config.apply({"index": {"vector_weight": 0.0}, "sources": {"teams": {"enabled": True}}})
    return service


def wait(service: MemoryService, job_id: int) -> dict:
    deadline = time.time() + 10
    while time.time() < deadline:
        job = next(j for j in service.jobs.list() if j["id"] == job_id)
        if job["status"] not in ("queued", "running"):
            return job
        time.sleep(0.01)
    raise AssertionError("job did not finish")


def stage(service: MemoryService) -> Path:
    copy = service.staging_dir / "teams-1"
    (copy / "WV2Profile_tfw" / f"{teams.source().id}.indexeddb.leveldb").mkdir(parents=True)
    return copy


def test_a_staged_copy_is_imported_and_then_deleted(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    seen: list[tuple[list[Path], float]] = []

    def reader(folders, after_ms):
        seen.append((folders, after_ms))
        records, newest = teams.records_from(*fixture(), after_ms=after_ms)
        return records, newest

    service = staged_service(tmp_path, monkeypatch, reader)
    copy = stage(service)
    job = wait(service, service.records_import_staged({"source": "teams", "path": str(copy)})["id"])
    assert job["status"] == "done", job["error"]
    assert job["result"]["teams"]["stored"] == 6
    assert not copy.exists()
    assert len(seen[0][0]) == 1 and seen[0][1] == 0.0
    assert float(service.store.cursor("teams")) == T0 + 9_000
    hits = service.search({"query": "POC", "scope": {"title": "Ali Pakkan", "sources": ["teams"]}})["hits"]
    assert {h["conversation_id"] for h in hits} == {ONE_TO_ONE}

    # The next import re-reads a short window before the cursor, to pick up edits.
    service.store.set_cursor("teams", "1800000000000.0")
    copy = stage(service)
    wait(service, service.records_import_staged({"source": "teams", "path": str(copy)})["id"])
    assert seen[1][1] == 1_800_000_000_000 - service_module.STAGED_LOOKBACK_MS
    assert float(service.store.cursor("teams")) == 1_800_000_000_000, "the cursor never moves back"


def test_a_failed_read_still_deletes_the_copy(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    def reader(folders, after_ms):
        raise RuntimeError("corrupt cache")

    service = staged_service(tmp_path, monkeypatch, reader)
    copy = stage(service)
    job = wait(service, service.records_import_staged({"source": "teams", "path": str(copy)})["id"])
    assert job["status"] == "failed"
    assert not copy.exists()


def test_only_folders_directly_inside_staging_are_accepted(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    service = staged_service(tmp_path, monkeypatch, lambda folders, after_ms: ([], 0.0))
    outside = tmp_path / "elsewhere"
    outside.mkdir()
    (outside / "keep.txt").write_text("not the service's to delete")
    nested = service.staging_dir / "a" / "b"
    nested.mkdir(parents=True)
    link = service.staging_dir / "link"
    link.symlink_to(outside)
    for path in (outside, nested, link, service.staging_dir / ".." / "elsewhere", tmp_path / "missing"):
        with pytest.raises(RequestError):
            service.records_import_staged({"source": "teams", "path": str(path)})
    assert (outside / "keep.txt").exists()
    with pytest.raises(RequestError):
        service.records_import_staged({"source": "whatsapp", "path": str(stage(service))})


def test_staging_leftovers_are_removed_at_start(tmp_path: Path):
    leftover = tmp_path / "data" / "staging" / "teams-crashed"
    leftover.mkdir(parents=True)
    service = MemoryService(tmp_path / "data", KEY)
    assert not leftover.exists()
    assert service.staging_dir.stat().st_mode & 0o777 == 0o700


def test_teams_and_outlook_are_listed_with_their_apps(tmp_path: Path):
    service = MemoryService(tmp_path / "data", KEY)
    listed = {s["id"]: s for s in service.sources_list({})}
    assert "com.microsoft.teams2" in listed["teams"]["app_bundle_ids"]
    assert listed["teams"]["pushed"] and listed["outlook"]["pushed"]
    assert listed["outlook"]["app_bundle_ids"] == ["com.microsoft.Outlook"]
