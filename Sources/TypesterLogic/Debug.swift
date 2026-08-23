import Foundation

public enum Debug {
    // Set to true to enable debug logging, or use TYPESTER_DEBUG=1 env var
    public static var enabled: Bool = {
        ProcessInfo.processInfo.environment["TYPESTER_DEBUG"] == "1"
    }()

    // Optional TYPESTER_LOGFILE=/path appends log lines to a file — useful for
    // GUI launches where stdout goes nowhere.
    private static let logfilePath: String? = ProcessInfo.processInfo.environment["TYPESTER_LOGFILE"]

    public static func log(_ message: String, file: String = #file, function: String = #function) {
        guard enabled else { return }
        let filename = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] [\(filename)] \(message)"
        print(line)
        if let path = logfilePath {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            let handle = FileHandle(forWritingAtPath: path)
            handle?.seekToEndOfFile()
            handle?.write(Data((line + "\n").utf8))
            handle?.closeFile()
        }
    }
}
