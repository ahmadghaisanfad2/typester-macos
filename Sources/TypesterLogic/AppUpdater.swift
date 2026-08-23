import Foundation
import AppKit

public extension Notification.Name {
    /// Sent when an update was discovered in the background (userInfo: none —
    /// read `AppUpdater.shared.pending`).
    static let updateDiscovered = Notification.Name("updateDiscovered")
    /// Sent by the status menu to make the open Settings window run a check.
    static let updateCheckRequested = Notification.Name("updateCheckRequested")
    /// Sent by the status menu's "Update to…" item to start installing
    /// `AppUpdater.shared.pending` in the Settings window.
    static let updateInstallRequested = Notification.Name("updateInstallRequested")
}

/// An update found on GitHub, held until the user installs or skips it.
public final class PendingUpdate {
    public let latest: String
    public let dmgURL: URL

    public init(latest: String, dmgURL: URL) {
        self.latest = latest
        self.dmgURL = dmgURL
    }
}

public enum AppUpdaterError: LocalizedError, Equatable {
    case alreadyInstalling
    case downloadFailed(String)
    case mountFailed
    case appNotFoundInImage
    case payloadNotValid(String)
    case locationNotReplaceable
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyInstalling:
            return "An update is already being installed."
        case .downloadFailed(let message):
            return "Could not download the update: \(message)"
        case .mountFailed:
            return "Could not open the downloaded update disk image."
        case .appNotFoundInImage:
            return "The update disk image does not contain a Typester app."
        case .payloadNotValid(let message):
            return "The update failed validation: \(message)"
        case .locationNotReplaceable:
            return "Typester is running from a location it cannot update in place (a disk image, or a folder without write access). Move it to /Applications and try again."
        case .installFailed(let message):
            return "Could not install the update: \(message)"
        }
    }
}

/// Throttling for the silent launch-time update check.
public enum UpdateCheckSchedule {
    static let lastCheckKey = "lastAutoUpdateCheck"

    public static func shouldAutoCheck(lastCheck: Date?, now: Date = Date(), interval: TimeInterval = 8 * 3600) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    public static func recordCheck(date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: lastCheckKey)
    }

    public static func lastCheck() -> Date? {
        UserDefaults.standard.object(forKey: lastCheckKey) as? Date
    }
}

/// Installs GitHub-release DMG updates over the running app:
/// download → mount → validate → atomic replace → strip quarantine → relaunch.
///
/// Because every release is signed with the same stable identity
/// (scripts/setup-signing.sh), the replaced app keeps its TCC grants
/// (Accessibility, microphone) and the Keychain API keys — no permission
/// re-grants after updates.
public final class AppUpdater: NSObject {
    public static let shared = AppUpdater()

    /// Latest discovered update, if any. Shown by the menu item and installed
    /// from the Settings window.
    public var pending: PendingUpdate?

    private let workQueue = DispatchQueue(label: "com.typester.appupdate", qos: .userInitiated)
    private let fm = FileManager.default
    private var installing = false

    // MARK: - Public API

    /// True when the running app lives somewhere it can replace itself
    /// (e.g. /Applications for an admin user, ~/Applications, …).
    public static func isReplaceableInstall(_ bundleURL: URL) -> Bool {
        let path = bundleURL.path
        // Running straight from a mounted disk image.
        if path.hasPrefix("/Volumes/") { return false }
        // Gatekeeper app translocation (quarantined app launched in place).
        if path.contains("/AppTranslocation/") || path.hasPrefix("/private/var/folders/") { return false }
        let parent = bundleURL.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parent)
    }

    public func isUpdateSupportedForCurrentInstall() -> Bool {
        Self.isReplaceableInstall(Bundle.main.bundleURL)
    }

    /// Installs the update distributed at `dmgURL` (an https:// GitHub asset,
    /// or a local file:// path for testing). `status` gets short progress text
    /// on the main thread; `completion` runs on the main thread. On success the
    /// app relaunches into the new version shortly after completion.
    public func install(
        from dmgURL: URL,
        currentBundle: Bundle = .main,
        status: @escaping (String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            guard !self.installing else {
                completion(.failure(AppUpdaterError.alreadyInstalling))
                return
            }
            guard Self.isReplaceableInstall(currentBundle.bundleURL) else {
                completion(.failure(AppUpdaterError.locationNotReplaceable))
                return
            }
            self.installing = true
        }
        workQueue.async { [self] in
            let result = performInstall(from: dmgURL, currentBundle: currentBundle) { text in
                DispatchQueue.main.async { status(text) }
            }
            DispatchQueue.main.async {
                self.installing = false
                completion(result)
            }
        }
    }

    // MARK: - Install pipeline

    private func performInstall(
        from dmgURL: URL,
        currentBundle: Bundle,
        report: @escaping (String) -> Void
    ) -> Result<Void, Error> {
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("TypesterUpdate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: workDir) }

        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            return .failure(AppUpdaterError.installFailed(error.localizedDescription))
        }

        // 1) Obtain the DMG (copy for file://, download otherwise)
        let dmgLocal = workDir.appendingPathComponent("update.dmg")
        if dmgURL.isFileURL {
            report("Preparing update…")
            do { try fm.copyItem(at: dmgURL, to: dmgLocal) }
            catch { return .failure(AppUpdaterError.downloadFailed(error.localizedDescription)) }
        } else {
            let download = downloadSync(url: dmgURL, to: dmgLocal) { fraction in
                let percent = Int((fraction * 100).rounded())
                report("Downloading update… \(percent)%")
            }
            switch download {
            case .failure(let error): return .failure(AppUpdaterError.downloadFailed(error.localizedDescription))
            case .success: break
            }
        }

        // 2) Mount and locate the app bundle inside
        report("Opening update image…")
        guard let mount = mount(dmg: dmgLocal) else {
            return .failure(AppUpdaterError.mountFailed)
        }
        defer { detach(mount: mount) }

        guard let payload = firstAppBundle(in: mount) else {
            return .failure(AppUpdaterError.appNotFoundInImage)
        }

        // 3) Validate before touching the current install
        switch Self.validatePayload(
            payload,
            currentVersion: currentBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? appVersion,
            bundleIdentifier: currentBundle.bundleIdentifier ?? "com.typester.app"
        ) {
        case .failure(let error): return .failure(error)
        case .success: break
        }

        // 4) Copy beside the current bundle (same volume → atomic replace),
        //    strip quarantine so the relaunch is Gatekeeper-clean.
        report("Installing update…")
        let currentURL = currentBundle.bundleURL
        let parent = currentURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent("Typester-Incoming-\(UUID().uuidString).app")

        do {
            try fm.copyItem(at: payload, to: staging)
        } catch {
            return .failure(AppUpdaterError.installFailed(error.localizedDescription))
        }
        Self.stripQuarantine(at: staging)

        // Detach before replacing so the image never lingers past relaunch.
        detach(mount: mount)

        do {
            // Explicit rename dance with rollback. The running process keeps
            // working while its bundle is moved aside (open files survive the
            // rename), and the fresh copy slides into the same path atomically.
            let aside = parent.appendingPathComponent("Typester-Old-\(UUID().uuidString).app")
            try fm.moveItem(at: currentURL, to: aside)
            do {
                try fm.moveItem(at: staging, to: currentURL)
                try? fm.removeItem(at: aside)
            } catch {
                try? fm.moveItem(at: aside, to: currentURL)
                throw error
            }
        } catch {
            return .failure(AppUpdaterError.installFailed(error.localizedDescription))
        }

        // 5) Relaunch into the new version
        report("Update installed — relaunching…")
        Self.scheduleRelaunch(of: currentURL)
        pending = nil
        return .success(())
    }

    /// Checks the payload's bundle identifier and that its version is newer.
    public static func validatePayload(
        _ appURL: URL,
        currentVersion: String,
        bundleIdentifier: String
    ) -> Result<String, AppUpdaterError> {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) else {
            return .failure(.payloadNotValid("no Info.plist in the downloaded app"))
        }
        let payloadID = plist["CFBundleIdentifier"] as? String
        guard payloadID == bundleIdentifier else {
            return .failure(.payloadNotValid("bundle identifier \(payloadID ?? "nil") does not match \(bundleIdentifier)"))
        }
        let payloadVersion = (plist["CFBundleShortVersionString"] as? String) ?? ""
        guard UpdateVersioning.isNewer(latest: payloadVersion, than: currentVersion) else {
            return .failure(.payloadNotValid("downloaded version \(payloadVersion) is not newer than \(currentVersion)"))
        }
        return .success(payloadVersion)
    }

    // MARK: - Download

    private func downloadSync(
        url: URL,
        to destination: URL,
        progress: @escaping (Double) -> Void
    ) -> Result<Void, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var output: Result<Void, Error> = .failure(AppUpdaterError.downloadFailed("download did not start"))

        let delegate = ProgressDelegate(progress: progress)
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url) { tempURL, response, error in
            defer { semaphore.signal() }
            if let error {
                output = .failure(error)
                return
            }
            guard let tempURL else {
                output = .failure(AppUpdaterError.downloadFailed("no file produced"))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                output = .failure(AppUpdaterError.downloadFailed("HTTP \(http.statusCode)"))
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tempURL, to: destination)
                progress(1.0)
                output = .success(())
            } catch {
                output = .failure(error)
            }
        }
        task.resume()
        semaphore.wait()
        session.finishTasksAndInvalidate()
        return output
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
        let progress: (Double) -> Void
        init(progress: @escaping (Double) -> Void) { self.progress = progress }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    // MARK: - Disk image

    /// Mounts a DMG read-only and returns the first mount point.
    private func mount(dmg: URL) -> URL? {
        let output = Self.runProcess(
            "/usr/bin/hdiutil",
            ["attach", "-plist", "-nobrowse", "-readonly", dmg.path]
        )
        guard output.status == 0 else { return nil }
        return Self.mountPoints(fromPlistOutput: output.stdout).first
    }

    private func detach(mount: URL) {
        _ = Self.runProcess("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
    }

    /// Parses `hdiutil attach -plist` stdout into mounted volume URLs.
    /// Older macOS prints a bare array of entities; newer versions wrap it in
    /// a dict under `system-entities`. Both are accepted.
    public static func mountPoints(fromPlistOutput data: Data) -> [URL] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return []
        }
        let entities: [[String: Any]]
        if let array = plist as? [[String: Any]] {
            entities = array
        } else if let dict = plist as? [String: Any],
                  let array = dict["system-entities"] as? [[String: Any]] {
            entities = array
        } else {
            return []
        }
        return entities.compactMap { entity in
            guard let path = entity["mount-point"] as? String else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private func firstAppBundle(in mount: URL) -> URL? {
        let entries = (try? fm.contentsOfDirectory(atPath: mount.path)) ?? []
        for entry in entries where entry.hasSuffix(".app") {
            let candidate = mount.appendingPathComponent(entry)
            if fm.fileExists(atPath: candidate.appendingPathComponent("Contents/Info.plist").path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Replace helpers

    /// Removes the Gatekeeper quarantine flag so the relaunched copy opens
    /// without any prompt. In-app-installed updates are not browser downloads,
    /// so stripping quarantine is expected and safe here.
    public static func stripQuarantine(at url: URL) {
        _ = runProcess("/usr/bin/xattr", ["-rd", "com.apple.quarantine", url.path])
    }

    @discardableResult
    private static func runProcess(_ path: String, _ arguments: [String]) -> (status: Int32, stdout: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (-1, Data())
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    /// Spawns a small shell that waits for this process to exit, then opens the
    /// updated bundle, and terminates the current instance.
    static func scheduleRelaunch(of bundleURL: URL) {
        let escaped = bundleURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.8; open -n '\(escaped)'"]
        try? process.run()

        DispatchQueue.main.async {
            NSApp.terminate(nil)
            // Backstop in case something vetoes termination.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
        }
    }
}
