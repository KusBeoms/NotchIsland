import Foundation
import EventKit

// MARK: - Calendar access (EventKit)

/// Reads today's events and reports them again whenever the calendar changes. Read-only: nothing is ever written.
final class CalendarMonitor {
    /// The events from a little before now to a day ahead (all calendars).
    var onChange: (([CalendarEvent]) -> Void)?
    private(set) var events: [CalendarEvent] = []
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var started = false

    /// Explains a refused permission in the settings window; nil when there is nothing to say.
    static var statusCaption: String? {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .denied, .restricted:
            return "캘린더 접근이 꺼져 있습니다. 시스템 설정 > 개인정보 보호 및 보안 > 캘린더에서 NotchIsland를 허용하세요."
        case .writeOnly:
            return "일정을 읽으려면 '전체 접근'이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 캘린더에서 바꿔 주세요."
        default:
            return nil
        }
    }

    func start() {
        guard !started else { return }
        started = true
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            refresh()
        case .notDetermined:
            store.requestFullAccessToEvents { [weak self] granted, _ in       // the system asks once; the answer arrives on any queue
                DispatchQueue.main.async { if granted { self?.refresh() } }
            }
        default:
            break                                                             // refused: stay silent, the settings window explains
        }
    }

    func stop() {
        guard started else { return }
        started = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        events = []
    }

    func refresh() {
        guard started, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let fresh = store.events(matching: predicate).compactMap { Self.convert($0) }
        guard fresh != events else { return }
        events = fresh
        onChange?(fresh)
    }

    /// Cancelled events and ones you declined are not worth a place on the island.
    private static func convert(_ e: EKEvent) -> CalendarEvent? {
        guard e.status != .canceled, let start = e.startDate, let end = e.endDate else { return nil }
        if e.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) == true { return nil }
        let id = "\(e.eventIdentifier ?? e.title ?? "?")@\(Int(start.timeIntervalSince1970))"
        return CalendarEvent(id: id, title: e.title ?? "(제목 없음)", location: e.location ?? "", start: start, end: end, isAllDay: e.isAllDay)
    }
}
