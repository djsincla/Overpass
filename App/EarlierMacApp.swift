#if os(macOS)
import Foundation

/// Up to 0.5.1 the Mac app was com.djsincla.overpass, and from 0.4.5 it ran without the sandbox.
/// It now shares the iPhone and iPad's identifier and runs sandboxed, for the Mac App Store.
/// On the first launch macOS moves the old settings and folder into the new container
/// (container-migration.plist), and this takes them in under the new names.
@MainActor
enum EarlierMacApp {
    static let identifier = "com.djsincla.overpass"
    private static let doneKey = "movedFromEarlierMacApp"

    static func moveIn() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != identifier, !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        // Settings, alignment, cable wind and everything else kept in defaults.
        let preferences = URL.libraryDirectory.appending(path: "Preferences/\(identifier).plist")
        if let old = NSDictionary(contentsOf: preferences) as? [String: Any] {
            for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }

        // TLEs, the mount log and the rest of the app's folder.
        let files = FileManager.default
        let folder = URL.applicationSupportDirectory.appending(path: identifier)
        let storage = AppModel.storage
        guard files.fileExists(atPath: folder.path), !files.fileExists(atPath: storage.path) else { return }
        try? files.moveItem(at: folder, to: storage)

        // Imported TLE files are listed by their full path in the old folder.
        let sources = storage.appending(path: "TLE/sources.json")
        guard var text = try? String(contentsOf: sources, encoding: .utf8) else { return }
        let home = URL(filePath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory())
        let before = home.appending(path: "Library/Application Support/\(identifier)").absoluteString
        let after = storage.absoluteString
        for (a, b) in [(before, after), (before.replacingOccurrences(of: "/", with: "\\/"), after.replacingOccurrences(of: "/", with: "\\/"))] {
            text = text.replacingOccurrences(of: a.hasSuffix("/") ? a : a + "/", with: b.hasSuffix("/") ? b : b + "/")
        }
        try? text.write(to: sources, atomically: true, encoding: .utf8)
    }
}
#endif
