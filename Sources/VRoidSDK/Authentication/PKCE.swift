import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636). VRoid Hub requires the S256 method.
struct PKCE: Sendable {
    let codeVerifier: String
    let codeChallenge: String

    init(codeVerifier: String) {
        self.codeVerifier = codeVerifier
        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        self.codeChallenge = Data(digest).base64URLEncodedString()
    }

    static func generate() -> PKCE {
        // 32 random bytes produce a 43-character base64url verifier,
        // the minimum length allowed by RFC 7636.
        PKCE(codeVerifier: Data.random(count: 32).base64URLEncodedString())
    }
}
