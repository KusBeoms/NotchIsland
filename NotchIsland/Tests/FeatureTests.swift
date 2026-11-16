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

// defaults, open on a non-music card: covering closes it at once
assert(sensorApp.sensorContext == .openOther)
sensorApp.sensorTouchBegan()
assert(!sensorApp.pinned)
sensorApp.sensorTouchEnded()

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
doubleApp.timer.startStopwatch(); doubleApp.syncActivities()
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
