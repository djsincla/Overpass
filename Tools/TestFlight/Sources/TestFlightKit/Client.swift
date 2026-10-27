import Foundation

/// A JSON:API resource as App Store Connect returns it: type, id and attributes.
public struct Resource: @unchecked Sendable {
    public let type: String
    public let id: String
    public let attributes: [String: Any]

    init?(_ json: Any?) {
        guard let object = json as? [String: Any], let type = object["type"] as? String, let id = object["id"] as? String else { return nil }
        self.type = type
        self.id = id
        attributes = object["attributes"] as? [String: Any] ?? [:]
    }

    public subscript(_ key: String) -> Any? { attributes[key] }
    public func string(_ key: String) -> String? { attributes[key] as? String }
}

public struct APIError: Error, CustomStringConvertible {
    public let status: Int
    public let message: String
    public var description: String { "App Store Connect answered \(status): \(message)" }
}

/// Requests to the App Store Connect API, signed with a fresh token each time.
public struct Client: Sendable {
    public let signer: TokenSigner
    public var base = URL(string: "https://api.appstoreconnect.apple.com/v1/")!

    public init(signer: TokenSigner) { self.signer = signer }

    /// `path` is relative to /v1/ and may carry a query string.
    @discardableResult
    public func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: base) else { throw APIError(status: 0, message: "bad path \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + (try signer.token()), forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = data.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let errors = (json["errors"] as? [[String: Any]] ?? []).map { e in
                [e["title"] as? String, e["detail"] as? String].compactMap { $0 }.joined(separator: ": ")
            }
            throw APIError(status: status, message: errors.isEmpty ? String(decoding: data, as: UTF8.self) : errors.joined(separator: "; "))
        }
        return json
    }

    public func list(_ path: String) async throws -> [Resource] {
        (try await send("GET", path)["data"] as? [Any] ?? []).compactMap(Resource.init)
    }

    public func one(_ path: String) async throws -> Resource? {
        Resource(try await send("GET", path)["data"])
    }

    @discardableResult
    public func create(_ type: String, attributes: [String: Any] = [:], relationships: [String: Any] = [:]) async throws -> Resource? {
        var data: [String: Any] = ["type": type]
        if !attributes.isEmpty { data["attributes"] = attributes }
        if !relationships.isEmpty { data["relationships"] = relationships }
        return Resource(try await send("POST", type, body: ["data": data])["data"])
    }

    public func update(_ type: String, id: String, attributes: [String: Any]) async throws {
        try await send("PATCH", "\(type)/\(id)", body: ["data": ["type": type, "id": id, "attributes": attributes]])
    }

    /// A to-one relationship, as JSON:API wants it.
    public static func link(_ type: String, _ id: String) -> [String: Any] { ["data": ["type": type, "id": id]] }

    public static func query(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? text
    }
}
