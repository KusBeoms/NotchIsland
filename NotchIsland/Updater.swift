import Foundation
import Security
import CryptoKit

// MARK: - Auto update from GitHub Releases
//
// Flow: ask the GitHub API for the latest release -> newer than this app? -> download the zip asset ->
// check it (size, GitHub's SHA-256, bundle id, version, and above all its code signature against THIS app's
// designated requirement) -> keep it staged next to the app -> swap the bundle and relaunch when the app is idle.
//
// Trust model: the release is signed with the same identity as the installed app (make-signing-cert.sh), so a new
// build is accepted only when it satisfies the running app's designated requirement. An ad-hoc signed app has no
// stable identity to compare against, so it never installs anything by itself: it only points at the release page.

struct UpdateRelease: Equatable {
    let version: String         // "2.1": the tag without its "v"
    let url: URL                // the zip asset
    let sha256: String?         // GitHub's digest of the asset, when it publishes one (lowercase hex)
}

struct UpdateError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Pure rules (no I/O)

enum UpdateRules {
    static let repo = "KusBeoms/NotchIsland"
    static let assetName = "NotchIsland-arm64.zip"
    static let appName = "NotchIsland.app"
    static let launchdLabel = "com.kusbeoms.notchisland"            // install.sh's login item
    static let checkInterval: TimeInterval = 6 * 3600
    static let maxDownloadBytes: Int64 = 200_000_000

    static var latestReleaseURL: URL { URL(string: "https://api.github.com/repos/\(repo)/releases/latest")! }
    static var releasesPageURL: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    /// "v2.0" / "2.0.1" -> [2, 0, 1]. nil for anything that is not a plain dotted number, so a tag such as
    /// "2.0-beta" or "nightly" never counts as an update.
    static func components(_ version: String) -> [Int]? {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return numbers
    }

    /// True only when both versions are plain dotted numbers and `candidate` is strictly greater ("2.0" == "2.0.0").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var a = components(candidate), var b = components(current) else { return false }
        while a.count < b.count { a.append(0) }
        while b.count < a.count { b.append(0) }
        return b.lexicographicallyPrecedes(a)
    }

    /// Only the project's own release downloads over HTTPS (GitHub then redirects to its CDN).
    static func isTrustedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/\(repo)/releases/download/")
    }

    /// The release the GitHub API describes, or nil when it is a draft / pre-release, has no plain version tag, or has no usable asset.
    static func parseRelease(_ data: Data) -> UpdateRelease? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
              let tag = object["tag_name"] as? String, let numbers = components(tag),
              let assets = object["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == assetName }),
              let link = asset["browser_download_url"] as? String, let url = URL(string: link), isTrustedDownload(url)
        else { return nil }
        var sha: String?
        if let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") {
            let hex = String(digest.dropFirst("sha256:".count)).lowercased()
            if hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) { sha = hex }
        }
        return UpdateRelease(version: numbers.map(String.init).joined(separator: "."), url: url, sha256: sha)
    }
}

// MARK: - Files, signatures and relaunch

enum UpdateInstaller {
    static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        return SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess ? code : nil
    }

    /// Unsigned code counts as ad-hoc: it has no identity to compare either.
    static func isAdHoc(_ code: SecStaticCode) -> Bool {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let flags = dict[kSecCodeInfoFlags as String] as? UInt32 else { return true }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    /// Why this app cannot replace itself (shown as "install it yourself"); nil when it can.
    static func installBlocker(app: URL) -> String? {
        guard app.pathExtension == "app" else { return "앱 번들로 실행 중이 아닙니다" }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else { return "앱이 있는 폴더에 쓸 수 없습니다" }
        guard let code = staticCode(app) else { return "앱 서명을 읽을 수 없습니다" }
        if isAdHoc(code) { return "임시 서명 앱은 새 버전의 서명을 확인할 수 없습니다" }
        return nil
    }

    static func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Read from disk each time: `Bundle(url:)` caches the Info.plist per path, and the staging folder reuses its path.
    static func info(of app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    /// Throws unless `newApp` is the same app (bundle id + the signing identity of `currentApp`) at exactly `expectedVersion`,
    /// and that version is newer than `currentVersion`.
    static func verify(newApp: URL, currentApp: URL, expectedVersion: String, currentVersion: String) throws {
        guard let new = info(of: newApp), let current = info(of: currentApp) else { throw UpdateError("앱 정보를 읽을 수 없습니다") }
        guard let id = new["CFBundleIdentifier"] as? String, id == current["CFBundleIdentifier"] as? String else { throw UpdateError("다른 앱입니다") }
        guard let version = new["CFBundleShortVersionString"] as? String,
              let a = UpdateRules.components(version), a == UpdateRules.components(expectedVersion) else {
            throw UpdateError("릴리스와 앱의 버전이 다릅니다")
        }
        guard UpdateRules.isNewer(version, than: currentVersion) else { throw UpdateError("새 버전이 아닙니다") }

        guard let currentCode = staticCode(currentApp), !isAdHoc(currentCode), let newCode = staticCode(newApp) else {
            throw UpdateError("서명을 확인할 수 없습니다")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(currentCode, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("현재 앱의 서명 조건을 읽을 수 없습니다")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidityWithErrors(newCode, flags, requirement, nil) == errSecSuccess else {
            throw UpdateError("서명이 현재 앱과 다릅니다")
        }
    }

    /// Moves the downloaded zip into a fresh `root`, checks and unpacks it, and returns the verified new bundle.
    /// `root` is wiped first and again on failure; nothing in it is ever executed.
    static func stage(downloaded: URL, release: UpdateRelease, currentApp: URL, currentVersion: String, root: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let zip = root.appendingPathComponent("update.zip")
            try fm.moveItem(at: downloaded, to: zip)
            let size = (try fm.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= UpdateRules.maxDownloadBytes else { throw UpdateError("내려받은 파일 크기가 올바르지 않습니다") }
            if let expected = release.sha256, try sha256Hex(of: zip) != expected { throw UpdateError("내려받은 파일이 손상되었습니다") }

            let extracted = root.appendingPathComponent("extracted")
            try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, extracted.path]
            ditto.standardOutput = FileHandle.nullDevice; ditto.standardError = FileHandle.nullDevice
            try ditto.run(); ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw UpdateError("압축을 풀 수 없습니다") }
            guard try fm.contentsOfDirectory(atPath: extracted.path) == [UpdateRules.appName] else { throw UpdateError("릴리스 구성이 올바르지 않습니다") }

            let app = extracted.appendingPathComponent(UpdateRules.appName)
            try verify(newApp: app, currentApp: currentApp, expectedVersion: release.version, currentVersion: currentVersion)
            return app
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    /// Atomically exchanges the installed bundle for the staged one (same volume: the staging folder sits next to the app).
    static func swap(staged: URL, over current: URL) throws {
        _ = try FileManager.default.replaceItemAt(current, withItemAt: staged, backupItemName: nil, options: [])
    }

    /// Starts the new copy. The login item (install.sh) is restarted by launchd itself, because a helper started by this
    /// process would be cleaned up with it; any other launch waits for this process to exit (the instance lock) and opens the app.
    static func relaunch(app: URL) {
        let process = Process()
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == UpdateRules.launchdLabel {
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(UpdateRules.launchdLabel)"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.2; i=$((i+1)); done; exec /usr/bin/open \"$2\"",
                                 "sh", String(getpid()), app.path]
        }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

// MARK: - The updater (state, network, timers)

final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(String)        // version
        case ready(String)              // downloaded, verified and staged: applying only needs a restart
        case available(String)          // newer, but this copy cannot replace itself: install it by hand
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            if case .ready = state { startApplyTimer() } else { applyTimer?.invalidate(); applyTimer = nil }
            onChange?()
        }
    }
    private(set) var manualReason: String?          // why `.available` has to be installed by hand

    var onChange: (() -> Void)?
    /// Fired once when a check the user asked for ends (up to date, ready, available or failed).
    var onManualResult: ((State) -> Void)?
    var onWillRelaunch: (() -> Void)?               // last chance to tidy up before the bundle is replaced
    var onRelaunch: (() -> Void)?                   // the app should quit now
    var isIdle: () -> Bool = { true }               // restarting would not interrupt anything
    var autoApply = false                           // restart by itself, when idle, once an update is ready

    let appURL: URL
    let currentVersion: String
    private let session: URLSession
    private var stagedApp: URL?
    private var checkTimer: Timer?, applyTimer: Timer?
    private var manualPending = false
    private var stagingRoot: URL { appURL.deletingLastPathComponent().appendingPathComponent(".NotchIsland-update") }

    init(appURL: URL = Bundle.main.bundleURL,
         currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
         session: URLSession = .shared) {
        self.appURL = appURL
        self.currentVersion = currentVersion
        self.session = session
    }

    var statusText: String {
        switch state {
        case .idle: return "현재 버전 \(currentVersion)"
        case .checking: return "업데이트 확인 중…"
        case .upToDate: return "현재 버전 \(currentVersion) · 최신 버전입니다"
        case .downloading(let v): return "버전 \(v) 내려받는 중…"
        case .ready(let v): return "버전 \(v) 준비됨 · 다시 시작하면 적용됩니다"
        case .available(let v): return "새 버전 \(v) · \(manualReason ?? "직접 설치해야 합니다")"
        case .failed(let message): return "업데이트 확인 실패 · \(message)"
        }
    }

    // MARK: scheduling

    /// First check shortly after launch, then every few hours.
    func startAutomaticChecks() {
        guard checkTimer == nil else { return }
        scheduleCheck(after: 30)
    }
    func stopAutomaticChecks() { checkTimer?.invalidate(); checkTimer = nil }

    private func scheduleCheck(after delay: TimeInterval) {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.check()
            self.scheduleCheck(after: UpdateRules.checkInterval)
        }
    }

    private func startApplyTimer() {
        applyTimer?.invalidate()
        applyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.considerApplying() }
        DispatchQueue.main.async { [weak self] in self?.considerApplying() }
    }

    /// Restarts into a ready update when auto-update is on and nothing would be interrupted.
    func considerApplying() {
        guard case .ready = state, autoApply, isIdle() else { return }
        applyAndRelaunch()
    }

    /// Removes a leftover staging folder (a previous run was interrupted, or the update was applied).
    func cleanupStaging() {
        if case .ready = state { return }
        if case .downloading = state { return }
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    // MARK: check -> download -> stage

    private func settle(_ new: State) {
        state = new
        if manualPending { manualPending = false; onManualResult?(new) }
    }

    func check(manual: Bool = false) {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.check(manual: manual) }; return }
        if manual { manualPending = true }
        switch state {
        case .checking, .downloading: return                       // the running check reports to a pending manual request too
        case .ready: settle(state); return
        default: break
        }
        state = .checking
        var request = URLRequest(url: UpdateRules.latestReleaseURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NotchIsland-Updater/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { self?.received(data: data, response: response, error: error) }
        }.resume()
    }

    private func received(data: Data?, response: URLResponse?, error: Error?) {
        let status = (response as? HTTPURLResponse)?.statusCode
        guard error == nil, status == 200, let data else {
            settle(.failed(status == 403 || status == 429 ? "GitHub 요청 한도에 걸렸습니다" : "네트워크에 연결할 수 없습니다"))
            return
        }
        guard let release = UpdateRules.parseRelease(data) else { settle(.failed("릴리스에서 \(UpdateRules.assetName)를 찾을 수 없습니다")); return }
        guard UpdateRules.isNewer(release.version, than: currentVersion) else { settle(.upToDate); return }
        if let reason = UpdateInstaller.installBlocker(app: appURL) {
            manualReason = reason
            settle(.available(release.version))
            return
        }
        state = .downloading(release.version)
        let root = stagingRoot, app = appURL, version = currentVersion
        session.downloadTask(with: URLRequest(url: release.url, timeoutInterval: 60)) { [weak self] file, response, error in
            // The system deletes `file` when this handler returns, so everything that touches it happens here, off the main thread.
            let result: Result<URL, UpdateError>
            if let file, error == nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                do { result = .success(try UpdateInstaller.stage(downloaded: file, release: release, currentApp: app, currentVersion: version, root: root)) }
                catch { result = .failure((error as? UpdateError) ?? UpdateError("파일을 처리할 수 없습니다")) }
            } else {
                result = .failure(UpdateError("내려받지 못했습니다"))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let staged): self.stagedApp = staged; self.settle(.ready(release.version))
                case .failure(let e): self.stagedApp = nil; self.settle(.failed(e.description))
                }
            }
        }.resume()
    }

    // MARK: apply

    /// Swaps in the staged bundle and restarts. The staged copy is verified once more right before the swap
    /// (it may have been sitting on disk for hours).
    func applyAndRelaunch() {
        guard case .ready(let version) = state, let staged = stagedApp else { return }
        do {
            try UpdateInstaller.verify(newApp: staged, currentApp: appURL, expectedVersion: version, currentVersion: currentVersion)
            try UpdateInstaller.swap(staged: staged, over: appURL)
        } catch {
            stagedApp = nil
            try? FileManager.default.removeItem(at: stagingRoot)
            settle(.failed((error as? UpdateError)?.description ?? "설치하지 못했습니다"))
            return
        }
        try? FileManager.default.removeItem(at: stagingRoot)
        onWillRelaunch?()
        UpdateInstaller.relaunch(app: appURL)
        onRelaunch?()
    }
}
