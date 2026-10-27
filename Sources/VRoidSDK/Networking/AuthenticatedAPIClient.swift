import Foundation
import VRoidSDKCore

/// Performs ``VRoidHubCall``s, attaching the access token where needed and
/// retrying once after a coalesced token refresh when the API responds with 401.
struct AuthenticatedAPIClient: Sendable {
    let api: VRoidHubAPI
    let transport: any HTTPTransport
    private let tokenManager: TokenManager

    init(api: VRoidHubAPI, transport: any HTTPTransport, tokenManager: TokenManager) {
        self.api = api
        self.transport = transport
        self.tokenManager = tokenManager
    }

    func perform<Result>(_ call: VRoidHubCall<Result>) async throws -> Result {
        try call.result(from: await send(call.request))
    }

    private func send(_ request: VRoidHubRequest) async throws -> VRoidHubResponse {
        guard request.requiresAuthorization else {
            return try await transport.send(request)
        }
        let token = try await tokenManager.validAccessToken()
        let response = try await transport.send(request.authorized(by: token))
        guard response.statusCode == 401 else {
            return response
        }
        let refreshedToken = try await tokenManager.tokenAfterAuthorizationFailure(staleAccessToken: token)
        return try await transport.send(request.authorized(by: refreshedToken))
    }
}
