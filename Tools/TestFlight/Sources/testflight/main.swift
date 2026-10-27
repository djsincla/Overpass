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

The key comes from ~/.appstoreconnect/testflight.json ({"keyID": "...", "issuerID": "..."}),
or ASC_KEY_ID and ASC_ISSUER_ID, and its file from ~/.appstoreconnect/private_keys/AuthKey_<keyID>.p8.
--bundle-id picks another app (com.dwaynesinclair.overpass by default).
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
let args = Arguments(all.dropFirst(), switches: ["public-link", "no-submit"])

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
