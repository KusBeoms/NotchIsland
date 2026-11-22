// Appended after AppTests.swift by run.sh (it uses makeTestApp() and the other helpers defined there).

// Never read or write the real preferences from here.
let testSuite = "com.kusbeoms.NotchIsland.tests"
Settings.store = UserDefaults(suiteName: testSuite)!
Settings.store.removePersistentDomain(forName: testSuite)

// Pomodoro: a finished phase starts the next one by itself and says so with a short alert; it never parks on a finished card.
let pomodoroApp = makeTestApp()
pomodoroApp.timer.startPomodoro(PomodoroConfig())
pomodoroApp.syncActivities()
assert(pomodoroApp.isActive(.timer) && pomodoroApp.timer.pomodoro?.phase == .work)
pomodoroApp.populate(pomodoroApp.c, bn: nil, kind: .timer)
assert(pomodoroApp.c.tLabel.stringValue == "집중 1/4")
pomodoroApp.timer.target = 0                                 // the work phase is over
pomodoroApp.step()
assert(pomodoroApp.timer.pomodoro?.phase == .rest && pomodoroApp.timer.running && !pomodoroApp.timer.finished)
assert(pomodoroApp.timer.target == 5 * 60 && pomodoroApp.alertText == "휴식 5분")
assert(pomodoroApp.selected != .timer)                        // the card is not taken over
pomodoroApp.populate(pomodoroApp.c, bn: nil, kind: .timer)
pomodoroApp.refreshSlots()
assert(pomodoroApp.c.tLabel.stringValue == "휴식")
assert((pomodoroApp.slotItems[.timer]?.icon as? TimerRing)?.pomodoro == .rest)
assert(pomodoroApp.activityName(.timer).hasPrefix("포모도로 휴식"))
pomodoroApp.timerCancelTapped()                              // cancel ends the whole set
assert(pomodoroApp.timer.pomodoro == nil && !pomodoroApp.timer.started)
pomodoroApp.refreshSlots()
assert((pomodoroApp.slotItems[.timer]?.icon as? TimerRing)?.pomodoro == nil)

// A plain countdown still stops on the finished card, as before.
let plainApp = makeTestApp()
plainApp.timer.startCountdown(minutes: 1)
plainApp.timer.target = 0
plainApp.step()
assert(plainApp.timer.pomodoro == nil && !plainApp.timer.running && plainApp.timer.finished && plainApp.selected == .timer)

print("Pomodoro app wiring checks passed")

// Microphone / camera: an activity while something records, with the generic info card; gone when it stops or is switched off.
let privacyApp = makeTestApp()
privacyApp.syncActivities()
assert(!privacyApp.isActive(.privacy) && privacyApp.acts.isEmpty)
privacyApp.privacy = PrivacyState(mic: true, camera: false, micApps: ["Zoom"])
privacyApp.syncActivities()
assert(privacyApp.isActive(.privacy) && privacyApp.acts == [.privacy])
assert(privacyApp.bodyFor(.privacy) == .info)
privacyApp.selected = .privacy; privacyApp.pinned = true
assert(privacyApp.body == .info)
privacyApp.populate(privacyApp.c, bn: nil, kind: .privacy)
assert(privacyApp.c.iTitle.stringValue == "마이크 사용 중" && privacyApp.c.iSub.stringValue == "Zoom")
assert(privacyApp.c.iIconName == "mic.fill" && !privacyApp.c.infoShowsBar)
privacyApp.refreshSlots()
assert(privacyApp.slotItems[.privacy]?.icon.identifier?.rawValue == "mic.fill")
assert(privacyApp.activityName(.privacy) == "마이크 사용 중: Zoom")
privacyApp.privacy = PrivacyState(mic: true, camera: true, micApps: ["Zoom"])         // the camera takes over the glyph and colour
privacyApp.populate(privacyApp.c, bn: nil, kind: .privacy)
privacyApp.refreshSlots()
assert(privacyApp.c.iTitle.stringValue == "카메라·마이크 사용 중" && privacyApp.c.iIconName == "video.fill")
assert(privacyApp.privacyColor == bannerGreen && privacyApp.slotItems[.privacy]?.icon.identifier?.rawValue == "video.fill")
Settings.setBool(Settings.Key.privacy, false)                                           // switched off in the settings window
privacyApp.syncActivities()
assert(!privacyApp.isActive(.privacy) && privacyApp.acts.isEmpty)
Settings.setBool(Settings.Key.privacy, true)
privacyApp.privacy = PrivacyState()                                                     // it stopped
privacyApp.syncActivities()
assert(privacyApp.acts.isEmpty)

print("Microphone / camera app wiring checks passed")

// Calendar: an event 4 minutes away becomes an activity and gets one alert; it goes away when the events do or it is switched off.
let calendarApp = makeTestApp()
calendarApp.syncActivities()
assert(!calendarApp.isActive(.calendar) && calendarApp.acts.isEmpty)
let soon = CalendarEvent(id: "t", title: "디자인 리뷰", location: "회의실 3",
                         start: Date().addingTimeInterval(4 * 60), end: Date().addingTimeInterval(64 * 60))
calendarApp.calendarEvents = [soon]
calendarApp.pollCalendar()
assert(calendarApp.isActive(.calendar) && calendarApp.acts == [.calendar] && calendarApp.bodyFor(.calendar) == .info)
assert(calendarApp.alertText == "4분 후 · 디자인 리뷰" && calendarApp.calendarAlerted.contains("t"))
calendarApp.alertText = nil
calendarApp.pollCalendar()
assert(calendarApp.alertText == nil)                                                    // one alert per event
calendarApp.selected = .calendar; calendarApp.pinned = true
assert(calendarApp.body == .info)
calendarApp.populate(calendarApp.c, bn: nil, kind: .calendar)
assert(calendarApp.c.iTitle.stringValue == "디자인 리뷰" && calendarApp.c.iIconName == "calendar")
assert(calendarApp.c.iTrail.stringValue == "4분" && calendarApp.c.iSub.stringValue.hasSuffix(" · 회의실 3") && !calendarApp.c.infoShowsBar)
calendarApp.refreshSlots()
assert((calendarApp.slotItems[.calendar]?.detail as? NSTextField)?.stringValue == "4분")
assert(calendarApp.activityName(.calendar) == "일정: 디자인 리뷰 (4분)")
Settings.setBool(Settings.Key.calendar, false)
calendarApp.syncActivities()
assert(!calendarApp.isActive(.calendar) && calendarApp.acts.isEmpty)                  // switched off in the settings window
Settings.setBool(Settings.Key.calendar, true)
calendarApp.syncActivities()
assert(calendarApp.acts == [.calendar])
calendarApp.calendarEvents = []                                                         // the event is gone
calendarApp.pollCalendar()
assert(calendarApp.acts.isEmpty)

print("Calendar app wiring checks passed")

// Transfers: a published download becomes an activity with a progress card, and disappears when it ends.
let transferApp = makeTestApp()
let transferDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ni-feature-transfer-\(getpid())")
try! FileManager.default.createDirectory(at: transferDir, withIntermediateDirectories: true)
transferApp.transferMonitor.start(folders: [transferDir])
let download = Progress(totalUnitCount: 100)
download.kind = .file; download.fileOperationKind = .downloading
download.fileURL = transferDir.appendingPathComponent("movie.mp4.crdownload")
download.publish()
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
transferApp.syncActivities()
assert(transferApp.transferMonitor.transfers.count == 1)
let transferID = transferApp.transferMonitor.transfers[0].id
assert(transferApp.isActive(.transfer(transferID)) && transferApp.acts == [.transfer(transferID)])
download.completedUnitCount = 40
RunLoop.main.run(until: Date().addingTimeInterval(0.4))                                 // the new value reaches the subscriber
transferApp.selected = .transfer(transferID); transferApp.pinned = true
assert(transferApp.body == .info)
transferApp.populate(transferApp.c, bn: nil, kind: .transfer(transferID))
assert(transferApp.c.iTitle.stringValue == "movie.mp4" && transferApp.c.iTrail.stringValue == "40%")
assert(transferApp.c.iIconName == "arrow.down.circle.fill" && transferApp.c.infoShowsBar && transferApp.c.iBar.fraction == 0.4)
assert(transferApp.c.iSub.stringValue.hasPrefix("다운로드 중"))
_ = transferApp.slotItem(.transfer(transferID))
transferApp.refreshSlots()
assert((transferApp.slotItems[.transfer(transferID)]?.detail as? NSTextField)?.stringValue == "40%")
assert(transferApp.activityName(.transfer(transferID)) == "다운로드 중: movie.mp4 40%")
Settings.setBool(Settings.Key.downloads, false)                                         // switched off in the settings window
transferApp.syncActivities()
assert(transferApp.acts.isEmpty)
Settings.setBool(Settings.Key.downloads, true)
transferApp.syncActivities()
assert(transferApp.acts == [.transfer(transferID)])
download.completedUnitCount = 100
download.unpublish()
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
transferApp.syncActivities()
assert(transferApp.transferMonitor.transfers.isEmpty && transferApp.acts.isEmpty)
assert(transferApp.slotItems[.transfer(transferID)] == nil)                             // its views are released with it
transferApp.transferMonitor.stop()
try? FileManager.default.removeItem(at: transferDir)

print("Transfer app wiring checks passed")

// Sensor gestures through the real App paths (covering = sensorTouchBegan, uncovering = sensorTouchEnded).
func sensorSpin(_ seconds: Double, _ app: App) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)); app.sensorTick() }     // what step() does each pass
}
Settings.sensorGestureMap = [:]

// defaults, closed with something running: reacts at once, held 0.3s it opens on the first activity
let sensorApp = makeTestApp()
sensorApp.timer.startStopwatch(); sensorApp.syncActivities()
assert(sensorApp.sensorContext == .closed && !sensorApp.pinned)
sensorApp.sensorTouchBegan()
assert(sensorApp.pressing && !sensorApp.pinned)
sensorSpin(0.45, sensorApp)
assert(sensorApp.pinned && sensorApp.selected == .timer && !sensorApp.pressing)
sensorApp.sensorTouchEnded()
assert(sensorApp.pinned)                                                                  // letting go does not close it

// defaults, open on a non-music, non-stopwatch card (a countdown): covering closes it at once, the countdown is untouched
let countApp = makeTestApp()
countApp.timer.startCountdown(minutes: 5); countApp.syncActivities()
countApp.selected = .timer; countApp.pinned = true
assert(countApp.sensorContext == .openOther)
countApp.sensorTouchBegan()
assert(!countApp.pinned && countApp.timer.running && countApp.timer.mode == .countdown)
countApp.sensorTouchEnded()
sensorSpin(0.5, countApp)
assert(countApp.timer.running)                                                            // nothing else fired later

// defaults, open on the stopwatch card: short = pause / resume (after the double-cover window), long = close, double = off
assert(sensorApp.sensorContext == .openStopwatch && sensorApp.timer.running)
sensorApp.sensorTouchBegan(); assert(sensorApp.pinned && sensorApp.timer.running)         // touching does nothing yet
sensorApp.sensorTouchEnded(); assert(sensorApp.timer.running)                              // waits for a possible second cover
sensorSpin(0.5, sensorApp)
assert(!sensorApp.timer.running && sensorApp.timer.started && sensorApp.pinned && sensorApp.sensorContext == .openStopwatch)   // paused, still a started stopwatch
sensorApp.syncActivities()
assert(sensorApp.acts.contains(.timer) && sensorApp.sensorContext == .openStopwatch)       // its card is still there
let pausedAt = sensorApp.timer.elapsed
sensorApp.sensorTouchBegan(); sensorApp.sensorTouchEnded()
sensorSpin(0.5, sensorApp)
assert(sensorApp.timer.running && sensorApp.timer.elapsed >= pausedAt && sensorApp.pinned)  // resumed
sensorApp.sensorTouchBegan()                                                              // long cover: closes, does not pause
sensorSpin(0.7, sensorApp)
assert(!sensorApp.pinned && sensorApp.timer.running)
sensorApp.sensorTouchEnded()
sensorSpin(0.5, sensorApp)
assert(!sensorApp.pinned && sensorApp.timer.running)                                      // no late pause from the release

let offApp = makeTestApp()
offApp.timer.startStopwatch(); offApp.syncActivities()
offApp.selected = .timer; offApp.pinned = true
offApp.sensorTouchBegan(); offApp.sensorTouchEnded()
offApp.sensorTouchBegan(); offApp.sensorTouchEnded()                                      // double cover: turned off
assert(!offApp.timer.started && !offApp.timer.running)
sensorSpin(0.5, offApp)
assert(!offApp.timer.started)                                                             // the first cover did not pause / resume it on its own
offApp.syncActivities()
assert(!offApp.acts.contains(.timer) && offApp.sensorContext != .openStopwatch)

// a paused stopwatch can be turned off too
let pausedOff = makeTestApp()
pausedOff.timer.startStopwatch(); pausedOff.timer.toggle(); pausedOff.syncActivities()
pausedOff.selected = .timer; pausedOff.pinned = true
assert(pausedOff.timer.started && !pausedOff.timer.running && pausedOff.sensorContext == .openStopwatch)
pausedOff.sensorTouchBegan(); pausedOff.sensorTouchEnded()
pausedOff.sensorTouchBegan(); pausedOff.sensorTouchEnded()
assert(!pausedOff.timer.started)

// the stopwatch gestures can be changed like any other (here: a short cover closes)
Settings.sensorGestureMap = [SensorGestureMap.key(.openStopwatch, .tap): SensorAction.closeIsland.rawValue]
let remapApp = makeTestApp()
remapApp.timer.startStopwatch(); remapApp.syncActivities()
remapApp.selected = .timer; remapApp.pinned = true
remapApp.sensorTouchBegan(); remapApp.sensorTouchEnded()
sensorSpin(0.5, remapApp)
assert(!remapApp.pinned && remapApp.timer.running)
Settings.sensorGestureMap = [:]

// defaults, closed and quick: nothing opens
let quickApp = makeTestApp()
quickApp.timer.startStopwatch(); quickApp.syncActivities()
quickApp.sensorTouchBegan(); quickApp.sensorTouchEnded()
sensorSpin(0.5, quickApp)
assert(!quickApp.pinned && !quickApp.pressing)

// a configured short cover on the closed island: it acts on release, and a hold still opens
Settings.sensorGestureMap = [SensorGestureMap.key(.closed, .tap): SensorAction.toggleTimer.rawValue]
let tapApp = makeTestApp()
tapApp.timer.startStopwatch(); tapApp.syncActivities()
assert(tapApp.timer.running)
tapApp.sensorTouchBegan(); tapApp.sensorTouchEnded()
assert(!tapApp.timer.running && !tapApp.pinned)                                           // paused by the tap
tapApp.sensorTouchBegan()
sensorSpin(0.45, tapApp)
tapApp.sensorTouchEnded()
assert(tapApp.pinned && tapApp.timer.started && !tapApp.timer.running)                    // the hold opened it, no extra tap action

// a double cover on an open island runs its action and does not also close it
Settings.sensorGestureMap = [SensorGestureMap.key(.openOther, .doubleTap): SensorAction.toggleTimer.rawValue]
let doubleApp = makeTestApp()
doubleApp.timer.startCountdown(minutes: 5); doubleApp.syncActivities()
doubleApp.selected = .timer; doubleApp.pinned = true
assert(doubleApp.sensorContext == .openOther && doubleApp.timer.running)
doubleApp.sensorTouchBegan(); doubleApp.sensorTouchEnded()
doubleApp.sensorTouchBegan(); doubleApp.sensorTouchEnded()
assert(!doubleApp.timer.running && doubleApp.pinned)
sensorSpin(0.5, doubleApp)
assert(doubleApp.pinned)                                                                  // no late "close" from the first cover
// ... while a single cover now closes after the double-tap window
doubleApp.sensorTouchBegan(); doubleApp.sensorTouchEnded()
assert(doubleApp.pinned)
sensorSpin(0.5, doubleApp)
assert(!doubleApp.pinned)

// actions with nothing to act on do nothing
Settings.sensorGestureMap = [SensorGestureMap.key(.closed, .hold): SensorAction.nextTrack.rawValue]
let noMediaApp = makeTestApp()
noMediaApp.timer.startStopwatch(); noMediaApp.syncActivities()
noMediaApp.sensorTouchBegan()
sensorSpin(0.45, noMediaApp)
noMediaApp.sensorTouchEnded()
assert(!noMediaApp.pinned)                                                                 // hold remapped away from "open"
Settings.sensorGestureMap = [:]

print("Sensor gesture app wiring checks passed")

// A system-started alert waits while the user is busy, then shows; a finished timer does not pop the card open under the user's hands
let quietApp = makeTestApp()
var shown = 0
quietApp.inputIdleSeconds = { 0.4 }
quietApp.whenQuiet { shown += 1; return true }
quietApp.runDeferredAlerts()
assert(shown == 0 && quietApp.deferredAlerts.count == 1)
quietApp.inputIdleSeconds = { 5 }
quietApp.runDeferredAlerts()
assert(shown == 1 && quietApp.deferredAlerts.isEmpty)
quietApp.whenQuiet { shown += 1; return true }
assert(shown == 2)                                                     // idle already: at once
let busyTimerApp = makeTestApp()
busyTimerApp.inputIdleSeconds = { 0.2 }
busyTimerApp.timer.startCountdown(minutes: 1); busyTimerApp.timer.target = 0
busyTimerApp.syncActivities()
busyTimerApp.step()
assert(busyTimerApp.timer.finished && !busyTimerApp.timer.running && !busyTimerApp.pinned && busyTimerApp.deferredAlerts.count == 1)
busyTimerApp.inputIdleSeconds = { 9 }
busyTimerApp.step()
assert(busyTimerApp.pinned && busyTimerApp.selected == .timer)
print("Deferred alert checks passed")

// Dragging the pointer past the threshold while pressing ends the long-press: it does not open the island half a second later
let dragApp = makeTestApp()
dragApp.timer.startStopwatch(); dragApp.syncActivities()
dragApp.pressBegan()
assert(dragApp.pressing && dragApp.longPressTimer != nil)
dragApp.view.onPressMoved = { [weak dragApp] in dragApp?.pressMoved() }
dragApp.view.onPressMoved?()
assert(!dragApp.pressing && dragApp.longPressTimer == nil)
dragApp.pressEnded(inside: true)
assert(!dragApp.pinned)                                                // not a tap either
assert(FileDragView.dragThreshold == 4)
print("Press drag threshold checks passed")

// A4: switching every gesture off and on again leaves no stale cover behind (no phantom hold, no tap)
Settings.sensorGestureMap = [:]
let resetApp = makeTestApp()
resetApp.lightBase = 400; resetApp.ambient = 400; resetApp.darkLatched = true; resetApp.lux = 1; resetApp.dropSince = Date()
_ = resetApp.sensorRecognizer.down(at: hardwareSeconds(), context: .closed, map: SensorGestureMap())
resetApp.pressing = true
resetApp.resetSensorState()
assert(!resetApp.darkLatched && resetApp.lux == -1 && resetApp.dropSince == nil && resetApp.recoveredSince == nil)
assert(resetApp.lightBase == -1 && resetApp.ambient == -1 && resetApp.sensorRecognizer.isIdle && !resetApp.pressing)
resetApp.timer.startStopwatch(); resetApp.syncActivities()
sensorSpin(0.6, resetApp)
assert(!resetApp.pinned)                                                                  // the cancelled cover never matures into an open

// A5: queued alerts re-check the state, run one at a time and in order
let queueApp = makeTestApp()
var order: [Int] = []
queueApp.inputIdleSeconds = { 0 }
queueApp.whenQuiet { order.append(1); return true }
queueApp.whenQuiet { order.append(2); return true }
queueApp.whenQuiet { order.append(3); return false }                                       // stale: dropped without showing
queueApp.whenQuiet { order.append(4); return true }
assert(order.isEmpty && queueApp.deferredAlerts.count == 4)
queueApp.inputIdleSeconds = { 10 }
queueApp.runDeferredAlerts()
assert(order == [1] && queueApp.deferredAlerts.count == 3)                                  // one per pass
queueApp.alertText = "on screen"; queueApp.alertUntil = Date().addingTimeInterval(5)
queueApp.runDeferredAlerts()
assert(order == [1])                                                                       // waits while an alert is showing
queueApp.alertText = nil
queueApp.runDeferredAlerts()
assert(order == [1, 2] && queueApp.deferredAlerts.count == 2)
queueApp.runDeferredAlerts()
assert(order == [1, 2, 3, 4] && queueApp.deferredAlerts.isEmpty)                            // the stale one is skipped on the spot
// a finished timer that was restarted before its turn is not announced
let staleApp = makeTestApp()
staleApp.inputIdleSeconds = { 0 }
staleApp.timer.startCountdown(minutes: 1); staleApp.timer.target = 0
staleApp.syncActivities(); staleApp.step()
assert(staleApp.deferredAlerts.count == 1 && staleApp.timer.finished)
staleApp.timer.reset()                                                                     // cancelled meanwhile
staleApp.inputIdleSeconds = { 10 }
staleApp.step()
assert(staleApp.deferredAlerts.isEmpty && !staleApp.pinned && staleApp.selected == nil)
// A9: cancelling a press also drops the sensor's pending touch and the pop-out
let cancelApp = makeTestApp()
cancelApp.timer.startStopwatch(); cancelApp.syncActivities()
_ = cancelApp.sensorRecognizer.down(at: hardwareSeconds(), context: .closed, map: SensorGestureMap())
cancelApp.popUntil = Date().addingTimeInterval(5); cancelApp.lyricsHoldFired = true
cancelApp.cancelPress()
assert(cancelApp.sensorRecognizer.isIdle && cancelApp.popUntil <= Date() && !cancelApp.lyricsHoldFired)
print("Sensor reset, queued alert and press cancel checks passed")

// B: mirroring the built-in display takes the island off screen and back; its state keeps running and nothing shows meanwhile
Settings.sensorGestureMap = [:]
let mirroredList = [DisplayMirrorInfo(id: 1, isBuiltin: true, inMirrorSet: true, mirrorsDisplay: 0), DisplayMirrorInfo(id: 2, isBuiltin: false, inMirrorSet: true, mirrorsDisplay: 1)]
let plainList = [DisplayMirrorInfo(id: 1, isBuiltin: true, inMirrorSet: false, mirrorsDisplay: 0)]
let mirrorApp = makeTestApp()
mirrorApp.timer.startStopwatch(); mirrorApp.syncActivities()
mirrorApp.selected = .timer; mirrorApp.pinned = true; mirrorApp.shape = .expanded
mirrorApp.mirrorInfo = { mirroredList }
mirrorApp.pressing = true; mirrorApp.dragActive = true; mirrorApp.hudUntil = Date().addingTimeInterval(5)
mirrorApp.applyMirroring()
assert(mirrorApp.mirrorHidden && mirrorApp.windowsHidden && !mirrorApp.panel.isVisible)
assert(!mirrorApp.pressing && !mirrorApp.dragActive && mirrorApp.hudUntil <= Date())
assert(mirrorApp.desiredShape() == .collapsed && mirrorApp.pinned)                         // nothing is drawn, the pinned card is remembered
assert(!mirrorApp.stepNeedsFullRate)                                                       // no 60 Hz loop for an invisible island
assert(!mirrorApp.handleMediaKey(0, true, false))                                           // volume keys go to the system (and its HUD)
mirrorApp.showBanner(.battery(title: "x", level: 80, color: .white)); assert(mirrorApp.banner == nil)
mirrorApp.trackFileDrag(NSPoint(x: 0, y: 0)); assert(!mirrorApp.dragActive && !mirrorApp.dragNear)
mirrorApp.showAlert("hidden", seconds: 3)
assert(mirrorApp.alertText == nil)                                                          // no alert for an invisible island
mirrorApp.inputIdleSeconds = { 0 }
mirrorApp.whenQuiet { true }
assert(mirrorApp.deferredAlerts.count == 1)                                                 // queued until it is back
mirrorApp.deferredAlerts[0].since = .distantPast
mirrorApp.runDeferredAlerts()
assert(mirrorApp.deferredAlerts.count == 1 && mirrorApp.timer.running)                      // the timer itself keeps running
// a list that cannot be read keeps the state (no flash of the island)
mirrorApp.mirrorInfo = { nil }; mirrorApp.applyMirroring()
assert(mirrorApp.mirrorHidden && mirrorApp.windowsHidden)
mirrorApp.mirrorInfo = { [] }; mirrorApp.applyMirroring()
assert(mirrorApp.mirrorHidden)
// switching the setting off brings it back at once, through settingsChanged
mirrorApp.mirrorInfo = { mirroredList }
Settings.setBool(Settings.Key.hideMirroring, false)
mirrorApp.settingsChanged()
assert(!mirrorApp.mirrorHidden && !mirrorApp.windowsHidden)
assert(mirrorApp.deferredAlerts[0].since > Date().addingTimeInterval(-5))                   // the wait starts when it is visible again
mirrorApp.runDeferredAlerts()
assert(mirrorApp.deferredAlerts.count == 1)                                                 // the user is typing: not shown the instant it returns
mirrorApp.inputIdleSeconds = { 10 }
mirrorApp.runDeferredAlerts()
assert(mirrorApp.deferredAlerts.isEmpty)
Settings.setBool(Settings.Key.hideMirroring, true)
mirrorApp.mirrorInfo = { plainList }
mirrorApp.applyMirroring()
assert(!mirrorApp.mirrorHidden)
// the lock state is asked from the session, not from the notice; a locked screen hides the windows too
let screenLockApp = makeTestApp()
screenLockApp.lockProbe = { true }
screenLockApp.applyLockState()
assert(screenLockApp.screenLocked && screenLockApp.windowsHidden && screenLockApp.islandSuppressed)
screenLockApp.lockProbe = { false }
screenLockApp.applyLockState()
assert(!screenLockApp.screenLocked && !screenLockApp.windowsHidden)
// queued alerts are capped
let alertCapApp = makeTestApp()
alertCapApp.inputIdleSeconds = { 0 }
for _ in 0..<9 { alertCapApp.whenQuiet { true } }
assert(alertCapApp.deferredAlerts.count == 5)
// every gesture off (or the island hidden): the sensor is dropped, even with the test light value in place
Settings.sensorGestureMap = [:]
let sensorOffApp = makeTestApp()
sensorOffApp.step()
assert(sensorOffApp.sensorWasOn && sensorOffApp.lux == 1000)
var allOff: [String: String] = [:]
for c in SensorContext.allCases { for g in SensorGesture.allCases { allOff[SensorGestureMap.key(c, g)] = SensorAction.none.rawValue } }
Settings.sensorGestureMap = allOff
sensorOffApp.tSensorConfig = 0
sensorOffApp.step()
assert(!sensorOffApp.sensorWasOn && sensorOffApp.lux == -1 && !sensorOffApp.darkLatched)
Settings.sensorGestureMap = [:]
print("Mirroring checks passed")
