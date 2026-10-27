import CryptoKit
import Foundation
import Testing
@testable import TestFlightKit

@Suite struct TokenTests {
    let key = P256.Signing.PrivateKey()

    func parts(_ token: String) -> [String] { token.split(separator: ".").map(String.init) }

    func json(_ part: String) throws -> [String: Any] {
        let data = try #require(TokenSigner.fromBase64URL(part))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func headerAndClaimsAreWhatAppleAsks() throws {
        let signer = TokenSigner(keyID: "ABC123DEFG", issuerID: "57246542-96fe-1a63-e053-0824d011072a", key: key)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try signer.token(now: now)
        let p = parts(token)
        #expect(p.count == 3)
        let header = try json(p[0]), claims = try json(p[1])
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "ABC123DEFG")
        #expect(header["typ"] as? String == "JWT")
        #expect(claims["iss"] as? String == "57246542-96fe-1a63-e053-0824d011072a")
        #expect(claims["aud"] as? String == "appstoreconnect-v1")
        #expect(claims["iat"] as? Int == 1_800_000_000)
        // Apple refuses tokens that live longer than 20 minutes.
        let life = try #require(claims["exp"] as? Int) - 1_800_000_000
        #expect(life > 0 && life <= 20 * 60)
    }

    @Test func signatureVerifiesWithThePublicKey() throws {
        let token = try TokenSigner(keyID: "K", issuerID: "I", key: key).token()
        let p = parts(token)
        let raw = try #require(TokenSigner.fromBase64URL(p[2]))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        #expect(key.publicKey.isValidSignature(signature, for: Data((p[0] + "." + p[1]).utf8)))
        // Base64url: no padding or characters that need escaping.
        #expect(!token.contains("=") && !token.contains("+") && !token.contains("/"))
    }

    @Test func readsAppleStyleKeyFiles() throws {
        // Apple's .p8 files are PKCS#8 PEM.
        let pem = key.pemRepresentation
        #expect(pem.hasPrefix("-----BEGIN PRIVATE KEY-----"))
        let signer = try TokenSigner(keyID: "K", issuerID: "I", pem: pem)
        #expect(try !signer.token().isEmpty)
    }
}
