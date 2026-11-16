import Foundation

// The sensor gesture rules with made-up times. The defaults must equal what the sensor did before it was configurable.
@main
struct SensorGestureTests {
    typealias R = SensorGestureRecognizer

    static func main() {
        let map = SensorGestureMap()

        // ---- the map
        assert(map.action(.closed, .hold) == .openIsland && map.action(.closed, .tap) == .none && map.action(.closed, .doubleTap) == .none)
        assert(map.action(.openMusic, .tap) == .closeIsland && map.action(.openMusic, .hold) == .lyrics)
        assert(map.action(.openOther, .tap) == .closeIsland && map.action(.openOther, .hold) == .none)
        var m = map
        m.set(.playPause, .openOther, .doubleTap)
        assert(m.action(.openOther, .doubleTap) == .playPause && m.stored["openOther.doubleTap"] == "playPause")
        m.set(.none, .openOther, .doubleTap)                                       // back to the default: nothing stays stored
        assert(m.stored.isEmpty && m == map)
        // an invalid or not allowed stored value falls back to the default
        assert(SensorGestureMap(["closed.hold": "bogus"]).action(.closed, .hold) == .openIsland)
        assert(SensorGestureMap(["openOther.tap": "openIsland"]).action(.openOther, .tap) == .closeIsland)   // cannot open an open island
        assert(SensorGestureMap(["closed.tap": "lyrics"]).action(.closed, .tap) == .none)                   // lyrics need the music card
        assert(SensorGestureMap.allowedActions(.closed).contains(.openIsland) && !SensorGestureMap.allowedActions(.closed).contains(.closeIsland))
        assert(SensorGestureMap.allowedActions(.openMusic).contains(.lyrics) && !SensorGestureMap.allowedActions(.openOther).contains(.lyrics))
        for c in SensorContext.allCases {                                          // every default is an allowed choice
            for g in SensorGesture.allCases { assert(SensorGestureMap.allowedActions(c).contains(SensorGestureMap.defaultAction(c, g))) }
        }

        // ---- default behaviour, as before
        // open, any other card: closes the moment it is covered
        var r = R()
        let ev = r.down(at: 0, context: .openOther, map: map)
        assert(ev == [.init(gesture: .tap, action: .closeIsland, context: .openOther)])
        assert(r.up(at: 0.5).isEmpty && r.tick(at: 1).isEmpty)

        // open music card: a short cover closes on release; keeping it covered toggles the lyrics instead (not both)
        r = R()
        assert(r.down(at: 0, context: .openMusic, map: map).isEmpty)
        assert(r.up(at: 0.2) == [.init(gesture: .tap, action: .closeIsland, context: .openMusic)])
        r = R()
        assert(r.down(at: 0, context: .openMusic, map: map).isEmpty)
        assert(r.tick(at: 0.44).isEmpty)
        assert(r.tick(at: 0.46) == [.init(gesture: .hold, action: .lyrics, context: .openMusic)])
        assert(r.tick(at: 0.9).isEmpty && r.up(at: 1.0).isEmpty)                    // held: fires once, release does nothing

        // closed: nothing on a short cover; held 0.3s opens
        r = R()
        assert(r.down(at: 0, context: .closed, map: map).isEmpty)
        assert(r.up(at: 0.1).isEmpty && r.tick(at: 1).isEmpty)
        r = R()
        assert(r.down(at: 0, context: .closed, map: map).isEmpty && r.tick(at: 0.29).isEmpty)
        assert(r.tick(at: 0.31) == [.init(gesture: .hold, action: .openIsland, context: .closed)])

        // ---- configured
        // a double tap on the other cards: the single tap now waits for the window
        var d = map
        d.set(.playPause, .openOther, .doubleTap)
        r = R()
        assert(r.down(at: 0, context: .openOther, map: d).isEmpty)                  // no longer acts on touch
        assert(r.up(at: 0.1).isEmpty)
        assert(r.tick(at: 0.3).isEmpty)                                             // still inside the window
        assert(r.tick(at: 0.5) == [.init(gesture: .tap, action: .closeIsland, context: .openOther)])   // lone tap, a little late
        assert(r.tick(at: 0.6).isEmpty)
        r = R()
        assert(r.down(at: 0, context: .openOther, map: d).isEmpty && r.up(at: 0.1).isEmpty)
        assert(r.down(at: 0.25, context: .openOther, map: d).isEmpty)
        assert(r.up(at: 0.32) == [.init(gesture: .doubleTap, action: .playPause, context: .openOther)])
        assert(r.tick(at: 1).isEmpty)                                               // the first tap was swallowed by the double tap
        // the second cover starts after the window: two single taps
        r = R()
        assert(r.down(at: 0, context: .openOther, map: d).isEmpty && r.up(at: 0.1).isEmpty)
        let late = r.down(at: 0.6, context: .openOther, map: d)
        assert(late == [.init(gesture: .tap, action: .closeIsland, context: .openOther)])
        assert(r.up(at: 0.7).isEmpty)
        assert(r.tick(at: 1.2) == [.init(gesture: .tap, action: .closeIsland, context: .openOther)])
        // the island changed between the two covers: the first tap stands alone
        r = R()
        assert(r.down(at: 0, context: .openOther, map: d).isEmpty && r.up(at: 0.1).isEmpty)
        assert(r.down(at: 0.2, context: .closed, map: d) == [.init(gesture: .tap, action: .closeIsland, context: .openOther)])

        // a tap mapped on a closed island acts on release (a hold is possible there), and a hold still opens it
        var t = map
        t.set(.nextTrack, .closed, .tap)
        r = R()
        assert(r.down(at: 0, context: .closed, map: t).isEmpty)
        assert(r.up(at: 0.15) == [.init(gesture: .tap, action: .nextTrack, context: .closed)])
        r = R()
        assert(r.down(at: 0, context: .closed, map: t).isEmpty)
        assert(r.tick(at: 0.35) == [.init(gesture: .hold, action: .openIsland, context: .closed)])
        assert(r.up(at: 0.5).isEmpty)

        // every gesture switched off in a context: nothing fires
        var off = map
        off.set(.none, .openOther, .tap)
        r = R()
        assert(r.down(at: 0, context: .openOther, map: off).isEmpty && r.up(at: 0.1).isEmpty && r.tick(at: 1).isEmpty)

        // cancel forgets a finger that is down and a waiting tap
        r = R()
        _ = r.down(at: 0, context: .openMusic, map: map)
        r.cancel()
        assert(!r.isDown && r.tick(at: 5).isEmpty && r.up(at: 5).isEmpty)

        print("Sensor gesture map, defaults, hold / double-tap timing checks passed")
    }
}
