import Foundation

/// The TestFlight steps for one app: test information, groups, builds, review and testers.
public struct TestFlight: Sendable {
    public let client: Client
    public let app: Resource

    /// The app with this bundle id.
    public static func open(client: Client, bundleID: String) async throws -> TestFlight {
        guard let app = try await client.list("apps?filter[bundleId]=\(Client.query(bundleID))").first else {
            throw APIError(status: 404, message: "no app with bundle id \(bundleID) in App Store Connect")
        }
        return TestFlight(client: client, app: app)
    }

    // MARK: Builds

    /// The newest builds first.
    public func builds(limit: Int = 10) async throws -> [Resource] {
        try await client.list("builds?filter[app]=\(app.id)&sort=-uploadedDate&limit=\(limit)")
    }

    /// The build with this build number (CFBundleVersion), the newest upload if there are several.
    public func build(_ number: String) async throws -> Resource? {
        try await client.list("builds?filter[app]=\(app.id)&filter[version]=\(Client.query(number))&sort=-uploadedDate&limit=1").first
    }

    /// Its external TestFlight state: READY_FOR_BETA_SUBMISSION, WAITING_FOR_BETA_REVIEW,
    /// IN_BETA_REVIEW, BETA_APPROVED, BETA_REJECTED, IN_BETA_TESTING, EXPIRED and so on.
    public func externalState(of build: Resource) async throws -> String? {
        try await client.one("builds/\(build.id)/buildBetaDetail")?.string("externalBuildState")
    }

    /// Waits for Apple to finish processing an upload: VALID, or FAILED / INVALID.
    public func waitUntilProcessed(_ number: String, timeout: TimeInterval = 45 * 60,
                                   progress: (String) -> Void = { _ in }) async throws -> Resource {
        let deadline = Date.now + timeout
        while true {
            if let build = try await build(number) {
                let state = build.string("processingState") ?? "?"
                if state == "VALID" { return build }
                if state == "FAILED" || state == "INVALID" {
                    throw APIError(status: 0, message: "build \(number) is \(state) in App Store Connect")
                }
                progress("build \(number): \(state.lowercased())")
            } else {
                progress("build \(number) hasn't appeared yet")
            }
            guard Date.now < deadline else { throw APIError(status: 0, message: "build \(number) still not processed after \(Int(timeout / 60)) minutes") }
            try await Task.sleep(for: .seconds(30))
        }
    }

    /// The "what to test" text testers see for a build.
    public func setWhatsNew(_ text: String, for build: Resource, locale: String = "en-US") async throws {
        let existing = try await client.list("builds/\(build.id)/betaBuildLocalizations").first { $0.string("locale") == locale }
        if let existing {
            try await client.update("betaBuildLocalizations", id: existing.id, attributes: ["whatsNew": text])
        } else {
            try await client.create("betaBuildLocalizations", attributes: ["locale": locale, "whatsNew": text],
                                    relationships: ["build": Client.link("builds", build.id)])
        }
    }

    public func submitForReview(_ build: Resource) async throws {
        try await client.create("betaAppReviewSubmissions", relationships: ["build": Client.link("builds", build.id)])
    }

    // MARK: Test information

    /// The beta app description, feedback email and the URLs testers see.
    public func setTestInformation(description: String?, feedbackEmail: String?, privacyPolicyURL: String?,
                                   marketingURL: String?, locale: String = "en-US") async throws {
        var attributes: [String: Any] = [:]
        if let description { attributes["description"] = description }
        if let feedbackEmail { attributes["feedbackEmail"] = feedbackEmail }
        if let privacyPolicyURL { attributes["privacyPolicyUrl"] = privacyPolicyURL }
        if let marketingURL { attributes["marketingUrl"] = marketingURL }
        guard !attributes.isEmpty else { return }
        let existing = try await client.list("apps/\(app.id)/betaAppLocalizations").first { $0.string("locale") == locale }
        if let existing {
            try await client.update("betaAppLocalizations", id: existing.id, attributes: attributes)
        } else {
            attributes["locale"] = locale
            try await client.create("betaAppLocalizations", attributes: attributes,
                                    relationships: ["app": Client.link("apps", app.id)])
        }
    }

    /// Who Apple's reviewer contacts, and the notes they read. No demo account: Overpass has no sign-in.
    public func setReviewDetails(firstName: String?, lastName: String?, email: String?, phone: String?, notes: String?) async throws {
        guard let detail = try await client.one("apps/\(app.id)/betaAppReviewDetail") else {
            throw APIError(status: 404, message: "no beta review detail for the app")
        }
        var attributes: [String: Any] = ["demoAccountRequired": false]
        if let firstName { attributes["contactFirstName"] = firstName }
        if let lastName { attributes["contactLastName"] = lastName }
        if let email { attributes["contactEmail"] = email }
        if let phone { attributes["contactPhone"] = phone }
        if let notes { attributes["notes"] = notes }
        try await client.update("betaAppReviewDetails", id: detail.id, attributes: attributes)
    }

    // MARK: Groups and testers

    public func groups() async throws -> [Resource] {
        try await client.list("betaGroups?filter[app]=\(app.id)&limit=50")
    }

    public func group(named name: String) async throws -> Resource? {
        try await groups().first { $0.string("name") == name }
    }

    /// An external group, with a public link if asked (capped at `linkLimit` testers).
    @discardableResult
    public func createGroup(_ name: String, publicLink: Bool, linkLimit: Int?) async throws -> Resource? {
        var attributes: [String: Any] = ["name": name, "publicLinkEnabled": publicLink, "feedbackEnabled": true]
        if let linkLimit {
            attributes["publicLinkLimitEnabled"] = true
            attributes["publicLinkLimit"] = linkLimit
        }
        return try await client.create("betaGroups", attributes: attributes, relationships: ["app": Client.link("apps", app.id)])
    }

    public func add(_ build: Resource, to group: Resource) async throws {
        try await client.send("POST", "betaGroups/\(group.id)/relationships/builds", body: ["data": [["type": "builds", "id": build.id]]])
    }

    /// Adds a tester to a group and sends the invitation.
    /// Adds a tester to `group` and sends the invitation email. A tester App Store Connect already
    /// knows is added to the group instead of created: an invite before the group had an approved
    /// build created the tester, then failed, and every retry after that answered 409.
    public func invite(email: String, firstName: String?, lastName: String?, to group: Resource) async throws {
        let tester: Resource
        if let existing = try await client.list("betaTesters?filter[email]=\(Client.query(email))&limit=1").first {
            try await client.send("POST", "betaGroups/\(group.id)/relationships/betaTesters",
                                  body: ["data": [["type": "betaTesters", "id": existing.id]]])
            tester = existing
        } else {
            var attributes: [String: Any] = ["email": email]
            if let firstName { attributes["firstName"] = firstName }
            if let lastName { attributes["lastName"] = lastName }
            guard let created = try await client.create("betaTesters", attributes: attributes,
                                                        relationships: ["betaGroups": ["data": [["type": "betaGroups", "id": group.id]]]]) else {
                throw APIError(status: 0, message: "App Store Connect didn't return the new tester")
            }
            tester = created
        }
        try await client.create("betaTesterInvitations",
                                relationships: ["app": Client.link("apps", app.id), "betaTester": Client.link("betaTesters", tester.id)])
    }
}
