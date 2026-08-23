import XCTest
@testable import TypesterCore
import Foundation

final class AppUpdaterTests: XCTestCase {
    // MARK: - hdiutil plist parsing

    private func hdiutilPlist(mountPoints: [String]) -> Data {
        let entities: [[String: Any]] = mountPoints.map {
            ["system-entities": true, "mount-point": $0]
        }
        return try! PropertyListSerialization.data(
            fromPropertyList: entities,
            format: .xml,
            options: 0
        )
    }

    func testMountPointsParsesAllMountPoints() {
        let data = hdiutilPlist(mountPoints: ["/Volumes/Typester", "/Volumes/Typester 2"])
        let mounts = AppUpdater.mountPoints(fromPlistOutput: data)
        XCTAssertEqual(mounts.map(\.path), ["/Volumes/Typester", "/Volumes/Typester 2"])
    }

    /// Modern macOS wraps the entity array in a dict under `system-entities`.
    func testMountPointsParsesSystemEntitiesDictFormat() {
        let entities: [[String: Any]] = [
            ["dev-entry": "/dev/disk13s1"],
            ["mount-point": "/Volumes/Typester 1"],
        ]
        let data = try! PropertyListSerialization.data(
            fromPropertyList: ["system-entities": entities],
            format: .xml,
            options: 0
        )
        let mounts = AppUpdater.mountPoints(fromPlistOutput: data)
        XCTAssertEqual(mounts.map(\.path), ["/Volumes/Typester 1"])
    }

    func testMountPointsSkipsEntitiesWithoutMountPoint() {
        let entities: [[String: Any]] = [
            ["system-entities": ["dev-entry": "/dev/disk2s1"]],
            ["mount-point": "/Volumes/Typester"],
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: entities, format: .xml, options: 0)
        let mounts = AppUpdater.mountPoints(fromPlistOutput: data)
        XCTAssertEqual(mounts.map(\.path), ["/Volumes/Typester"])
    }

    func testMountPointsToleratesGarbage() {
        XCTAssertTrue(AppUpdater.mountPoints(fromPlistOutput: Data("not a plist".utf8)).isEmpty)
        XCTAssertTrue(AppUpdater.mountPoints(fromPlistOutput: Data()).isEmpty)
    }

    // MARK: - install-location checks

    func testReplaceableInstallRejectsVolumesAndTranslocation() {
        XCTAssertFalse(AppUpdater.isReplaceableInstall(URL(fileURLWithPath: "/Volumes/Typester/Typester.app")))
        XCTAssertFalse(AppUpdater.isReplaceableInstall(URL(fileURLWithPath: "/private/var/folders/ab/AppTranslocation/123/d/Typester.app")))
        XCTAssertFalse(AppUpdater.isReplaceableInstall(URL(fileURLWithPath: "/private/var/folders/zz/Typester.app")))
    }

    func testReplaceableInstallAcceptsWritableHome() {
        // The test runner's temp directory is user-writable.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("replaceable-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(AppUpdater.isReplaceableInstall(dir.appendingPathComponent("Typester.app")))
    }

    // MARK: - payload validation

    private func makeAppFixture(version: String, identifier: String = "com.typester.app") -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString).app", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: String] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
        ]
        (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        return root
    }

    func testValidatePayloadAcceptsNewerMatchingBundle() {
        let app = makeAppFixture(version: "1.15.0")
        defer { try? FileManager.default.removeItem(at: app) }

        let result = AppUpdater.validatePayload(app, currentVersion: "1.14.0", bundleIdentifier: "com.typester.app")
        guard case .success(let version) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(version, "1.15.0")
    }

    func testValidatePayloadRejectsSameOrOlderVersion() {
        let same = makeAppFixture(version: "1.14.0")
        defer { try? FileManager.default.removeItem(at: same) }
        XCTAssertEqual(
            AppUpdater.validatePayload(same, currentVersion: "1.14.0", bundleIdentifier: "com.typester.app"),
            .failure(.payloadNotValid("downloaded version 1.14.0 is not newer than 1.14.0"))
        )
    }

    func testValidatePayloadRejectsBundleIdentifierMismatch() {
        let other = makeAppFixture(version: "2.0.0", identifier: "com.evil.app")
        defer { try? FileManager.default.removeItem(at: other) }
        guard case .failure(.payloadNotValid) = AppUpdater.validatePayload(
            other, currentVersion: "1.14.0", bundleIdentifier: "com.typester.app"
        ) else {
            return XCTFail("expected payloadNotValid failure")
        }
    }

    func testValidatePayloadRejectsMissingPlist() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).app", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .failure(.payloadNotValid) = AppUpdater.validatePayload(
            dir, currentVersion: "1.14.0", bundleIdentifier: "com.typester.app"
        ) else {
            return XCTFail("expected payloadNotValid failure")
        }
    }

    // MARK: - auto-check throttle

    func testShouldAutoCheckWithoutPreviousCheck() {
        XCTAssertTrue(UpdateCheckSchedule.shouldAutoCheck(lastCheck: nil, now: Date(), interval: 3600))
    }

    func testShouldAutoCheckRespectsInterval() {
        let now = Date()
        XCTAssertFalse(UpdateCheckSchedule.shouldAutoCheck(lastCheck: now.addingTimeInterval(-60), now: now, interval: 3600))
        XCTAssertTrue(UpdateCheckSchedule.shouldAutoCheck(lastCheck: now.addingTimeInterval(-7200), now: now, interval: 3600))
    }
}
