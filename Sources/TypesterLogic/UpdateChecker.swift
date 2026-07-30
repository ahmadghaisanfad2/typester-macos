import Foundation
import AppKit

public enum VersionCompareResult: Equatable {
    case ascending   // lhs < rhs
    case same
    case descending  // lhs > rhs
}

public enum UpdateCheckOutcome: Equatable {
    case upToDate(current: String, latest: String)
    case updateAvailable(current: String, latest: String, dmgURL: URL, releaseURL: URL?)
    case noRelease
    case noDMGAsset(latest: String)
    case failure(String)
}

/// Pure helpers for GitHub release version tags and semver comparison.
public enum UpdateVersioning {
    /// Strip a leading `v` / `V` and any surrounding whitespace.
    public static func normalizeTag(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    /// Compare dotted numeric versions (e.g. `1.4.0` vs `1.5.0`). Non-numeric
    /// segments compare as 0. Missing trailing components are treated as 0.
    public static func compare(_ lhs: String, _ rhs: String) -> VersionCompareResult {
        let left = normalizeTag(lhs)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        let right = normalizeTag(rhs)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .ascending }
            if l > r { return .descending }
        }
        return .same
    }

    public static func isNewer(latest: String, than current: String) -> Bool {
        compare(current, latest) == .ascending
    }
}

public struct GitHubReleaseInfo: Equatable {
    public let tagName: String
    public let htmlURL: URL?
    public let dmgDownloadURL: URL?

    public init(tagName: String, htmlURL: URL?, dmgDownloadURL: URL?) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.dmgDownloadURL = dmgDownloadURL
    }

    public static func parse(json: [String: Any]) -> GitHubReleaseInfo? {
        guard let tagName = json["tag_name"] as? String, !tagName.isEmpty else {
            return nil
        }

        let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:))
        var dmgURL: URL?
        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = asset["name"] as? String,
                      name.lowercased().hasSuffix(".dmg"),
                      let urlString = asset["browser_download_url"] as? String,
                      let url = URL(string: urlString) else {
                    continue
                }
                dmgURL = url
                // Prefer Typester-*.dmg when multiple DMGs exist
                if name.lowercased().hasPrefix("typester") {
                    break
                }
            }
        }

        return GitHubReleaseInfo(tagName: tagName, htmlURL: htmlURL, dmgDownloadURL: dmgURL)
    }
}

public final class UpdateChecker {
    public static let shared = UpdateChecker()

    private let session: URLSession
    private let releasesURL: URL
    private let currentVersion: String

    public init(
        session: URLSession = .shared,
        releasesURL: URL = URL(string: githubReleasesAPIURL)!,
        currentVersion: String = appVersion
    ) {
        self.session = session
        self.releasesURL = releasesURL
        self.currentVersion = currentVersion
    }

    public func checkForUpdates(completion: @escaping (UpdateCheckOutcome) -> Void) {
        var request = URLRequest(url: releasesURL)
        request.setValue("Typester/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let task = session.dataTask(with: request) { data, response, error in
            let outcome = Self.outcome(
                data: data,
                response: response,
                error: error,
                currentVersion: self.currentVersion
            )
            DispatchQueue.main.async {
                completion(outcome)
            }
        }
        task.resume()
    }

    public static func outcome(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        currentVersion: String
    ) -> UpdateCheckOutcome {
        if let error {
            return .failure(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                return .noRelease
            }
            if !(200...299).contains(http.statusCode) {
                return .failure("GitHub returned HTTP \(http.statusCode)")
            }
        }

        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let release = GitHubReleaseInfo.parse(json: json) else {
            return .failure("Could not parse GitHub release response")
        }

        let latest = UpdateVersioning.normalizeTag(release.tagName)
        let current = UpdateVersioning.normalizeTag(currentVersion)

        guard UpdateVersioning.isNewer(latest: latest, than: current) else {
            return .upToDate(current: current, latest: latest)
        }

        guard let dmgURL = release.dmgDownloadURL else {
            return .noDMGAsset(latest: latest)
        }

        return .updateAvailable(
            current: current,
            latest: latest,
            dmgURL: dmgURL,
            releaseURL: release.htmlURL
        )
    }

    public func downloadDMG(
        from url: URL,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let task = session.downloadTask(with: url) { tempURL, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            guard let tempURL else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "UpdateChecker",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Download produced no file"]
                    )))
                }
                return
            }

            do {
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                let filename = url.lastPathComponent.isEmpty ? "Typester-update.dmg" : url.lastPathComponent
                var destination = downloads.appendingPathComponent(filename)

                if FileManager.default.fileExists(atPath: destination.path) {
                    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                    destination = downloads.appendingPathComponent("\(destination.deletingPathExtension().lastPathComponent)-\(stamp).dmg")
                }

                try FileManager.default.moveItem(at: tempURL, to: destination)
                DispatchQueue.main.async {
                    progress?(1.0)
                    completion(.success(destination))
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }

        task.resume()
    }

    public func openDownloadedDMG(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        NSWorkspace.shared.open(fileURL)
    }
}
