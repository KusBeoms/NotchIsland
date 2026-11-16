import Foundation

// Which event is shown, what it says, and when it alerts. No calendar access needed.
@main
struct CalendarTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ev(_ id: String, _ startMin: Double, _ lengthMin: Double, allDay: Bool = false, place: String = "") -> CalendarEvent {
            let s = now.addingTimeInterval(startMin * 60)
            return CalendarEvent(id: id, title: "일정 \(id)", location: place, start: s, end: s.addingTimeInterval(lengthMin * 60), isAllDay: allDay)
        }

        // nothing close: nothing shown
        assert(CalendarRules.featured([], now: now) == nil)
        assert(CalendarRules.featured([ev("far", 45, 30)], now: now) == nil)           // starts beyond the 30 minute lead
        assert(CalendarRules.featured([ev("past", -90, 30)], now: now) == nil)         // already over

        // the soonest upcoming event within the lead wins
        let a = ev("a", 20, 30), b = ev("b", 10, 30), c = ev("c", 29, 30)
        assert(CalendarRules.featured([a, b, c], now: now)?.id == "b")
        assert(CalendarRules.featured([ev("edge", 30, 30)], now: now)?.id == "edge")  // exactly on the lead: shown
        assert(CalendarRules.featured([ev("edge", 31, 30)], now: now) == nil)

        // an upcoming meeting beats a long block that is merely in progress
        let block = ev("block", -120, 480), meeting = ev("meeting", 12, 30)
        assert(CalendarRules.featured([block, meeting], now: now)?.id == "meeting")
        // with nothing upcoming, the one in progress is shown (the most recently started)
        let early = ev("early", -120, 240), late = ev("late", -10, 60)
        assert(CalendarRules.featured([early, late], now: now)?.id == "late")
        assert(CalendarRules.featured([ev("done", -60, 60)], now: now) == nil)          // ended exactly now: over

        // all-day events are never "next"
        assert(CalendarRules.featured([ev("holiday", -300, 1440, allDay: true), ev("trip", 5, 1440, allDay: true)], now: now) == nil)
        assert(CalendarRules.featured([ev("holiday", -300, 1440, allDay: true), ev("m", 7, 30)], now: now)?.id == "m")

        // texts
        assert(CalendarRules.trail(ev("x", 10, 30), now: now) == "10분")
        assert(CalendarRules.trail(ev("x", 0.2, 30), now: now) == "1분")                // never "0분"
        assert(CalendarRules.trail(ev("x", 9.1, 30), now: now) == "10분")               // rounds up like a countdown
        assert(CalendarRules.trail(ev("x", -5, 30), now: now) == "진행 중")
        assert(CalendarRules.alertText(ev("팀", 5, 30), now: now) == "5분 후 · 일정 팀")
        let withPlace = ev("p", 10, 60, place: "회의실 3")
        let range = CalendarRules.subtitle(withPlace)
        assert(range.hasSuffix(" · 회의실 3") && range.contains("–") && range.count == "00:00–00:00 · 회의실 3".count)
        assert(CalendarRules.subtitle(ev("q", 10, 60)).count == "00:00–00:00".count)       // no place: just the time

        // one alert per event, only in the last 5 minutes
        var alerted = Set<String>()
        let m = ev("m", 4, 30)
        assert(CalendarRules.shouldAlert(m, now: now, alerted: alerted))
        assert(!CalendarRules.shouldAlert(ev("m", 6, 30), now: now, alerted: alerted))      // too early
        assert(!CalendarRules.shouldAlert(ev("m", 0, 30), now: now, alerted: alerted))      // already started
        assert(CalendarRules.shouldAlert(ev("m", 5, 30), now: now, alerted: alerted))       // exactly 5 minutes
        alerted.insert("m")
        assert(!CalendarRules.shouldAlert(m, now: now, alerted: alerted))
        assert(CalendarRules.shouldAlert(ev("other", 3, 30), now: now, alerted: alerted))
        print("Calendar event selection, texts and alert rule checks passed")
    }
}
