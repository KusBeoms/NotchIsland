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
            let status = run("/usr/bin/codesign", ["--force", "--sign", identity, "--keychain", keychain, app.path]); assert(status == 0)
        } else {
            let status = run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]); assert(status == 0)
        }
        return app
    }

    static func zip(_ app: URL, to zip: URL) {
        let status = run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path]); assert(status == 0)
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
        assert(UpdateRules.components("01.2") == nil && UpdateRules.components("2.01") == nil && UpdateRules.components("0.0") == [0, 0])   // no leading zeros, like build.sh
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

        // MARK: redirect host allow-list
        assert(UpdateRules.isAllowedRedirect(url("https://objects.githubusercontent.com/a/b")))
        assert(UpdateRules.isAllowedRedirect(url("https://release-assets.githubusercontent.com/a")))
        assert(UpdateRules.isAllowedRedirect(url("https://GitHub.com/\(UpdateRules.repo)/x")))
        assert(!UpdateRules.isAllowedRedirect(url("http://objects.githubusercontent.com/a")))              // no downgrade
        assert(!UpdateRules.isAllowedRedirect(url("https://evil.example/a")))
        assert(!UpdateRules.isAllowedRedirect(url("https://objects.githubusercontent.com.evil.example/a")))
        assert(!UpdateRules.isAllowedRedirect(url("https://evilgithubusercontent.com/a")))
        assert(!UpdateRules.isAllowedRedirect(nil))

        // port, credentials and CDN sub-domains
        assert(!UpdateRules.isAllowedRedirect(url("https://objects.githubusercontent.com:8443/a")))
        assert(UpdateRules.isAllowedRedirect(url("https://objects.githubusercontent.com:443/a")))
        assert(!UpdateRules.isAllowedRedirect(url("https://user@objects.githubusercontent.com/a")))
        assert(!UpdateRules.isAllowedRedirect(url("https://user:pw@github.com/a")))
        assert(!UpdateRules.isTrustedDownload(url("https://github.com:8443/\(UpdateRules.repo)/releases/download/v2.1/a.zip")))
        assert(!UpdateRules.isTrustedDownload(url("https://user@github.com/\(UpdateRules.repo)/releases/download/v2.1/a.zip")))
        assert(UpdateRules.isTrustedDownload(url("https://github.com:443/\(UpdateRules.repo)/releases/download/v2.1/a.zip")))
        assert(UpdateRules.isAllowedRedirect(url("https://new-cdn.githubusercontent.com/a")))              // exactly one label below the domain
        for host in ["raw.githubusercontent.com", "gist.githubusercontent.com", "user-images.githubusercontent.com", "avatars.githubusercontent.com",
                     "a.b.githubusercontent.com", ".githubusercontent.com", "-x.githubusercontent.com", "x-.githubusercontent.com", "githubusercontent.com"] {
            assert(!UpdateRules.isAllowedRedirect(url("https://\(host)/a")))
        }
        assert(!UpdateRules.isAllowedRedirect(URL(string: "https://x\u{0430}.githubusercontent.com/a")))                 // a look-alike letter
        assert(!UpdateRules.isAllowedRedirect(url("https://githubusercontent.com.evil.example/a")))
        assert(!UpdateRules.isAllowedRedirect(url("https://x.githubusercontent.com.evil.example/a")))
        assert(!UpdateRules.isAllowedRedirect(url("https://evilgithubusercontent.com/a")))
        assert(!UpdateRules.isAllowedRedirect(url("https://sub.github.com/a")))                             // github.com itself: exact match only
        assert(UpdateRules.isRefusedRedirect(status: 302) && !UpdateRules.isRefusedRedirect(status: 200) && !UpdateRules.isRefusedRedirect(status: nil))

        // MARK: zip table of contents (before unpacking)
        func listing(_ entries: [String], declared: Int? = nil, header: Bool = true) -> String {
            var t = "Archive:  x.zip\n"
            if header { t += "Zip file size: 576 bytes, number of entries: \(declared ?? entries.count)\n" }
            t += entries.joined(separator: "\n") + "\n\(entries.count) files, 12 bytes uncompressed, 12 bytes compressed:  0.0%\n"
            return t
        }
        func entry(_ name: String, size: Int64 = 3, perms: String = "-rw-r--r--") -> String {
            "\(perms)  3.0 unx \(size) tx        3 stor 26-Nov-22 19:31 \(name)"
        }
        func zipFailure(_ text: String, maxBytes: Int64 = 1000, maxEntries: Int = 10) -> String? {
            failure { try ZipListing.validate(text, maxBytes: maxBytes, maxEntries: maxEntries) }
        }
        assert(zipFailure(listing([entry("NotchIsland.app/", size: 0, perms: "drwxr-xr-x"), entry("NotchIsland.app/Contents/Info.plist")])) == nil)
        assert(zipFailure(listing([entry("NotchIsland.app/Contents/My File  name.txt")])) == nil)              // spaces in the name
        assert(zipFailure(listing([entry("a", size: 600), entry("b", size: 600)])) == "압축을 푼 크기가 너무 큽니다")
        assert(zipFailure(listing([entry("a", size: 600), entry("b", size: 400)])) == nil)
        assert(zipFailure(listing((0..<11).map { entry("f\($0)") })) == "압축 파일에 항목이 너무 많습니다")
        assert(zipFailure(listing([entry("a")], declared: 11)) == "압축 파일에 항목이 너무 많습니다")
        assert(zipFailure(listing([entry("a"), entry("lnk", perms: "lrwxr-xr-x")])) == "릴리스에 심볼릭 링크가 들어 있습니다")
        assert(zipFailure(listing([entry("p", perms: "prw-r--r--")])) == "릴리스에 허용되지 않는 항목이 들어 있습니다")
        for bad in ["/etc/passwd", "../x", "a/../../x", "a/..", "\\evil", "a\\..\\x"] {
            assert(zipFailure(listing([entry(bad)])) == "릴리스에 허용되지 않는 경로가 들어 있습니다")
        }
        assert(zipFailure(listing([entry("a/..b/c..d")])) == nil)                                              // ".." only as a whole path element
        // anything unreadable is refused
        assert(zipFailure("") == "압축을 풀 수 없습니다")
        assert(zipFailure("Archive:  x.zip\n") == "압축을 풀 수 없습니다")
        assert(zipFailure(listing([entry("a")], header: false)) == "압축을 풀 수 없습니다")                      // no entry count: cannot cross-check
        assert(zipFailure(listing([entry("a")], declared: 2)) == "압축을 풀 수 없습니다")                         // count mismatch (a line was lost)
        assert(zipFailure(listing(["garbage line"])) == "압축을 풀 수 없습니다")
        assert(zipFailure(listing(["-rw-r--r--  3.0 unx notanumber tx 3 stor 26-Nov-22 19:31 a"])) == "압축을 풀 수 없습니다")
        assert(zipFailure(listing(["-rw-r--r--  3.0 unx 5 tx 3 stor 26-Nov-22 19:31"])) == "압축을 풀 수 없습니다")   // no name
        assert(zipFailure(listing([], declared: 0)) == "압축을 풀 수 없습니다")                                   // an empty archive is not a release

        // MARK: installer, on real bundles
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ni-updater-test-\(getpid())")
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // a zip whose central directory lies about the sizes passes the listing filter, but the unpacking is stopped when it grows
        do {
            let src = fresh("forge-src", root)
            let big = src.appendingPathComponent("big.bin")
            _ = fm.createFile(atPath: big.path, contents: nil)
            let handle = try! FileHandle(forWritingTo: big)
            try! handle.truncate(atOffset: 1_500_000_000)                                              // 1.5 GB of zeros (sparse here, a tiny zip)
            try! handle.close()
            let forged = root.appendingPathComponent("forged.zip")
            let zipStatus = run("/usr/bin/zip", ["-q", "-j", forged.path, big.path]); assert(zipStatus == 0)
            try! fm.removeItem(at: big)
            let limit: Int64 = 50_000_000
            assert(failure { try UpdateInstaller.inspectArchive(forged, maxBytes: limit) } == "압축을 푼 크기가 너무 큽니다")   // honest listing: refused up front
            var bytes = try! Data(contentsOf: forged)
            let signature: [UInt8] = [0x50, 0x4b, 0x01, 0x02]                                         // central directory file header
            let at = bytes.firstRange(of: signature)!.lowerBound
            bytes.replaceSubrange((at + 24)..<(at + 28), with: [0x0a, 0, 0, 0])                       // claims 10 bytes
            try! bytes.write(to: forged)
            assert(failure { try UpdateInstaller.inspectArchive(forged, maxBytes: limit) } == nil)    // the forged listing looks harmless
            let out = fresh("forge-out", root)
            let verdict = failure { try UpdateInstaller.extract(forged, to: out, maxBytes: limit, timeout: 120) }
            assert(verdict == "압축을 푼 크기가 너무 큽니다")                                              // stopped by the watch ...
            assert(UpdateInstaller.treeBytes(out, limit: .max) < 3 * limit)                            // ... long before the 1.5 GB were written
            try? fm.removeItem(at: out)
            // the same kind of archive, honest and within the limit, unpacks; the timeout also ends an unpacking
            let small = src.appendingPathComponent("small.bin")
            _ = fm.createFile(atPath: small.path, contents: nil)
            let h2 = try! FileHandle(forWritingTo: small)
            try! h2.truncate(atOffset: 40_000_000)
            try! h2.close()
            let honest = root.appendingPathComponent("honest.zip")
            let honestStatus = run("/usr/bin/zip", ["-q", "-j", honest.path, small.path]); assert(honestStatus == 0)
            let out2 = fresh("honest-out", root)
            assert(failure { try UpdateInstaller.extract(honest, to: out2, maxBytes: limit, timeout: 60) } == nil)
            let out3 = fresh("timeout-out", root)
            assert(failure { try UpdateInstaller.extract(honest, to: out3, maxBytes: 200_000_000, timeout: 0, pollInterval: 0.001) } == "압축을 푸는 데 너무 오래 걸립니다")
            // a disk that cannot hold the claimed size is refused before anything is written
            let out4 = fresh("space-out", root)
            assert(failure { try UpdateInstaller.extract(honest, to: out4, maxBytes: limit, expectedBytes: Int64.max / 4) } == "디스크 공간이 부족합니다")
            // everything unpacked must stay inside NotchIsland.app
            let tree = fresh("contain", root)
            try! fm.createDirectory(at: tree.appendingPathComponent("NotchIsland.app/Contents"), withIntermediateDirectories: true)
            assert(failure { try UpdateInstaller.ensureContained(tree) } == nil)
            try! "x".write(to: tree.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)
            assert(failure { try UpdateInstaller.ensureContained(tree) } == "릴리스에 허용되지 않는 경로가 들어 있습니다")
        }
        // a download path cannot climb out of the release prefix, and the host carries no escapes
        assert(!UpdateRules.isTrustedDownload(url("https://github.com/\(UpdateRules.repo)/releases/download/../../../evil/x.zip")))
        for evil in ["releases/download/%2e%2e/%2e%2e/x.zip", "releases/download/..%2fx.zip", "releases/download/a%2Fb.zip", "releases/download/./x.zip",
                     "releases/download/v1/../../x.zip", "releases/download%5Cx.zip"] {
            assert(!UpdateRules.isTrustedDownload(url("https://github.com/\(UpdateRules.repo)/\(evil)")))
        }
        assert(!UpdateRules.isTrustedDownload(url("https://github%2Ecom/\(UpdateRules.repo)/releases/download/v2.1/a.zip")))     // an encoded host

        // unpacked tree: symbolic links and total size
        do {
            let tree = fresh("tree-ok", root)
            try! Data(count: 1000).write(to: tree.appendingPathComponent("a.bin"))
            try! fm.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try! Data(count: 1000).write(to: tree.appendingPathComponent("sub/b.bin"))
            assert(failure { try UpdateInstaller.validateExtracted(tree) } == nil)
            assert(failure { try UpdateInstaller.validateExtracted(tree, maxBytes: 1999) } == "압축을 푼 크기가 너무 큽니다")
            assert(failure { try UpdateInstaller.validateExtracted(tree, maxBytes: 2000) } == nil)
            try! fm.createSymbolicLink(at: tree.appendingPathComponent("sub/link"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
            assert(failure { try UpdateInstaller.validateExtracted(tree) } == "릴리스에 심볼릭 링크가 들어 있습니다")
            // a hard link is one file: counted once; resource forks count too
            let hard = fresh("tree-hard", root)
            try! Data(count: 1000).write(to: hard.appendingPathComponent("a.bin"))
            try! fm.linkItem(at: hard.appendingPathComponent("a.bin"), to: hard.appendingPathComponent("b.bin"))
            assert(failure { try UpdateInstaller.validateExtracted(hard, maxBytes: 1500) } == nil)
            let forks = fresh("tree-forks", root)
            let forked = forks.appendingPathComponent("f.bin")
            try! Data(count: 10).write(to: forked)
            try! Data(count: 40_000).write(to: URL(fileURLWithPath: forked.path + "/..namedfork/rsrc"))      // a resource fork
            assert(failure { try UpdateInstaller.validateExtracted(forks, maxBytes: 20_000) } == "압축을 푼 크기가 너무 큽니다")
            let dangling = fresh("tree-dangling", root)
            try! fm.createSymbolicLink(at: dangling.appendingPathComponent("x"), withDestinationURL: URL(fileURLWithPath: "/nonexistent"))
            assert(failure { try UpdateInstaller.validateExtracted(dangling) } == "릴리스에 심볼릭 링크가 들어 있습니다")
        }

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

        // a release that contains a symbolic link is refused before any signature check
        do {
            let dir = fresh("linked", root)
            let app = makeApp(in: dir, id: "com.test.NotchIsland", version: "1.1", signed: false)
            try! fm.createSymbolicLink(at: app.appendingPathComponent("Contents/Resources-link"), withDestinationURL: URL(fileURLWithPath: "/etc"))
            let linkedZip = root.appendingPathComponent("linked.zip")
            zip(app, to: linkedZip)
            assert(staged(linkedZip, release("1.1"), current: adhoc, "1.0", "linked") == "릴리스에 심볼릭 링크가 들어 있습니다")
        }

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
        let status = run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", extraDir.path, extraZip.path]); assert(status == 0)    // the app plus a stray file at the top level
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
