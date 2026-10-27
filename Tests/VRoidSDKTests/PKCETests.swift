import Foundation
import Testing
@testable import VRoidSDK
@testable import VRoidSDKCore

struct PKCETests {
    @Test
    func challengeMatchesRFC7636TestVector() {
        // RFC 7636 Appendix B
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.codeChallenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test
    func generatedVerifiersConformToRFC7636AndAreUnique() {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let generated = (0..<100).map { _ in PKCE.generate() }
        for pkce in generated {
            #expect((43...128).contains(pkce.codeVerifier.count))
            #expect(pkce.codeVerifier.unicodeScalars.allSatisfy(allowed.contains))
            #expect(!pkce.codeChallenge.isEmpty)
        }
        #expect(Set(generated.map(\.codeVerifier)).count == generated.count)
    }
}

struct OAuthCallbackValidatorTests {
    @Test
    func extractsAuthorizationCode() throws {
        let url = URL(string: "myapp://oauth/vroid?code=abc123&state=expected")!
        let code = try VRoidHubAPI.authorizationCode(from: url, expectedState: "expected")
        #expect(code == "abc123")
    }

    @Test
    func rejectsMismatchedState() {
        let url = URL(string: "myapp://oauth/vroid?code=abc123&state=tampered")!
        #expect(throws: VRoidHubError.self) {
            try VRoidHubAPI.authorizationCode(from: url, expectedState: "expected")
        }
    }

    @Test
    func mapsAccessDeniedToCancellation() {
        let url = URL(string: "myapp://oauth/vroid?error=access_denied&state=expected")!
        let error = #expect(throws: VRoidHubError.self) {
            try VRoidHubAPI.authorizationCode(from: url, expectedState: "expected")
        }
        guard case .authenticationCancelled = error else {
            Issue.record("Expected authenticationCancelled, got \(String(describing: error))")
            return
        }
    }

    @Test
    func rejectsErrorResponseWithMismatchedState() {
        let url = URL(string: "myapp://oauth/vroid?error=access_denied&state=tampered")!
        let error = #expect(throws: VRoidHubError.self) {
            try VRoidHubAPI.authorizationCode(from: url, expectedState: "expected")
        }
        guard case .invalidOAuthState = error else {
            Issue.record("Expected invalidOAuthState, got \(String(describing: error))")
            return
        }
    }

    @Test
    func failsWithoutCode() {
        let url = URL(string: "myapp://oauth/vroid?state=expected")!
        #expect(throws: VRoidHubError.self) {
            try VRoidHubAPI.authorizationCode(from: url, expectedState: "expected")
        }
    }
}
