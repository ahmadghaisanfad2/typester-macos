import Foundation

public enum Debug {
    // Set to true to enable debug logging, or use TYPESTER_DEBUG=1 env var
    public static var enabled: Bool = {
        ProcessInfo.processInfo.environment["TYPESTER_DEBUG"] == "1"
    }()

    public static func log(_ message: String, file: String = #file, function: String = #function) {
        guard enabled else { return }
        let filename = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[\(timestamp)] [\(filename)] \(message)")
    }
}
