import Foundation

/// Watching builds through Beta App Review without anyone asking: the external state of each
/// build is saved between runs, and a run reports only the builds whose state changed.
public enum Watch {
    /// One line per build whose state differs from last time, oldest build first. A build seen
    /// for the first time counts as a change only if it is past review, so the first run after
    /// an upload stays quiet while the build is still waiting.
    public static func changes(from old: [String: String], to new: [String: String]) -> [String] {
        let waiting: Set = ["READY_FOR_BETA_SUBMISSION", "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "PROCESSING_EXCEPTION"]
        return new.keys.sorted { (Int($0) ?? 0, $0) < (Int($1) ?? 0, $1) }.compactMap { build in
            let state = new[build]!
            if let before = old[build] {
                guard before != state else { return nil }
                return "build \(build): \(describe(before)) → \(describe(state))"
            }
            return waiting.contains(state) ? nil : "build \(build): \(describe(state))"
        }
    }

    /// WAITING_FOR_BETA_REVIEW → "waiting for beta review".
    public static func describe(_ state: String) -> String { state.lowercased().replacingOccurrences(of: "_", with: " ") }

    // MARK: The launchd agent

    public static let label = "com.dwaynesinclair.testflight-watch"

    public static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/testflight-watch.log")
    }

    /// A launch agent that runs `executable watch` every `interval` seconds, and once when loaded.
    public static func agent(executable: String, arguments: [String], interval: Int) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable, "watch"] + arguments,
            "StartInterval": interval,
            "RunAtLoad": true,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
    }
}
