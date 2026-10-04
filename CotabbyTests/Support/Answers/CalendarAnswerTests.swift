import Foundation
import XCTest
@testable import Cotabby

/// Pins the calendar side of memory and answers: which questions are about the user's time and
/// which days they mean, the free/busy facts drafted from (and what they reveal to whom), the memory
/// record an event becomes, and the reader's incremental window.
final class CalendarAnswerTests: XCTestCase {
    /// Fixed clock and calendar: Monday 5 October 2026, 10:30 in Istanbul.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return calendar
    }()
    private var now: Date { date(5, 10, 30) }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func event(
        _ title: String, _ start: Date, _ end: Date, allDay: Bool = false, busy: Bool = true, cancelled: Bool = false,
        attendees: [CalendarEventSnapshot.Person] = [], organizer: CalendarEventSnapshot.Person? = nil,
        notes: String? = nil, modified: Date? = nil, id: String? = nil
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: id ?? title, seriesID: id ?? title, title: title, start: start, end: end, isAllDay: allDay, location: nil,
            notes: notes, calendarTitle: "Work", organizer: organizer, attendees: attendees, isCancelled: cancelled,
            showsAsBusy: busy, lastModified: modified
        )
    }

    private let me = CalendarEventSnapshot.Person(name: "Senad", email: "senad@imperum.io", isCurrentUser: true)
    private let ayse = CalendarEventSnapshot.Person(name: "Ayşe Yılmaz", email: "ayse@client.com", isCurrentUser: false)

    // MARK: - Scheduling questions

    func test_availabilityQuestionsAreRecognisedAndOtherQuestionsAreNot() {
        for question in ["Are you free Thursday afternoon?", "Can we meet next week?", "When can we schedule the demo?",
                         "Yarın müsait misin?", "Perşembeye toplantı yapabilir miyiz, saat kaçta uygun?"] {
            XCTAssertNotNil(SchedulingQuestion.days(in: question, now: now, calendar: calendar), question)
        }
        for question in ["Did the meeting go well?", "Can you send the POC numbers?", "Raporu gönderdin mi?"] {
            XCTAssertNil(SchedulingQuestion.days(in: question, now: now, calendar: calendar), question)
        }
    }

    func test_daysFollowTheWordsInBothLanguages() {
        let days = { (question: String) in SchedulingQuestion.days(in: question, now: self.now, calendar: self.calendar) ?? [] }
        XCTAssertEqual(days("Are you free tomorrow?"), [date(6)])
        XCTAssertEqual(days("Are you free Thursday?"), [date(8)])
        XCTAssertEqual(days("Perşembeye müsait misin?"), [date(8)], "a Turkish case ending on the day")
        XCTAssertEqual(days("Cumartesi müsait misin?"), [date(10)], "cumartesi is not cuma")
        XCTAssertEqual(days("Are you free next Thursday?"), [date(8), date(15)], "both readings of next")
        XCTAssertEqual(days("Can we meet next week?"), [date(12), date(13), date(14), date(15), date(16)])
        XCTAssertEqual(days("Are you free on 9 Oct?"), [date(9)])
        XCTAssertEqual(days("9 Ekim'de müsait misin?"), [date(9)])
        XCTAssertEqual(days("Are you free 3.11?"), [date(3, month: 11)])
        XCTAssertEqual(days("When are you free?").count, SchedulingQuestion.defaultDays)
        XCTAssertNil(SchedulingQuestion.month(named: "decisions"), "a word starting like a month is not one")
    }

    // MARK: - Availability facts

    func test_freeTimeIsTheWorkdayAroundMeetingsFromNow() {
        let busy = [event("Standup", date(5, 9), date(5, 9, 15)), event("Review", date(5, 13), date(5, 14))]
        let gaps = AvailabilityFacts.freeGaps(day: date(5), busy: busy, now: now, calendar: calendar)
        XCTAssertEqual(gaps, [DateInterval(start: date(5, 10, 30), end: date(5, 13)), DateInterval(start: date(5, 14), end: date(5, 18))])
        XCTAssertEqual(AvailabilityFacts.freeGaps(day: date(5), busy: [], now: date(5, 19), calendar: calendar), [],
                       "after hours nothing is left, and nothing traps")
        XCTAssertEqual(AvailabilityFacts.freeGaps(day: date(6), busy: [event("OOO", date(6), date(7), allDay: true)],
                                                  now: now, calendar: calendar), [])
    }

    /// Only busy and free: who asks comes from the message, which its sender controls, so no event's
    /// title or people are ever in an availability fact.
    func test_availabilityFactsSayBusyAndFreeAndNothingElse() {
        let shared = event("THY review", date(8, 10), date(8, 11), attendees: [me, ayse])
        let private_ = event("Dentist", date(8, 14), date(8, 15))
        let free = event("Holiday", date(8), date(9), allDay: true, busy: false)
        let facts = AvailabilityFacts.facts(days: [date(8)], events: [shared, private_, free], language: .english,
                                            now: now, calendar: calendar)
        XCTAssertEqual(facts.first?.text,
                       "Thursday 8 October 2026: free 09:00–10:00, 11:00–14:00, 15:00–18:00; busy 10:00–11:00, 14:00–15:00")
        let turkish = AvailabilityFacts.facts(days: [date(8)], events: [private_], language: .turkish, now: now, calendar: calendar)
        XCTAssertEqual(turkish.first?.text, "8 Ekim 2026 Perşembe: boş (müsait) 09:00–14:00, 15:00–18:00; dolu 14:00–15:00")
        XCTAssertEqual(AvailabilityFacts.language(of: "Perşembe öğleden sonra müsait misin?"), .turkish)
    }

    // MARK: - Memory records

    func test_anEventBecomesARecordWithoutCallBoilerplate() throws {
        let notes = "Agenda: pilot scope and pricing\n\n________________\nMicrosoft Teams meeting\nJoin on your computer\nhttps://teams.microsoft.com/l/x\nPasscode: abc123"
        let record = try XCTUnwrap(CalendarEventText.record(
            event("THY review", date(8, 10), date(8, 11), attendees: [me, ayse], organizer: ayse, notes: notes, id: "E1"),
            timeZone: calendar.timeZone
        ))
        XCTAssertEqual(record.text, """
        Meeting: THY review
        When: Thu 8 Oct 2026, 10:00–11:00
        Organizer: Ayşe Yılmaz
        Agenda: pilot scope and pricing
        """)
        XCTAssertEqual(record.conversationID, "event:E1")
        XCTAssertEqual(record.participants, ["ayse@client.com"], "the user is not a participant")
        XCTAssertFalse(record.isFromMe, "an event is not something the user said")
        let cancelled = try XCTUnwrap(CalendarEventText.record(event("Sync", date(9, 9), date(9, 10), cancelled: true),
                                                               timeZone: calendar.timeZone))
        XCTAssertTrue(cancelled.text.contains("Status: cancelled"), "replaces the stored meeting instead of vanishing")
    }

    func test_theReaderReadsChangedEventsAndOnesEnteringTheHorizon() throws {
        let lastSync = now.addingTimeInterval(-86_400)
        let events = [
            event("Old unchanged", date(1, 10), date(1, 11), modified: date(1)),
            event("Moved", date(9, 10), date(9, 11), modified: now.addingTimeInterval(-600)),
            event("Far ahead", lastSync.addingTimeInterval(91 * 86_400), lastSync.addingTimeInterval(91 * 86_400 + 3_600), modified: date(1)),
        ]
        let reader = CalendarHistoryReader(events: { _, _ in events }, isAuthorized: { true }, now: { self.now })
        let first = try reader.read(after: nil, since: nil, limit: 500)
        XCTAssertEqual(first.records.count, 3, "the first sync reads the whole window")
        let next = try reader.read(after: String(Int64(lastSync.timeIntervalSince1970 * 1000)), since: nil, limit: 500)
        XCTAssertEqual(next.records.map(\.conversationTitle), ["Moved", "Far ahead"])
        XCTAssertEqual(next.nextCursor, String(Int64(now.timeIntervalSince1970 * 1000)))
        let denied = CalendarHistoryReader(events: { _, _ in events }, isAuthorized: { false }, now: { self.now })
        XCTAssertFalse(denied.readiness().isReady)
        XCTAssertTrue(try denied.read(after: nil, since: nil, limit: 10).records.isEmpty)
    }
}
