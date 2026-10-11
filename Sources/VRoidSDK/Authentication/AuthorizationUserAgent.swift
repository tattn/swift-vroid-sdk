import AuthenticationServices
import Foundation

/// Presents the authorization page to the user and returns the callback URL.
///
/// The user agent passes the effective redirect URI (the loopback flow binds
/// its port dynamically) to the `authorizationURL` closure exactly once; the
/// caller owns recording it, so the URI that was authorized is structurally
/// the URI used for the token exchange.
@MainActor
protocol AuthorizationUserAgent: Sendable {
    func authenticate(
        redirectURI: URL,
        authorizationURL: @MainActor (URL) throws -> URL
    ) async throws -> URL
}

/// `ASWebAuthenticationSession`-based user agent for custom scheme callbacks.
@MainActor
final class WebAuthenticationUserAgent: NSObject, AuthorizationUserAgent {
    private var activeSession: ASWebAuthenticationSession?

    func authenticate(
        redirectURI: URL,
        authorizationURL: @MainActor (URL) throws -> URL
    ) async throws -> URL {
        guard let scheme = redirectURI.scheme, scheme != "http", scheme != "https" else {
            throw VRoidHubError.invalidConfiguration(
                "customScheme requires a custom URL scheme redirect URI (e.g. myapp://oauth/vroid)"
            )
        }
        let authorizationURL = try authorizationURL(redirectURI)
        defer { activeSession = nil }
        return try await withCheckedThrowingContinuation { continuation in
            // `start()` can both return false and invoke the completion handler
            // with an error (e.g. while the app is returning to the foreground).
            var pendingContinuation: CheckedContinuation<URL, any Error>? = continuation
            func finish(_ result: Result<URL, any Error>) {
                pendingContinuation?.resume(with: result)
                pendingContinuation = nil
            }
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callback: .customScheme(scheme)
            ) { callbackURL, error in
                if let callbackURL {
                    finish(.success(callbackURL))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    finish(.failure(VRoidHubError.authenticationCancelled))
                } else {
                    finish(.failure(VRoidHubError.authenticationFailed))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            if !session.start() {
                activeSession = nil
                finish(.failure(VRoidHubError.authenticationFailed))
            }
        }
    }
}

extension WebAuthenticationUserAgent: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? ASPresentationAnchor()
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if os(macOS)
/// Opens the authorization page in the user's default browser and receives
/// the redirect on a one-time loopback HTTP server, like the official Unity
/// SDK's desktop flow. The default browser keeps the user's existing VRoid
/// Hub login session.
@MainActor
final class LoopbackUserAgent: AuthorizationUserAgent {
    func authenticate(
        redirectURI: URL,
        authorizationURL: @MainActor (URL) throws -> URL
    ) async throws -> URL {
        let server = try LoopbackCallbackServer(redirectURI: redirectURI)
        defer { server.stop() }
        let effectiveRedirectURI = try await server.start()
        let authorizationURL = try authorizationURL(effectiveRedirectURI)
        guard NSWorkspace.shared.open(authorizationURL) else {
            throw VRoidHubError.authenticationFailed
        }
        return try await server.waitForCallback()
    }
}
#endif

enum OAuthCallbackValidator {
    /// Extracts the authorization code from the callback URL, verifying `state`.
    static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw VRoidHubError.authenticationFailed
        }
        let queryItems = components.queryItems ?? []
        func value(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value
        }
        guard value("state") == expectedState else {
            throw VRoidHubError.invalidOAuthState
        }
        if let error = value("error") {
            throw error == "access_denied"
                ? VRoidHubError.authenticationCancelled
                : VRoidHubError.authenticationFailed
        }
        guard let code = value("code"), !code.isEmpty else {
            throw VRoidHubError.authenticationFailed
        }
        return code
    }
}
