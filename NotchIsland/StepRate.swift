import Foundation

// MARK: - How fast the main loop (and with it the light sensor) needs to run. Pure rules, no I/O.

/// The loop runs flat out only while something moves. A collapsed island with nothing to show ("deep idle") samples the light
/// sensor less often, but wakes to the normal idle rate the moment the sensor sees anything that could be a finger, and stays
/// there long enough to cover a whole double tap (`SensorGestureRecognizer.doubleTapWindow`) and a hold.
enum StepRate: Equatable {
    case full, idle, deepIdle

    var interval: TimeInterval {
        switch self { case .full: return 1.0 / 60; case .idle: return 1.0 / 30; case .deepIdle: return 1.0 / 20 }
    }
}

enum StepRatePolicy {
    /// After the last sign of a possible touch the loop keeps the idle rate this long: more than a double-tap window
    /// plus a long hold, so a tap that is still maturing never sees a slower sampling.
    static let activeHold: TimeInterval = 2.0

    /// - Parameters:
    ///   - needsFull: something visible or moving (the existing `stepNeedsFullRate`)
    ///   - restingCollapsed: collapsed, nothing live, spring settled, nothing pinned
    ///   - sinceSensorActivity: seconds since the sensor last looked like a finger (or a gesture was pending)
    static func rate(needsFull: Bool, restingCollapsed: Bool, sinceSensorActivity: TimeInterval) -> StepRate {
        if needsFull { return .full }
        if restingCollapsed && sinceSensorActivity >= activeHold { return .deepIdle }
        return .idle
    }

    /// True while the reading, the finger state or a waiting gesture means the sensor must keep being sampled at the idle rate.
    static func sensorActive(lux: Double, threshold: Double, ambient: Double, covered: Bool, dropInProgress: Bool, gestureBusy: Bool) -> Bool {
        if covered || dropInProgress || gestureBusy { return true }
        guard lux >= 0 else { return false }
        // Relative to the room once its light is known (a dark room must still be able to rest); the bar itself only before that.
        if ambient > 0 { return lux < ambient * 0.75 }
        return lux < threshold * 1.5
    }
}

// MARK: Mission Control detection: when to ask the window server

/// Asking the window list is not free, so it is only done while there is something to fold away, or while Mission Control is
/// known to be up (to notice it ending). With the island (or a locked / pinned card) on screen it is asked often (`visibleInterval`)
/// because the island must get out of the way promptly; with nothing on screen only slowly, and not at all unless Mission Control
/// is up. The space-change notification mainly helps when Mission Control ends or the space switches; entering it is found by the
/// poll, so the notification is only a shortcut (`forced`).
enum MissionControlPolling {
    static let visibleInterval: TimeInterval = 0.2
    static let hiddenInterval: TimeInterval = 0.5

    static func shouldCheck(islandVisible: Bool, missionControlUp: Bool, sinceLast: TimeInterval, forced: Bool) -> Bool {
        guard islandVisible || missionControlUp else { return false }
        return forced || sinceLast >= (islandVisible ? visibleInterval : hiddenInterval)
    }
}

// MARK: - Sensor smoothing by elapsed time, not by sample count

/// The loop's rate changes (60 / 30 / 20 Hz), so averages and "no data for N seconds" must follow the clock.
enum SensorSmoothing {
    static let tau: TimeInterval = 1.65            // the old 0.98 per sample at 30 Hz
    static let silence: TimeInterval = 2           // no reading for this long: stop trusting the last one

    /// Exponential moving average with a time constant: the same result however often it is sampled.
    static func blend(_ old: Double, _ new: Double, dt: TimeInterval) -> Double {
        let keep = exp(-max(0, dt) / tau)
        return old * keep + new * (1 - keep)
    }
    static func isStale(silentFor: TimeInterval) -> Bool { silentFor >= silence }
}

extension SensorGestureMap {
    /// False when every gesture in every context is set to "no action": the light sensor then has nothing to do and is not polled.
    var anyGestureEnabled: Bool {
        for c in SensorContext.allCases {
            for g in SensorGesture.allCases where action(c, g) != .none { return true }
        }
        return false
    }
}

// MARK: - Alerts the system starts (not the user): wait while the user is busy

/// An alert nobody asked for (a Pomodoro phase, a finished timer, a meeting) must not pull the island open while the user is
/// typing or moving the pointer. It waits until the input has been quiet for `quiet` seconds, but never longer than `maxWait`.
enum AlertTiming {
    static let quiet: TimeInterval = 3
    static let maxWait: TimeInterval = 20

    static func shouldShow(secondsSinceInput: TimeInterval, waited: TimeInterval) -> Bool {
        secondsSinceInput >= quiet || waited >= maxWait
    }
}

// MARK: - Hover peek: the pointer must stay a moment

/// Brushing past the notch on the way to the menu bar must not make the island jump out: the pointer has to rest on it for
/// `dwell` first. Once the island is already out, staying on it needs no new wait.
enum HoverDwell {
    static let dwell: TimeInterval = 0.12

    static func met(enteredAt: Date, now: Date, alreadyOpen: Bool) -> Bool {
        alreadyOpen || now.timeIntervalSince(enteredAt) >= dwell
    }

    /// Leaving the notch for a moment (an edge jitter) does not forget the wait already done; only a stay away this long does.
    static let leaveGrace: TimeInterval = 0.08
    static func hasLeft(leftAt: Date, now: Date) -> Bool { now.timeIntervalSince(leftAt) >= leaveGrace }
}
