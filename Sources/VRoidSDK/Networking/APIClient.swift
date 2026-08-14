import Foundation

enum APIVersion {
    /// The API version this SDK is implemented against. Not configurable:
    /// a different version may change response shapes the SDK relies on.
    static let current = 11
}

struct APIClient: Sendable {
    static let defaultBaseURL = URL(string: "https://hub.vroid.com")!

    let baseURL: URL
    let transport: any HTTPTransport
    let dateProvider: any DateProviding

    init(
        baseURL: URL = APIClient.defaultBaseURL,
        transport: any HTTPTransport,
        dateProvider: any DateProviding = SystemDateProvider()
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.dateProvider = dateProvider
    }

    // MARK: Requests

    func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        accessToken: String? = nil,
        formBody: [String: String]? = nil
    ) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
        }
        return makeRequest(method: method, url: components.url!, accessToken: accessToken, formBody: formBody)
    }

    func makeRequest(
        method: String,
        url: URL,
        accessToken: String? = nil,
        formBody: [String: String]? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("\(APIVersion.current)", forHTTPHeaderField: "X-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let formBody {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = FormBody.encode(formBody)
        }
        return request
    }

    // MARK: Response handling

    func decodePayload<Payload: Decodable>(
        _ type: Payload.Type,
        from response: HTTPResponse
    ) throws -> (payload: Payload, links: APILinks?) {
        try validate(response)
        guard let envelope = try? Self.makeDecoder().decode(APIEnvelope<Payload>.self, from: response.body) else {
            throw VRoidHubError.invalidResponse
        }
        if let payload = envelope.data {
            return (payload, envelope.links)
        }
        if let error = envelope.error {
            throw Self.apiError(error, statusCode: response.statusCode)
        }
        throw VRoidHubError.invalidResponse
    }

    /// Maps a non-2xx response to a ``VRoidHubError``.
    func validate(_ response: HTTPResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw VRoidHubError.unauthorized
        case 403:
            throw VRoidHubError.forbidden
        case 404:
            throw VRoidHubError.notFound
        case 429:
            throw VRoidHubError.rateLimited(retryAfter: retryAfterDate(from: response))
        default:
            if let envelope = try? Self.makeDecoder().decode(APIEnvelope<EmptyPayload>.self, from: response.body),
               let error = envelope.error {
                throw Self.apiError(error, statusCode: response.statusCode)
            }
            throw VRoidHubError.invalidResponse
        }
    }

    private static func apiError(_ error: APIErrorPayload, statusCode: Int) -> VRoidHubError {
        .api(code: error.code ?? "\(statusCode)", message: error.message ?? "")
    }

    func retryAfterDate(from response: HTTPResponse) -> Date? {
        guard let value = response.headerValue("Retry-After") else { return nil }
        if let seconds = TimeInterval(value) {
            return dateProvider.now.addingTimeInterval(seconds)
        }
        return httpDateFormatter.date(from: value)
    }

    func resolve(link: APILink?) -> URL? {
        guard let link else { return nil }
        return URL(string: link.href, relativeTo: baseURL)?.absoluteURL
    }

    // MARK: Decoding

    /// `JSONDecoder` is not `Sendable`; create one per use.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                if let date = (try? iso8601WithFractionalSeconds.parse(string)) ?? (try? iso8601.parse(string)) {
                    return date
                }
            }
            if let epoch = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: epoch)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported date format")
        }
        return decoder
    }
}

private let iso8601WithFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
private let iso8601 = Date.ISO8601FormatStyle()

private let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}()

enum FormBody {
    // RFC 3986 unreserved characters; URLComponents is not suitable here
    // because it leaves sub-delims like "+" unescaped in query encoding.
    private static let allowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    static func encode(_ parameters: [String: String]) -> Data {
        let encoded = parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }
}
