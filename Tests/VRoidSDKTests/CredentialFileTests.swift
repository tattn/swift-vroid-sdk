import Foundation
import Testing
@testable import VRoidSDK

struct CredentialFileTests {
    private static func json(
        redirectURI: String = "http://127.0.0.1",
        iosURLScheme: String = "http://127.0.0.1"
    ) -> Data {
        Data("""
        {
          "application_id": "app-id",
          "secret": "app-secret",
          "redirect_uri": "\(redirectURI)",
          "ios_url_scheme": "\(iosURLScheme)",
          "android_url_scheme": "\(iosURLScheme)",
          "scope": ["default"]
        }
        """.utf8)
    }

    @Test
    func decodesTheDownloadedFileFormat() throws {
        let file = try VRoidCredentialFile(data: Self.json())
        #expect(file.applicationID == "app-id")
        #expect(file.secret == "app-secret")
        #expect(file.redirectURI?.absoluteString == "http://127.0.0.1")
        #expect(file.credential.clientID == "app-id")
        #expect(file.credential.clientSecret == "app-secret")
    }

    @Test
    func loopbackRedirectURIBecomesALoopbackCallback() throws {
        let configuration = try VRoidHubConfiguration(
            credentialFile: try VRoidCredentialFile(data: Self.json())
        )
        guard case .loopbackServer(let uri) = configuration.callback else {
            Issue.record("Expected loopbackServer, got \(configuration.callback)")
            return
        }
        #expect(uri.absoluteString == "http://127.0.0.1")
    }

    @Test
    func customSchemeBecomesACustomSchemeCallback() throws {
        let file = try VRoidCredentialFile(data: Self.json(
            redirectURI: "myapp://vroidhub",
            iosURLScheme: "myapp://vroidhub"
        ))
        guard case .customScheme(let uri) = try file.callback() else {
            Issue.record("Expected customScheme")
            return
        }
        #expect(uri.absoluteString == "myapp://vroidhub")
    }

    @Test
    func explicitCallbackOverridesTheFile() throws {
        let override = OAuthCallback.customScheme(redirectURI: URL(string: "other://cb")!)
        let configuration = try VRoidHubConfiguration(
            credentialFile: try VRoidCredentialFile(data: Self.json()),
            callback: override
        )
        #expect(configuration.callback.redirectURI.absoluteString == "other://cb")
    }

    @Test
    func loadsFromAFileOnDisk() throws {
        let url = makeTestDirectory().appending(path: "credential.json.bytes")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Self.json().write(to: url)

        let configuration = try VRoidHubConfiguration(credentialFileAt: url)
        #expect(configuration.credential.clientID == "app-id")
    }

    @Test
    func reportsInvalidContent() {
        let error = #expect(throws: VRoidHubError.self) {
            try VRoidCredentialFile(data: Data("not json".utf8))
        }
        guard case .invalidConfiguration = error else {
            Issue.record("Expected invalidConfiguration, got \(String(describing: error))")
            return
        }
    }
}
