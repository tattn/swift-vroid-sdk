#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The VRoid Hub API without I/O. Each method returns a ``VRoidHubCall``
/// describing the request and how to read the response, so that any HTTP
/// client and token storage can drive it. `VRoidHubClient` (in `VRoidSDK`)
/// performs these calls with `URLSession` and the Keychain on Apple platforms.
public struct VRoidHubAPI: Sendable {
    public static let defaultBaseURL = URL(string: "https://hub.vroid.com")!

    /// The API version this SDK is implemented against. Not configurable:
    /// a different version may change response shapes the SDK relies on.
    static let version = 11

    public let credential: VRoidCredential
    public let baseURL: URL
    package let dateProvider: any DateProviding

    public init(credential: VRoidCredential, baseURL: URL = VRoidHubAPI.defaultBaseURL) {
        self.init(credential: credential, baseURL: baseURL, dateProvider: SystemDateProvider())
    }

    package init(credential: VRoidCredential, baseURL: URL = VRoidHubAPI.defaultBaseURL, dateProvider: any DateProviding) {
        self.credential = credential
        self.baseURL = baseURL
        self.dateProvider = dateProvider
    }

    // MARK: - Account and character models

    public func account() -> VRoidHubCall<VRoidAccount> {
        payloadCall(apiRequest("GET", "/api/account"))
    }

    /// The signed-in user's own character models.
    public func characterModels(
        options: VRoidCharacterModelsOptions = VRoidCharacterModelsOptions()
    ) -> VRoidHubCall<VRoidPage<VRoidCharacterModel>> {
        pageCall(apiRequest("GET", "/api/account/character_models", query: options.queryItems))
    }

    /// The page referenced by ``VRoidPage/next`` of any listing of character
    /// models except staff picks. Throws for URLs outside the API origin.
    public func characterModels(pageAt url: URL) throws -> VRoidHubCall<VRoidPage<VRoidCharacterModel>> {
        pageCall(try pageRequest(at: url))
    }

    /// Models the user hearted on VRoid Hub that are available to this
    /// application. The official guidelines require presenting each model's
    /// conditions of use before it is used.
    public func hearts(
        options: VRoidHeartsOptions = VRoidHeartsOptions()
    ) -> VRoidHubCall<VRoidPage<VRoidCharacterModel>> {
        let applicationID = URLQueryItem(name: "application_id", value: credential.clientID)
        return pageCall(apiRequest("GET", "/api/hearts", query: [applicationID] + options.queryItems))
    }

    /// Character models picked by the VRoid Hub staff.
    ///
    /// Staff picks pages wrap each model in a staff pick object, so follow
    /// `next` URLs with ``staffPicks(pageAt:)``, not ``characterModels(pageAt:)``.
    public func staffPicks(
        options: VRoidStaffPicksOptions = VRoidStaffPicksOptions()
    ) -> VRoidHubCall<VRoidPage<VRoidCharacterModel>> {
        staffPicksCall(apiRequest("GET", "/api/staff_picks", query: options.queryItems))
    }

    /// The page referenced by a staff picks `next` URL.
    public func staffPicks(pageAt url: URL) throws -> VRoidHubCall<VRoidPage<VRoidCharacterModel>> {
        staffPicksCall(try pageRequest(at: url))
    }

    /// Searches public character models by keyword.
    public func searchCharacterModels(
        options: VRoidCharacterModelSearchOptions
    ) -> VRoidHubCall<VRoidPage<VRoidCharacterModel>> {
        pageCall(apiRequest("GET", "/api/search/character_models", query: options.queryItems))
    }

    public func characterModel(id: String) -> VRoidHubCall<VRoidCharacterModelDetail> {
        payloadCall(apiRequest("GET", "/api/character_models/\(id)"))
    }

    // MARK: - Download licenses and model files

    /// Issues a download license for the latest version of a model. The
    /// license tells which version it authorizes.
    public func issueDownloadLicense(characterModelID: String) -> VRoidHubCall<VRoidDownloadLicense> {
        payloadCall(apiRequest("POST", "/api/download_licenses", form: ["character_model_id": characterModelID]))
    }

    public func downloadLicense(id: String) -> VRoidHubCall<VRoidDownloadLicense> {
        payloadCall(apiRequest("GET", "/api/download_licenses/\(id)"))
    }

    public func deleteDownloadLicense(id: String) -> VRoidHubCall<Void> {
        VRoidHubCall(request: apiRequest("DELETE", "/api/download_licenses/\(id)")) { response in
            try validate(response)
        }
    }

    /// Locates the model file a download license authorizes. The API answers
    /// with a redirect to a presigned URL, so the result is the call that
    /// fetches the file itself. That call carries no API headers and needs no
    /// access token: the file host must never receive them.
    public func modelFile(downloadLicenseID: String) -> VRoidHubCall<VRoidHubCall<Data>> {
        var request = apiRequest("GET", "/api/download_licenses/\(downloadLicenseID)/download")
        request.followsRedirects = false
        return VRoidHubCall(request: request) { response in
            guard (300..<400).contains(response.statusCode) else {
                // The endpoint is specified to respond with a redirect;
                // anything else (including 2xx) must not be treated as model data.
                try validate(response)
                throw VRoidHubError.downloadFailed
            }
            guard let location = response.headerValue("Location"), let fileURL = URL(string: location) else {
                throw VRoidHubError.downloadFailed
            }
            return VRoidHubCall(request: VRoidHubRequest(method: "GET", url: fileURL)) { response in
                guard (200..<300).contains(response.statusCode), !response.body.isEmpty else {
                    throw VRoidHubError.downloadFailed
                }
                return response.body
            }
        }
    }

    // MARK: - OAuth

    /// The authorization page for the OAuth 2.0 authorization code flow with
    /// PKCE (S256). `codeChallenge` is the base64url SHA-256 of the code
    /// verifier later passed to ``tokenExchange(authorizationCode:codeVerifier:redirectURI:)``.
    public func authorizationURL(codeChallenge: String, state: String, redirectURI: URL) throws -> URL {
        var components = URLComponents(
            url: baseURL.appending(path: "/oauth/authorize"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: credential.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: "default"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else {
            throw VRoidHubError.invalidConfiguration("Could not build the authorization URL")
        }
        return url
    }

    /// Extracts the authorization code from the redirect back from the
    /// authorization page, verifying `state`.
    public static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
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

    /// Exchanges the authorization code for a token. `redirectURI` must be the
    /// exact URI the authorization page was opened with.
    public func tokenExchange(
        authorizationCode: String,
        codeVerifier: String,
        redirectURI: URL
    ) -> VRoidHubCall<VRoidOAuthToken> {
        tokenCall(parameters: [
            "grant_type": "authorization_code",
            "code": authorizationCode,
            "redirect_uri": redirectURI.absoluteString,
            "client_id": credential.clientID,
            "client_secret": credential.clientSecret,
            "code_verifier": codeVerifier,
        ], currentRefreshToken: nil, failure: .authenticationFailed)
    }

    /// Refreshes `token`. Fails with ``VRoidHubError/unauthorized`` when the
    /// refresh token was rejected, meaning the session is over.
    public func tokenRefresh(_ token: VRoidOAuthToken) -> VRoidHubCall<VRoidOAuthToken> {
        tokenCall(parameters: [
            "grant_type": "refresh_token",
            "refresh_token": token.refreshToken,
            "client_id": credential.clientID,
            "client_secret": credential.clientSecret,
        ], currentRefreshToken: token.refreshToken, failure: .unauthorized)
    }

    public func tokenRevocation(accessToken: String) -> VRoidHubCall<Void> {
        let request = apiRequest("POST", "/oauth/revoke", form: [
            "client_id": credential.clientID,
            "client_secret": credential.clientSecret,
            "token": accessToken,
        ], requiresAuthorization: false).authorized(by: accessToken)
        return VRoidHubCall(request: request) { response in
            guard (200..<300).contains(response.statusCode) else {
                throw VRoidHubError.invalidResponse
            }
        }
    }

    // MARK: - Requests

    private func apiRequest(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        form: [String: String]? = nil,
        requiresAuthorization: Bool = true
    ) -> VRoidHubRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
        }
        var request = apiRequest(method, url: components.url!, requiresAuthorization: requiresAuthorization)
        if let form {
            request.headers["Content-Type"] = "application/x-www-form-urlencoded"
            request.body = FormBody.encode(form)
        }
        return request
    }

    private func apiRequest(_ method: String, url: URL, requiresAuthorization: Bool = true) -> VRoidHubRequest {
        VRoidHubRequest(
            method: method,
            url: url,
            headers: ["X-Api-Version": "\(Self.version)", "Accept": "application/json"],
            requiresAuthorization: requiresAuthorization
        )
    }

    /// Requests a `_links.next` URL, refusing URLs that do not belong to the
    /// API origin (the request carries the access token).
    private func pageRequest(at url: URL) throws -> VRoidHubRequest {
        guard Self.isSameOrigin(url, baseURL) else {
            throw VRoidHubError.invalidConfiguration("Page URL does not belong to the VRoid Hub API")
        }
        return apiRequest("GET", url: url)
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              lhsScheme == rhsScheme,
              let lhsHost = lhs.host(),
              let rhsHost = rhs.host(),
              lhsHost.lowercased() == rhsHost.lowercased()
        else {
            return false
        }
        return effectivePort(of: lhs, scheme: lhsScheme) == effectivePort(of: rhs, scheme: rhsScheme)
    }

    private static func effectivePort(of url: URL, scheme: String) -> Int? {
        if let port = url.port {
            return port
        }
        return switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
    }

    // MARK: - Responses

    private func payloadCall<Payload: Decodable & SendableMetatype>(_ request: VRoidHubRequest) -> VRoidHubCall<Payload> {
        VRoidHubCall(request: request) { response in
            try decodePayload(Payload.self, from: response).payload
        }
    }

    private func pageCall(_ request: VRoidHubRequest) -> VRoidHubCall<VRoidPage<VRoidCharacterModel>> {
        VRoidHubCall(request: request) { response in
            try decodePage([VRoidCharacterModel].self, from: response) { $0 }
        }
    }

    private func staffPicksCall(_ request: VRoidHubRequest) -> VRoidHubCall<VRoidPage<VRoidCharacterModel>> {
        VRoidHubCall(request: request) { response in
            try decodePage([VRoidStaffPick].self, from: response) { $0.compactMap(\.characterModel) }
        }
    }

    private func decodePage<Items: Decodable & SendableMetatype>(
        _ type: Items.Type,
        from response: VRoidHubResponse,
        models: (Items) -> [VRoidCharacterModel]
    ) throws -> VRoidPage<VRoidCharacterModel> {
        let (items, links) = try decodePayload(Items.self, from: response)
        let next = links?.next.flatMap { URL(string: $0.href, relativeTo: baseURL)?.absoluteURL }
        return VRoidPage(items: models(items), next: next)
    }

    package func decodePayload<Payload: Decodable>(
        _ type: Payload.Type,
        from response: VRoidHubResponse
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

    /// Maps a non-2xx response to a ``VRoidHubError``. A reason the API gave
    /// (e.g. a model not available to this application) wins over the bare
    /// status, so that it can be shown to the user.
    package func validate(_ response: VRoidHubResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw VRoidHubError.unauthorized
        case 429:
            throw VRoidHubError.rateLimited(retryAfter: retryAfterDate(from: response))
        default:
            if let envelope = try? Self.makeDecoder().decode(APIEnvelope<EmptyPayload>.self, from: response.body),
               let error = envelope.error {
                throw Self.apiError(error, statusCode: response.statusCode)
            }
            switch response.statusCode {
            case 403: throw VRoidHubError.forbidden
            case 404: throw VRoidHubError.notFound
            default: throw VRoidHubError.invalidResponse
            }
        }
    }

    private static func apiError(_ error: APIErrorPayload, statusCode: Int) -> VRoidHubError {
        .api(code: error.code ?? "\(statusCode)", message: error.message ?? "")
    }

    package func retryAfterDate(from response: VRoidHubResponse) -> Date? {
        guard let value = response.headerValue("Retry-After") else { return nil }
        if let seconds = TimeInterval(value) {
            return dateProvider.now.addingTimeInterval(seconds)
        }
        return HTTPDate.parse(value)
    }

    private func tokenCall(
        parameters: [String: String],
        currentRefreshToken: String?,
        failure: VRoidHubError
    ) -> VRoidHubCall<VRoidOAuthToken> {
        // The token endpoint authenticates with the client credentials, not a user's token.
        let request = apiRequest("POST", "/oauth/token", form: parameters, requiresAuthorization: false)
        return VRoidHubCall(request: request) { response in
            // The token endpoint speaks plain OAuth, not the API envelope, so
            // failures are mapped here instead of through validate.
            switch response.statusCode {
            case 200..<300:
                break
            case 400, 401:
                // The grant or the credentials were rejected.
                throw failure
            case 429:
                throw VRoidHubError.rateLimited(retryAfter: retryAfterDate(from: response))
            default:
                // Transient server failures must not be mistaken for a revoked
                // session (callers end the session on unauthorized).
                throw VRoidHubError.invalidResponse
            }
            guard let payload = try? JSONDecoder().decode(TokenResponse.self, from: response.body) else {
                throw VRoidHubError.invalidResponse
            }
            guard let refreshToken = payload.refreshToken ?? currentRefreshToken else {
                throw VRoidHubError.invalidResponse
            }
            return VRoidOAuthToken(
                accessToken: payload.accessToken,
                refreshToken: refreshToken,
                expiresAt: dateProvider.now.addingTimeInterval(TimeInterval(payload.expiresIn))
            )
        }
    }

    // MARK: - Decoding

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

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

/// The IMF-fixdate form of an HTTP date (`Sun, 06 Nov 1994 08:49:37 GMT`),
/// parsed by hand because `DateFormatter` needs ICU.
enum HTTPDate {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func parse(_ value: String) -> Date? {
        let fields = value.split(separator: " ")
        guard fields.count == 6, fields[5] == "GMT",
              let day = Int(fields[1]),
              let month = months.firstIndex(of: String(fields[2])).map({ $0 + 1 }),
              let year = Int(fields[3])
        else {
            return nil
        }
        let time = fields[4].split(separator: ":").compactMap { Int($0) }
        guard time.count == 3 else { return nil }
        let seconds = daysSince1970(year: year, month: month, day: day) * 86_400 + time[0] * 3_600 + time[1] * 60 + time[2]
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Days from 1970-01-01 in the proleptic Gregorian calendar (Howard
    /// Hinnant's `days_from_civil`).
    private static func daysSince1970(year: Int, month: Int, day: Int) -> Int {
        let year = month <= 2 ? year - 1 : year
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
