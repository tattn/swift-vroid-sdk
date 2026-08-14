public import Foundation

/// The `credential.json.bytes` file downloadable from the VRoid Hub
/// application management page.
///
/// ```json
/// {
///   "application_id": "...",
///   "secret": "...",
///   "redirect_uri": "http://127.0.0.1",
///   "ios_url_scheme": "myapp://vroidhub",
///   "android_url_scheme": "myapp://vroidhub",
///   "scope": ["default"]
/// }
/// ```
public struct VRoidCredentialFile: Decodable, Sendable {
    public let applicationID: String
    public let secret: String
    /// Redirect URI registered for desktop use.
    public let redirectURI: URL?
    /// Redirect URI registered for iOS, typically a custom URL scheme.
    public let iosURLScheme: URL?
    public let androidURLScheme: URL?

    enum CodingKeys: String, CodingKey {
        case applicationID = "application_id"
        case secret
        case redirectURI = "redirect_uri"
        case iosURLScheme = "ios_url_scheme"
        case androidURLScheme = "android_url_scheme"
    }

    public init(data: Data) throws {
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw VRoidHubError.invalidConfiguration("credential.json.bytes could not be parsed")
        }
    }

    public init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            throw VRoidHubError.invalidConfiguration("credential.json.bytes could not be read at \(url.path)")
        }
        try self.init(data: data)
    }

    public var credential: VRoidCredential {
        VRoidCredential(clientID: applicationID, clientSecret: secret)
    }

    /// The callback matching the current platform: the iOS URL scheme on iOS,
    /// and the desktop redirect URI on macOS. A custom scheme is intercepted
    /// by `ASWebAuthenticationSession`; a loopback URI starts the local
    /// callback server.
    public func callback() throws -> OAuthCallback {
        #if os(macOS)
        let candidates = [redirectURI, iosURLScheme]
        #else
        let candidates = [iosURLScheme, redirectURI]
        #endif
        guard let uri = candidates.compactMap(\.self).first else {
            throw VRoidHubError.invalidConfiguration("credential.json.bytes contains no redirect URI")
        }
        return switch uri.scheme {
        case "http", "https": .loopbackServer(redirectURI: uri)
        default: .customScheme(redirectURI: uri)
        }
    }
}

extension VRoidHubConfiguration {
    /// Builds a configuration from a `credential.json.bytes` file downloaded
    /// from the VRoid Hub application management page.
    ///
    /// ```swift
    /// let url = Bundle.main.url(forResource: "credential.json", withExtension: "bytes")!
    /// let client = VRoidHubClient(configuration: try VRoidHubConfiguration(credentialFileAt: url))
    /// ```
    public init(
        credentialFile: VRoidCredentialFile,
        callback: OAuthCallback? = nil,
        cache: VRoidCacheConfiguration = VRoidCacheConfiguration()
    ) throws {
        self.init(
            credential: credentialFile.credential,
            callback: try callback ?? credentialFile.callback(),
            cache: cache
        )
    }

    public init(
        credentialFileAt url: URL,
        callback: OAuthCallback? = nil,
        cache: VRoidCacheConfiguration = VRoidCacheConfiguration()
    ) throws {
        try self.init(
            credentialFile: try VRoidCredentialFile(contentsOf: url),
            callback: callback,
            cache: cache
        )
    }
}
