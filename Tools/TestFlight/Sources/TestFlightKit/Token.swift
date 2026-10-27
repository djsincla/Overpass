import CryptoKit
import Foundation

/// The signed token App Store Connect wants on every request: a JWT, ES256, from a team API key.
/// Apple limits its life to 20 minutes, so a fresh one is made well before that runs out.
public struct TokenSigner: Sendable {
    public let keyID: String
    public let issuerID: String
    private let key: P256.Signing.PrivateKey

    /// `pem` is the contents of the AuthKey_<keyID>.p8 file Apple gives you.
    public init(keyID: String, issuerID: String, pem: String) throws {
        self.keyID = keyID
        self.issuerID = issuerID
        key = try P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    /// Signs with an existing key: for tests.
    public init(keyID: String, issuerID: String, key: P256.Signing.PrivateKey) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.key = key
    }

    public func token(now: Date = .now, lifetime: TimeInterval = 15 * 60) throws -> String {
        let header = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let issued = Int(now.timeIntervalSince1970)
        let payload: [String: Any] = ["iss": issuerID, "iat": issued, "exp": issued + Int(lifetime), "aud": "appstoreconnect-v1"]
        let signingInput = try Self.base64URL(JSONSerialization.data(withJSONObject: header, options: .sortedKeys))
            + "." + Self.base64URL(JSONSerialization.data(withJSONObject: payload, options: .sortedKeys))
        // The raw 64-byte r‖s form, which is what JWT's ES256 means (not DER).
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return signingInput + "." + Self.base64URL(signature)
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func fromBase64URL(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
