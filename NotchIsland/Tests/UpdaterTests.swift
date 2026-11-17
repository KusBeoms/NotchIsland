import Foundation

// Update rules (versions, release JSON, trusted URLs) and the installer's checks on real bundles in a temporary folder.
// The "same identity" cases need the local signing identity (make-signing-cert.sh); without it they are skipped.
@main
struct UpdaterTests {
    static let fm = FileManager.default
    static let keychain = NSHomeDirectory() + "/Library/Keychains/notchisland-signing.keychain-db"
    static let identity = "NotchIsland Local Signing"

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    static func hasIdentity() -> Bool {
        guard fm.fileExists(atPath: keychain) else { return false }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-identity", "-p", "codesigning", keychain]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try! p.run()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return text.contains(identity)
    }

    /// A minimal signed app bundle: `signed` = with the local identity, otherwise ad-hoc.
    static func makeApp(in dir: URL, id: String, version: String, signed: Bool) -> URL {
        let app = dir.appendingPathComponent("NotchIsland.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try! fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try! fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appendingPathComponent("NotchIsland"))
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleVersion": version,
                                   "CFBundleExecutable": "NotchIsland", "CFBundlePackageType": "APPL", "CFBundleName": "NotchIsland"]
        try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if signed {
            run("/usr/bin/security", ["unlock-keychain", "-p", "", keychain])
            assert(run("/usr/bin/codesign", ["--force", "--sign", identity, "--keychain", keychain, app.path]) == 0)
        } else {
            assert(run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) == 0)
        }
        return app
    }

    static func zip(_ app: URL, to zip: URL) {
        assert(run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path]) == 0)
    }

    static func fresh(_ name: String, _ root: URL) -> URL {
        let d = root.appendingPathComponent(name)
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The message a throwing call fails with, nil when it succeeds.
    static func failure(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return (error as? UpdateError)?.description ?? "\(error)" }
    }

    static func release(_ version: String, sha256: String? = nil) -> UpdateRelease {
        UpdateRelease(version: version, url: URL(string: "https://github.com/\(UpdateRules.repo)/releases/download/v\(version)/\(UpdateRules.assetName)")!, sha256: sha256)
    }

    static func main() {
        // MARK: versions
        assert(UpdateRules.components("v2.0") == [2, 0] && UpdateRules.components("2.10.3") == [2, 10, 3])
        assert(UpdateRules.components("2.0-beta") == nil && UpdateRules.components("nightly") == nil)
        assert(UpdateRules.components("") == nil && UpdateRules.components("v") == nil && UpdateRules.components("1..2") == nil)
        assert(UpdateRules.components("1.2.3.4.5") == nil && UpdateRules.components("١.٢") == nil)          // too long; non-ASCII digits
        assert(UpdateRules.isNewer("2.1", than: "2.0") && UpdateRules.isNewer("v2.0.1", than: "2.0"))
        assert(UpdateRules.isNewer("2.10", than: "2.9"))                                                  // numeric, not textual
        assert(UpdateRules.isNewer("3", than: "2.9.9"))
        assert(!UpdateRules.isNewer("2.0", than: "2.0") && !UpdateRules.isNewer("2.0.0", than: "2.0"))
        assert(!UpdateRules.isNewer("1.9", than: "2.0"))                                                  // never downgrade
        assert(!UpdateRules.isNewer("2.1-beta", than: "2.0") && !UpdateRules.isNewer("2.1", than: "dev"))

        // MARK: trusted download links
        func url(_ s: String) -> URL { URL(string: s)! }
        let base = "https://github.com/\(UpdateRules.repo)/releases/download/v2.1/\(UpdateRules.assetName)"
        assert(UpdateRules.isTrustedDownload(url(base)))
        assert(!UpdateRules.isTrustedDownload(url(base.replacingOccurrences(of: "https", with: "http"))))
        assert(!UpdateRules.isTrustedDownload(url("https://evil.example/\(UpdateRules.repo)/releases/download/v2.1/a.zip")))
        assert(!UpdateRules.isTrustedDownload(url("https://github.com.evil.example/\(UpdateRules.repo)/releases/download/v2.1/a.zip")))
        assert(!UpdateRules.isTrustedDownload(url("https://github.com/someone/else/releases/download/v2.1/a.zip")))

        // MARK: release JSON
        let hex = String(repeating: "ab", count: 32)
        func json(tag: String = "v2.1", draft: Bool = false, pre: Bool = false, name: String = UpdateRules.assetName,
                  link: String = base, digest: String? = "sha256:" + String(repeating: "ab", count: 32)) -> Data {
            var asset: [String: Any] = ["name": name, "browser_download_url": link]
            if let digest { asset["digest"] = digest }
            return try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": pre, "assets": [asset]])
        }
        let parsed = UpdateRules.parseRelease(json())
        assert(parsed == UpdateRelease(version: "2.1", url: url(base), sha256: hex))
        assert(UpdateRules.parseRelease(json(tag: "2.1"))?.version == "2.1")
        assert(UpdateRules.parseRelease(json(digest: nil))?.sha256 == nil)
        assert(UpdateRules.parseRelease(json(digest: "sha256:xyz"))?.sha256 == nil)                       // malformed digest is ignored, not trusted
        assert(UpdateRules.parseRelease(json(digest: "sha1:" + hex))?.sha256 == nil)
        assert(UpdateRules.parseRelease(json(draft: true)) == nil && UpdateRules.parseRelease(json(pre: true)) == nil)
        assert(UpdateRules.parseRelease(json(tag: "2.1-beta")) == nil)
        assert(UpdateRules.parseRelease(json(name: "other.zip")) == nil)
        assert(UpdateRules.parseRelease(json(link: "https://evil.example/NotchIsland-arm64.zip")) == nil)
        assert(UpdateRules.parseRelease(Data("not json".utf8)) == nil && UpdateRules.parseRelease(Data("{}".utf8)) == nil)

        // MARK: installer, on real bundles
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ni-updater-test-\(getpid())")
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // an ad-hoc signed app has no identity to compare, so it must not install anything by itself
        let adhocDir = fresh("adhoc", root)
        let adhoc = makeApp(in: adhocDir, id: "com.test.NotchIsland", version: "1.0", signed: false)
        assert(UpdateInstaller.installBlocker(app: adhoc) != nil)
        assert(UpdateInstaller.installBlocker(app: adhocDir.appendingPathComponent("tool")) != nil)       // not an .app
        let newDir = fresh("new", root)
        let newAdhoc = makeApp(in: newDir, id: "com.test.NotchIsland", version: "1.1", signed: false)
        let newZip = root.appendingPathComponent("new.zip")
        zip(newAdhoc, to: newZip)
        func staged(_ zipURL: URL, _ rel: UpdateRelease, current: URL, _ currentVersion: String, _ name: String) -> String? {
            let copy = root.appendingPathComponent("copy-\(name).zip")
            try? fm.removeItem(at: copy)
            try! fm.copyItem(at: zipURL, to: copy)
            return failure { _ = try UpdateInstaller.stage(downloaded: copy, release: rel, currentApp: current, currentVersion: currentVersion,
                                                           root: root.appendingPathComponent("staging-\(name)")) }
        }
        assert(staged(newZip, release("1.1"), current: adhoc, "1.0", "adhoc") == "서명을 확인할 수 없습니다")
        assert(!fm.fileExists(atPath: root.appendingPathComponent("staging-adhoc").path))                 // a failed stage cleans up after itself

        // GitHub's digest must match
        assert(staged(newZip, release("1.1", sha256: hex), current: adhoc, "1.0", "sha") == "내려받은 파일이 손상되었습니다")
        let realDigest = try! UpdateInstaller.sha256Hex(of: newZip)
        assert(realDigest.count == 64 && realDigest == (try! UpdateInstaller.sha256Hex(of: newZip)))
        assert(staged(newZip, release("1.1", sha256: realDigest), current: adhoc, "1.0", "shaok") == "서명을 확인할 수 없습니다")   // digest passes, then the signature check refuses

        // a zip must hold exactly NotchIsland.app
        let extraDir = fresh("extra", root)
        _ = makeApp(in: extraDir, id: "com.test.NotchIsland", version: "1.1", signed: false)
        try! "x".write(to: extraDir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let extraZip = root.appendingPathComponent("extra.zip")
        assert(run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", extraDir.path, extraZip.path]) == 0)    // the app plus a stray file at the top level
        assert(staged(extraZip, release("1.1"), current: adhoc, "1.0", "layout") == "릴리스 구성이 올바르지 않습니다")
        let junk = root.appendingPathComponent("junk.zip")
        try! Data("this is not a zip".utf8).write(to: junk)
        assert(staged(junk, release("1.1"), current: adhoc, "1.0", "junk") == "압축을 풀 수 없습니다")

        guard hasIdentity() else {
            print("updater tests passed (same-identity cases skipped: run ./make-signing-cert.sh to cover them)")
            return
        }

        // same signing identity: the happy path and each way it must still be refused
        let curDir = fresh("current", root)
        let current = makeApp(in: curDir, id: "com.test.NotchIsland", version: "1.0", signed: true)
        assert(UpdateInstaller.installBlocker(app: current) == nil)

        func candidate(_ name: String, id: String = "com.test.NotchIsland", version: String = "1.1", signed: Bool = true) -> URL {
            let dir = fresh("cand-\(name)", root)
            let app = makeApp(in: dir, id: id, version: version, signed: signed)
            let z = root.appendingPathComponent("cand-\(name).zip")
            zip(app, to: z)
            return z
        }
        assert(staged(candidate("ok"), release("1.1"), current: current, "1.0", "ok") == nil)
        assert(staged(candidate("ad", signed: false), release("1.1"), current: current, "1.0", "ad") == "서명이 현재 앱과 다릅니다")
        assert(staged(candidate("id", id: "com.other.App"), release("1.1"), current: current, "1.0", "id") == "다른 앱입니다")
        assert(staged(candidate("same", version: "1.0"), release("1.0"), current: current, "1.0", "same") == "새 버전이 아닙니다")
        assert(staged(candidate("old", version: "0.9"), release("0.9"), current: current, "1.0", "old") == "새 버전이 아닙니다")
        assert(staged(candidate("mismatch"), release("1.2"), current: current, "1.0", "mismatch") == "릴리스와 앱의 버전이 다릅니다")

        // swap: the installed bundle is replaced in place and still validates
        var stagedApp: URL!
        do {
            let copy = root.appendingPathComponent("copy-swap.zip")
            try! fm.copyItem(at: candidate("swap"), to: copy)
            stagedApp = try! UpdateInstaller.stage(downloaded: copy, release: release("1.1"), currentApp: current, currentVersion: "1.0",
                                                   root: root.appendingPathComponent("staging-swap"))
        }
        try! UpdateInstaller.swap(staged: stagedApp, over: current)
        assert(UpdateInstaller.info(of: current)?["CFBundleShortVersionString"] as? String == "1.1")
        assert(UpdateInstaller.installBlocker(app: current) == nil)
        assert(!fm.fileExists(atPath: stagedApp.path))

        print("updater tests passed")
    }
}
