import Foundation
import TestFlightKit

let usage = """
testflight: TestFlight for Overpass through the App Store Connect API.

  testflight status
  testflight setup [--description TEXT|--description-file PATH] [--feedback-email EMAIL]
                   [--privacy-url URL] [--marketing-url URL]
                   [--contact-first NAME] [--contact-last NAME] [--contact-email EMAIL]
                   [--contact-phone PHONE] [--notes TEXT|--notes-file PATH]
  testflight group NAME [--public-link] [--link-limit N]
  testflight release BUILD --group NAME [--whats-new TEXT|--whats-new-file PATH] [--no-submit]
  testflight invite EMAIL --group NAME [--first NAME] [--last NAME]
  testflight watch [--install [--every HOURS] | --uninstall]

The key comes from ~/.appstoreconnect/testflight.json ({"keyID": "...", "issuerID": "..."}),
or ASC_KEY_ID and ASC_ISSUER_ID, and its file from ~/.appstoreconnect/private_keys/AuthKey_<keyID>.p8.
--bundle-id picks another app (com.dwaynesinclair.overpass by default).

watch reports builds whose review state changed since the last watch, with a notification.
--install runs it from launchd every 2 hours (or --every HOURS) until --uninstall; it logs to
~/Library/Logs/testflight-watch.log.
"""

/// Flags after the command: --name value, or --name alone for a switch.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var switches: Set<String> = []

    init(_ args: some Sequence<String>, switches known: Set<String>) {
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if known.contains(name) { switches.insert(name) } else { options[name] = iterator.next() }
            } else {
                positional.append(arg)
            }
        }
    }

    /// --name TEXT, or the contents of --name-file PATH.
    func text(_ name: String) throws -> String? {
        if let path = options[name + "-file"] { return try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) }
        return options[name]
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func signer() throws -> TokenSigner {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let config = home.appending(path: ".appstoreconnect/testflight.json")
    var keyID = ProcessInfo.processInfo.environment["ASC_KEY_ID"]
    var issuerID = ProcessInfo.processInfo.environment["ASC_ISSUER_ID"]
    if let data = try? Data(contentsOf: config), let json = try JSONSerialization.jsonObject(with: data) as? [String: String] {
        keyID = keyID ?? json["keyID"]
        issuerID = issuerID ?? json["issuerID"]
    }
    guard let keyID, let issuerID else { fail("No key: put {\"keyID\": …, \"issuerID\": …} in \(config.path), or set ASC_KEY_ID and ASC_ISSUER_ID.") }
    let keyFile = home.appending(path: ".appstoreconnect/private_keys/AuthKey_\(keyID).p8")
    guard let pem = try? String(contentsOf: keyFile, encoding: .utf8) else { fail("No key file at \(keyFile.path).") }
    return try TokenSigner(keyID: keyID, issuerID: issuerID, pem: pem)
}

let all = Array(CommandLine.arguments.dropFirst())
guard let command = all.first, command != "help", command != "--help" else {
    print(usage)
    exit(0)
}
let args = Arguments(all.dropFirst(), switches: ["public-link", "no-submit", "install", "uninstall"])

/// Runs a command and waits, returning its exit status.
@discardableResult
func run(_ path: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

/// A notification in the corner of the screen. The text goes in as arguments, so quotes in it are safe.
func notify(_ title: String, _ message: String) {
    run("/usr/bin/osascript", ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                               "-e", "end run", title, message])
}

if command == "watch", args.switches.contains("install") || args.switches.contains("uninstall") {
    let domain = "gui/\(getuid())"
    run("/bin/launchctl", ["bootout", "\(domain)/\(Watch.label)"])
    if args.switches.contains("uninstall") {
        try? FileManager.default.removeItem(at: Watch.agentURL)
        print("watch removed")
        exit(0)
    }
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { fail("Can't tell where this program is.") }
    let hours = args.options["every"].flatMap(Double.init) ?? 2
    guard hours >= 0.25 else { fail("--every is in hours, at least 0.25.") }
    let agent = Watch.agent(executable: executable, arguments: args.options["bundle-id"].map { ["--bundle-id", $0] } ?? [],
                            interval: Int(hours * 3600))
    do {
        try FileManager.default.createDirectory(at: Watch.agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: Watch.agentURL)
    } catch {
        fail("Couldn't write \(Watch.agentURL.path): \(error)")
    }
    guard run("/bin/launchctl", ["bootstrap", domain, Watch.agentURL.path]) == 0 else { fail("launchctl couldn't load \(Watch.agentURL.path).") }
    print("watching every \(hours.formatted()) h from \(executable)")
    print("log: \(Watch.logURL.path)")
    exit(0)
}

do {
    let client = Client(signer: try signer())
    let testFlight = try await TestFlight.open(client: client, bundleID: args.options["bundle-id"] ?? "com.dwaynesinclair.overpass")
    print("\(testFlight.app.string("name") ?? "?") (\(testFlight.app.string("bundleId") ?? "?"))")

    switch command {
    case "status":
        for build in try await testFlight.builds() {
            let state = (try? await testFlight.externalState(of: build)) ?? nil
            print(String(format: "  build %-6@ %-11@ external: %@  uploaded %@%@",
                         build.string("version") ?? "?", (build.string("processingState") ?? "?").lowercased(),
                         (state ?? "?").lowercased(), String((build.string("uploadedDate") ?? "?").prefix(16)),
                         (build["expired"] as? Bool) == true ? "  (expired)" : ""))
        }
        for group in try await testFlight.groups() {
            let kind = (group["isInternalGroup"] as? Bool) == true ? "internal" : "external"
            let link = group.string("publicLink").map { "  public link \($0)" } ?? ""
            print("  group \"\(group.string("name") ?? "?")\" (\(kind))\(link)")
        }

    case "setup":
        try await testFlight.setTestInformation(description: try args.text("description"), feedbackEmail: args.options["feedback-email"],
                                                privacyPolicyURL: args.options["privacy-url"], marketingURL: args.options["marketing-url"])
        let contact = ["contact-first", "contact-last", "contact-email", "contact-phone", "notes", "notes-file"]
        if contact.contains(where: { args.options[$0] != nil }) {
            try await testFlight.setReviewDetails(firstName: args.options["contact-first"], lastName: args.options["contact-last"],
                                                  email: args.options["contact-email"], phone: args.options["contact-phone"],
                                                  notes: try args.text("notes"))
        }
        print("  test information saved")

    case "group":
        guard let name = args.positional.first else { fail(usage) }
        if let existing = try await testFlight.group(named: name) {
            print("  group \"\(name)\" already exists" + (existing.string("publicLink").map { ", public link \($0)" } ?? ""))
        } else {
            let group = try await testFlight.createGroup(name, publicLink: args.switches.contains("public-link"),
                                                         linkLimit: args.options["link-limit"].flatMap(Int.init))
            print("  created group \"\(name)\"" + (group?.string("publicLink").map { ", public link \($0)" } ?? ""))
        }

    case "release":
        guard let number = args.positional.first, let groupName = args.options["group"] else { fail(usage) }
        guard let group = try await testFlight.group(named: groupName) else { fail("No group \"\(groupName)\"; make it with: testflight group \"\(groupName)\"") }
        let build = try await testFlight.waitUntilProcessed(number) { print("  " + $0) }
        print("  build \(number) is processed")
        if let whatsNew = try args.text("whats-new") {
            try await testFlight.setWhatsNew(whatsNew, for: build)
            print("  what to test set")
        }
        try await testFlight.add(build, to: group)
        print("  added to \"\(groupName)\"")
        let state = try await testFlight.externalState(of: build)
        if (group["isInternalGroup"] as? Bool) == true || args.switches.contains("no-submit") {
            print("  not submitted for review")
        } else if state == "READY_FOR_BETA_SUBMISSION" {
            try await testFlight.submitForReview(build)
            print("  submitted for Beta App Review")
        } else {
            print("  external state is \(state?.lowercased() ?? "unknown"), so no submission needed")
        }

    case "watch":
        // Saved per app, so --bundle-id watches don't mix.
        let bundleID = testFlight.app.string("bundleId") ?? "app"
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".appstoreconnect/watch-\(bundleID).json")
        let old = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        var new: [String: String] = [:]
        for build in try await testFlight.builds() {
            guard let number = build.string("version") else { continue }
            // App Store Connect sometimes answers 404 for a build's beta details; keep what we knew.
            if let state = (try? await testFlight.externalState(of: build)) ?? old?[number] { new[number] = state }
        }
        try JSONEncoder().encode(new).write(to: file)
        let stamp = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.space))
        guard let old else {
            // The first watch has nothing to compare with: note where each build stands.
            for build in new.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) { print("  \(stamp) build \(build): \(Watch.describe(new[build]!))") }
            break
        }
        let changes = Watch.changes(from: old, to: new)
        if changes.isEmpty {
            print("  \(stamp) no change")
        } else {
            for change in changes { print("  \(stamp) \(change)") }
            notify("TestFlight: \(testFlight.app.string("name") ?? bundleID)", changes.joined(separator: "\n"))
        }

    case "invite":
        guard let email = args.positional.first, let groupName = args.options["group"] else { fail(usage) }
        guard let group = try await testFlight.group(named: groupName) else { fail("No group \"\(groupName)\".") }
        try await testFlight.invite(email: email, firstName: args.options["first"], lastName: args.options["last"], to: group)
        print("  invited \(email) to \"\(groupName)\"")

    default:
        fail(usage)
    }
} catch {
    fail("\(error)")
}
