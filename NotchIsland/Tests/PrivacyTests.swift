import Foundation

// The texts of the microphone / camera card and the rules that keep false alarms out. No hardware is touched.
@main
struct PrivacyTests {
    static func main() {
        var s = PrivacyState()
        assert(!s.isActive)
        s.mic = true; s.micApps = ["Zoom"]
        assert(s.isActive && s.title == "마이크 사용 중" && s.subtitle == "Zoom")
        s.micApps = ["FaceTime", "Zoom"]
        assert(s.subtitle == "FaceTime, Zoom")
        s.micApps = ["A", "B", "C", "D"]
        assert(s.subtitle == "A, B 외 2")
        s.camera = true
        assert(s.title == "카메라·마이크 사용 중")
        s.mic = false; s.micApps = []
        assert(s.isActive && s.title == "카메라 사용 중" && s.subtitle.isEmpty)   // the camera's owner is not knowable

        // Hey Siri's always-open microphone is not "recording"; real apps are.
        assert(PrivacyRules.ignored(bundleID: "com.apple.CoreSpeech"))
        assert(!PrivacyRules.ignored(bundleID: "us.zoom.xos"))
        assert(!PrivacyRules.ignored(bundleID: "com.apple.Siri"))                // Siri that you invoked is shown

        // A helper process is named after the app that owns it: the longest matching bundle ID, on a dot boundary.
        let running = ["company.thebrowser.browser", "company.thebrowser", "com.google.Chrome", "org.mozilla.firefox"]
        assert(PrivacyRules.owner(of: "company.thebrowser.browser.helper", among: running) == "company.thebrowser.browser")
        assert(PrivacyRules.owner(of: "com.google.Chrome.helper.Renderer", among: running) == "com.google.Chrome")
        assert(PrivacyRules.owner(of: "org.mozilla.firefox", among: running) == "org.mozilla.firefox")
        assert(PrivacyRules.owner(of: "com.google.ChromeX", among: running) == nil)   // a prefix must end at a dot
        assert(PrivacyRules.owner(of: "", among: running) == nil)

        // The monitor itself: starting and stopping repeatedly must be safe, and stop() leaves nothing reported.
        let monitor = PrivacyMonitor()
        monitor.stop()                                                              // before start: harmless
        monitor.start(); monitor.start()
        monitor.stop(); monitor.stop()
        assert(monitor.state == PrivacyState())
        print("Microphone / camera state texts, ignore rules and monitor lifecycle checks passed")
    }
}
