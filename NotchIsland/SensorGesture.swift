import Foundation

// MARK: - Light-sensor gestures: what covering the sensor does

/// Where the island is when the sensor is covered. The defaults of each match what the app always did.
enum SensorContext: String, CaseIterable {
    case closed          // collapsed (or only peeking)
    case openMusic       // open, on a music card that has lyrics
    case openOther       // open, on any other card

    var title: String {
        switch self { case .closed: return "닫혀 있을 때"; case .openMusic: return "음악 카드"; case .openOther: return "다른 카드" }
    }
}

enum SensorGesture: String, CaseIterable {
    case tap, hold, doubleTap
    var title: String {
        switch self { case .tap: return "짧게 덮기"; case .hold: return "길게 덮기"; case .doubleTap: return "두 번 덮기" }
    }
}

enum SensorAction: String, CaseIterable {
    case none, openIsland, closeIsland, lyrics, playPause, nextTrack, previousTrack, toggleTimer, startPomodoro

    var title: String {
        switch self {
        case .none: return "동작 없음"
        case .openIsland: return "섬 열기"
        case .closeIsland: return "섬 닫기"
        case .lyrics: return "가사 보기/닫기"
        case .playPause: return "재생/일시정지"
        case .nextTrack: return "다음 곡"
        case .previousTrack: return "이전 곡"
        case .toggleTimer: return "타이머 시작/정지"
        case .startPomodoro: return "포모도로 시작/정지"
        }
    }
}

/// Which gesture does what: the user's choices on top of the defaults. Stored as "context.gesture" -> action in the preferences.
struct SensorGestureMap: Equatable {
    private(set) var overrides: [String: String]
    init(_ stored: [String: String] = [:]) { overrides = stored }

    static func key(_ c: SensorContext, _ g: SensorGesture) -> String { "\(c.rawValue).\(g.rawValue)" }

    /// Exactly what the sensor did before it could be configured.
    static func defaultAction(_ c: SensorContext, _ g: SensorGesture) -> SensorAction {
        switch (c, g) {
        case (.closed, .hold): return .openIsland
        case (.openMusic, .tap): return .closeIsland
        case (.openMusic, .hold): return .lyrics
        case (.openOther, .tap): return .closeIsland
        default: return .none
        }
    }

    /// What a context can sensibly be given: an open island cannot be opened, a closed one cannot be closed, lyrics need the music card.
    static func allowedActions(_ c: SensorContext) -> [SensorAction] {
        let common: [SensorAction] = [.playPause, .nextTrack, .previousTrack, .toggleTimer, .startPomodoro]
        switch c {
        case .closed: return [.none, .openIsland] + common
        case .openMusic: return [.none, .closeIsland, .lyrics] + common
        case .openOther: return [.none, .closeIsland] + common
        }
    }

    func action(_ c: SensorContext, _ g: SensorGesture) -> SensorAction {
        if let raw = overrides[Self.key(c, g)], let a = SensorAction(rawValue: raw), Self.allowedActions(c).contains(a) { return a }
        return Self.defaultAction(c, g)
    }

    /// A choice equal to the default is not stored: the defaults can then improve without leaving stale overrides behind.
    mutating func set(_ a: SensorAction, _ c: SensorContext, _ g: SensorGesture) {
        if a == Self.defaultAction(c, g) { overrides.removeValue(forKey: Self.key(c, g)) }
        else { overrides[Self.key(c, g)] = a.rawValue }
    }
    var stored: [String: String] { overrides }
}

/// Turns "finger down / finger up" of the sensor into tap / hold / double-tap, for the actions the map gives the current context.
/// Driven by the main loop (`tick`), so it needs no timers and can be tested with made-up times.
struct SensorGestureRecognizer {
    struct Event: Equatable {
        var gesture: SensorGesture
        var action: SensorAction
        var context: SensorContext
    }

    static let doubleTapWindow: TimeInterval = 0.35
    static func holdDelay(_ c: SensorContext) -> TimeInterval { c == .closed ? 0.3 : 0.45 }

    private struct Touch {
        var at: TimeInterval
        var context: SensorContext
        var map: SensorGestureMap
        var holdFired = false
        var consumed = false          // already acted on (a tap that fires at once)
    }
    private var touch: Touch?          // finger is down
    private var pending: (at: TimeInterval, context: SensorContext, map: SensorGestureMap)?    // a tap waiting to see if a second follows

    var isDown: Bool { touch != nil }
    /// Nothing is down and no tap is waiting: `tick` has nothing to do.
    var isIdle: Bool { touch == nil && pending == nil }

    private func event(_ g: SensorGesture, _ c: SensorContext, _ m: SensorGestureMap) -> [Event] {
        let a = m.action(c, g)
        return a == .none ? [] : [Event(gesture: g, action: a, context: c)]
    }

    mutating func down(at now: TimeInterval, context c: SensorContext, map m: SensorGestureMap) -> [Event] {
        var out: [Event] = []
        // a tap still waiting for a partner stands alone when the island changed since, or the window is already over
        if let p = pending, p.context != c || now - p.at > Self.doubleTapWindow {
            out += event(.tap, p.context, p.map); pending = nil
        }
        var t = Touch(at: now, context: c, map: m)
        // nothing else could follow this tap (no hold, no double tap mapped): act the moment the finger lands, like it always did
        let tapAlone = m.action(c, .hold) == .none && m.action(c, .doubleTap) == .none
        if tapAlone && m.action(c, .tap) != .none { t.consumed = true; out += event(.tap, c, m) }
        touch = t
        return out
    }

    mutating func up(at now: TimeInterval) -> [Event] {
        guard let t = touch else { return [] }
        touch = nil
        if t.consumed || t.holdFired { return [] }
        if t.map.action(t.context, .doubleTap) != .none {
            if pending?.context == t.context {                  // `down` already dropped a partner that was too old
                pending = nil
                return event(.doubleTap, t.context, t.map)
            }
            pending = (now, t.context, t.map)                   // wait: it may become a double tap
            return []
        }
        return event(.tap, t.context, t.map)
    }

    /// Call on every loop pass: fires a hold once the finger has stayed down long enough, and a lone tap once the double-tap window is over.
    mutating func tick(at now: TimeInterval) -> [Event] {
        if var t = touch, !t.consumed, !t.holdFired,
           t.map.action(t.context, .hold) != .none, now - t.at >= Self.holdDelay(t.context) {
            t.holdFired = true; touch = t
            pending = nil
            return event(.hold, t.context, t.map)
        }
        if touch == nil, let p = pending, now - p.at > Self.doubleTapWindow {
            pending = nil
            return event(.tap, p.context, p.map)
        }
        return []
    }

    /// The sensor went away (no readings): forget a finger that is "down".
    mutating func cancel() { touch = nil; pending = nil }
}
