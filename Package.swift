// swift-tools-version:5.9
import PackageDescription
import Foundation

// Get the package directory to use for absolute path
let packageDir = URL(fileURLWithPath: #file).deletingLastPathComponent().path

let package = Package(
    name: "typester",
    platforms: [.macOS(.v13)],
    targets: [
        // Non-UI logic (builds with Command Line Tools; used by tests)
        .target(
            name: "TypesterCore",
            path: "Sources/TypesterLogic"
        ),
        // SwiftUI / AppKit UI (requires SwiftUI macro plugins; CI / full Xcode)
        .target(
            name: "TypesterUI",
            dependencies: ["TypesterCore"],
            path: "Sources/TypesterCore"
        ),
        // Executable that imports the UI library
        .executableTarget(
            name: "typester",
            dependencies: ["TypesterUI"],
            path: "Sources",
            exclude: ["TypesterCore", "TypesterLogic", "DictionarySmoke", "Info.plist", "typester.entitlements"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "\(packageDir)/Sources/Info.plist"])
            ]
        ),
        .testTarget(
            name: "TypesterTests",
            dependencies: ["TypesterCore"],
            path: "Tests"
        ),
        // CLI smoke checks for environments without XCTest (Command Line Tools only)
        .executableTarget(
            name: "dictionary-smoke",
            dependencies: ["TypesterCore"],
            path: "Sources/DictionarySmoke"
        )
    ]
)
