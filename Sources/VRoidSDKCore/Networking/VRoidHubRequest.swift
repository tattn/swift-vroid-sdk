#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// An HTTP request to VRoid Hub, described without sending it so that any HTTP
/// client can perform it.
public struct VRoidHubRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// `false` when the redirect response itself is the answer, so the client
    /// must return it instead of following it.
    public var followsRedirects: Bool
    /// Whether the request must carry the user's access token; send
    /// ``authorized(by:)`` instead.
    public var requiresAuthorization: Bool

    public init(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        followsRedirects: Bool = true,
        requiresAuthorization: Bool = false
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.followsRedirects = followsRedirects
        self.requiresAuthorization = requiresAuthorization
    }

    /// The request carrying `accessToken` as its bearer token.
    public func authorized(by accessToken: String) -> VRoidHubRequest {
        var request = self
        request.headers["Authorization"] = "Bearer \(accessToken)"
        return request
    }
}

/// An HTTP response to a ``VRoidHubRequest``.
public struct VRoidHubResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// The value of the header `name`, matched case-insensitively (HTTP/2
    /// delivers header names in lowercase).
    public func headerValue(_ name: String) -> String? {
        let name = name.lowercased()
        return headers.first { $0.key.lowercased() == name }?.value
    }
}

/// One VRoid Hub API call: the request to send and how to read its response.
///
/// ```swift
/// let call = api.account()
/// let response = try await send(call.request.authorized(by: accessToken))
/// let account = try call.result(from: response)
/// ```
///
/// A 401 response means the access token was rejected: refresh the token and
/// send the request again before reading the result.
public struct VRoidHubCall<Result>: Sendable {
    public let request: VRoidHubRequest
    private let read: @Sendable (VRoidHubResponse) throws -> Result

    package init(request: VRoidHubRequest, read: @escaping @Sendable (VRoidHubResponse) throws -> Result) {
        self.request = request
        self.read = read
    }

    /// Interprets the response to ``request``, throwing ``VRoidHubError`` for
    /// failures.
    public func result(from response: VRoidHubResponse) throws -> Result {
        try read(response)
    }
}

enum FormBody {
    static func encode(_ parameters: [String: String]) -> Data {
        let encoded = parameters
            .sorted { $0.key < $1.key }
            .map { key, value in "\(percentEncoded(key))=\(percentEncoded(value))" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    /// Escapes everything outside the RFC 3986 unreserved characters.
    /// URLComponents is not suitable here because it leaves sub-delims like
    /// "+" unescaped in query encoding.
    private static func percentEncoded(_ string: String) -> String {
        var encoded = ""
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "~"):
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                let hex = String(byte, radix: 16, uppercase: true)
                encoded += byte < 16 ? "%0\(hex)" : "%\(hex)"
            }
        }
        return encoded
    }
}
