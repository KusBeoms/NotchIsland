import Foundation

// MARK: - Calendar: which event the island shows, and what it says

/// One calendar event, reduced to what the island needs. Built from EventKit in CalendarMonitor.swift.
struct CalendarEvent: Equatable {
    var id: String               // unique per occurrence (a repeating event shares its EventKit identifier)
    var title: String
    var location = ""
    var start: Date
    var end: Date
    var isAllDay = false
}

enum CalendarRules {
    /// The event shows up as an activity this long before it starts ...
    static let lead: TimeInterval = 30 * 60
    /// ... and a short alert says so once this long before.
    static let alertLead: TimeInterval = 5 * 60

    /// The event to show now: the soonest one starting within `lead`; otherwise the one in progress (the most recently
    /// started); otherwise nothing. All-day events never count (they are not "next").
    static func featured(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        let timed = events.filter { !$0.isAllDay }
        let upcoming = timed.filter { $0.start > now && $0.start.timeIntervalSince(now) <= lead }
        if let soonest = upcoming.min(by: { ($0.start, $0.end) < ($1.start, $1.end) }) { return soonest }
        let ongoing = timed.filter { $0.start <= now && $0.end > now }
        return ongoing.max(by: { ($0.start, $1.end) < ($1.start, $0.end) })
    }

    static func minutesUntil(_ e: CalendarEvent, now: Date) -> Int {
        max(1, Int((e.start.timeIntervalSince(now) / 60).rounded(.up)))
    }
    /// The value on the right: "10분" before it starts, "진행 중" after.
    static func trail(_ e: CalendarEvent, now: Date) -> String {
        e.start > now ? "\(minutesUntil(e, now: now))분" : "진행 중"
    }
    /// "14:30–15:30 · 회의실 3"
    static func subtitle(_ e: CalendarEvent) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        let range = "\(f.string(from: e.start))–\(f.string(from: e.end))"
        return e.location.isEmpty ? range : "\(range) · \(e.location)"
    }

    /// One alert per event, in the last `alertLead` before it starts.
    static func shouldAlert(_ e: CalendarEvent, now: Date, alerted: Set<String>) -> Bool {
        let wait = e.start.timeIntervalSince(now)
        return wait > 0 && wait <= alertLead && !alerted.contains(e.id)
    }
    /// A queued "in N minutes" alert is dropped when the event has started (or been over) by the time it would be shown.
    static func alertStillUseful(_ e: CalendarEvent, now: Date) -> Bool { e.start > now }

    static func alertText(_ e: CalendarEvent, now: Date) -> String {
        "\(minutesUntil(e, now: now))분 후 · \(e.title)"
    }
}

// MARK: - One calendar query at a time

/// Decides which EventKit queries run and which results are used (main thread only, no I/O). A burst of change notifications
/// starts at most one query and marks one more run as owed; a result is applied unless `stop()` came after its query began.
struct CalendarRefreshGate {
    private var counter = 0
    private var stopToken = 0              // results of queries started up to here are void
    private var appliedToken = 0
    private var runningToken: Int?
    private var dirty = false

    /// A token to run a query with, or nil when one is already running (a rerun is then owed).
    mutating func begin() -> Int? {
        if runningToken != nil { dirty = true; return nil }
        counter += 1
        runningToken = counter
        return counter
    }

    /// A query ended. `apply`: use its events. `rerun`: something changed meanwhile, ask for a fresh query now.
    mutating func finish(_ token: Int) -> (apply: Bool, rerun: Bool) {
        let current = runningToken == token
        if current { runningToken = nil }
        let apply = token > stopToken && token > appliedToken
        if apply { appliedToken = token }
        let rerun = current && dirty && token > stopToken
        if current { dirty = false }
        return (apply, rerun)
    }

    /// Voids the running query and anything owed; the next `begin()` is free again.
    mutating func stop() { stopToken = counter; runningToken = nil; dirty = false }
}
