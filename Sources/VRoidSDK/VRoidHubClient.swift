public import Foundation

/// The entry point of the SDK: authentication, VRoid Hub API access, model
/// download, and the encrypted model cache.
///
/// ```swift
/// let client = VRoidHubClient(configuration: configuration)
/// let account = try await client.signIn()
/// let page = try await client.characterModels()
/// let downloaded = try await client.downloadModel(page.items[0])
/// let data = try await client.modelData(for: downloaded)
/// ```
public actor VRoidHubClient {
    private struct DownloadKey: Hashable {
        let modelID: String
        let versionID: String?
    }

    private let configuration: VRoidHubConfiguration
    private let api: AuthenticatedAPIClient
    private let oauth: OAuthService
    private let tokenManager: TokenManager
    private let cache: ModelCache
    private let downloader: ModelDownloader
    private let userAgentOverride: (any AuthorizationUserAgent)?

    private var inFlightDownloads: [DownloadKey: Task<DownloadedVRoidModel, any Error>] = [:]

    public init(configuration: VRoidHubConfiguration) {
        self.init(
            configuration: configuration,
            transport: URLSessionTransport(),
            tokenStore: KeychainTokenStore(clientID: configuration.credential.clientID),
            cacheDirectory: ModelCache.defaultDirectory,
            cacheKeyProvider: KeychainCacheKeyProvider.shared,
            dateProvider: SystemDateProvider()
        )
    }

    init(
        configuration: VRoidHubConfiguration,
        transport: any HTTPTransport,
        tokenStore: any TokenStore,
        cacheDirectory: URL,
        cacheKeyProvider: any CacheKeyProviding,
        dateProvider: any DateProviding,
        baseURL: URL = APIClient.defaultBaseURL,
        userAgent: (any AuthorizationUserAgent)? = nil
    ) {
        self.configuration = configuration
        let apiClient = APIClient(baseURL: baseURL, transport: transport, dateProvider: dateProvider)
        let oauth = OAuthService(
            api: apiClient,
            credential: configuration.credential,
            dateProvider: dateProvider
        )
        self.oauth = oauth
        let tokenManager = TokenManager(store: tokenStore, oauth: oauth, dateProvider: dateProvider)
        self.tokenManager = tokenManager
        self.api = AuthenticatedAPIClient(api: apiClient, tokenManager: tokenManager)
        self.cache = ModelCache(
            directory: cacheDirectory,
            configuration: configuration.cache,
            cryptor: ModelCacheCryptor(keyProvider: cacheKeyProvider),
            dateProvider: dateProvider
        )
        self.downloader = ModelDownloader(api: api, transport: transport)
        self.userAgentOverride = userAgent
    }

    // MARK: - Authentication

    /// Runs the OAuth 2.0 authorization code flow with PKCE and returns the
    /// signed-in user's account.
    @MainActor
    public func signIn() async throws -> VRoidAccount {
        let pkce = PKCE.generate()
        let state = Data.random(count: 16).base64URLEncodedString()

        let userAgent = try makeUserAgent()
        // Capturing the URI at the moment the authorize URL is built
        // guarantees the token exchange uses exactly the authorized URI,
        // even when the loopback flow rewrites the port at runtime.
        var effectiveRedirectURI = configuration.callback.redirectURI
        let callbackURL = try await userAgent.authenticate(redirectURI: configuration.callback.redirectURI) {
            effectiveRedirectURI = $0
            return try oauth.authorizationURL(pkce: pkce, state: state, redirectURI: $0)
        }
        let code = try OAuthCallbackValidator.authorizationCode(
            from: callbackURL,
            expectedState: state
        )
        let token = try await oauth.exchangeAuthorizationCode(
            code,
            codeVerifier: pkce.codeVerifier,
            redirectURI: effectiveRedirectURI
        )
        try await tokenManager.replace(token)
        return try await account()
    }

    /// Restores a previous session from the Keychain, returning `nil` when no
    /// session exists or the stored token is no longer valid.
    public func restoreSession() async throws -> VRoidAccount? {
        guard try await tokenManager.currentToken() != nil else {
            return nil
        }
        do {
            return try await account()
        } catch VRoidHubError.unauthorized {
            try? await tokenManager.clear()
            return nil
        }
    }

    /// Revokes the current token (best effort) and clears the stored session.
    public func signOut() async throws {
        if let token = try? await tokenManager.currentToken() {
            try? await oauth.revoke(accessToken: token.accessToken)
        }
        try await tokenManager.clear()
    }

    // MARK: - API

    public func account() async throws -> VRoidAccount {
        try await api.get("/api/account")
    }

    /// The signed-in user's own character models.
    public func characterModels(
        options: VRoidCharacterModelsOptions = VRoidCharacterModelsOptions()
    ) async throws -> VRoidPage<VRoidCharacterModel> {
        try await api.page("/api/account/character_models", query: options.queryItems)
    }

    /// Fetches the page referenced by ``VRoidPage/next`` of any listing of
    /// character models.
    public func characterModels(pageAt url: URL) async throws -> VRoidPage<VRoidCharacterModel> {
        try await api.page(at: url)
    }

    /// Models the user hearted on VRoid Hub that are available to this
    /// application. The official guidelines require presenting each model's
    /// conditions of use before it is used.
    public func hearts(options: VRoidHeartsOptions = VRoidHeartsOptions()) async throws -> VRoidPage<VRoidCharacterModel> {
        let applicationID = URLQueryItem(name: "application_id", value: configuration.credential.clientID)
        return try await api.page("/api/hearts", query: [applicationID] + options.queryItems)
    }

    /// Character models picked by the VRoid Hub staff.
    ///
    /// Staff picks pages wrap each model in a staff pick object, so follow
    /// `next` URLs with ``staffPicks(pageAt:)``, not
    /// ``characterModels(pageAt:)``.
    public func staffPicks(
        options: VRoidStaffPicksOptions = VRoidStaffPicksOptions()
    ) async throws -> VRoidPage<VRoidCharacterModel> {
        unwrapStaffPicks(try await api.page("/api/staff_picks", query: options.queryItems))
    }

    /// Fetches the page referenced by a staff picks `next` URL.
    public func staffPicks(pageAt url: URL) async throws -> VRoidPage<VRoidCharacterModel> {
        unwrapStaffPicks(try await api.page(at: url))
    }

    private func unwrapStaffPicks(_ page: VRoidPage<VRoidStaffPick>) -> VRoidPage<VRoidCharacterModel> {
        VRoidPage(items: page.items.compactMap(\.characterModel), next: page.next)
    }

    /// Searches public character models by keyword.
    public func searchCharacterModels(
        options: VRoidCharacterModelSearchOptions
    ) async throws -> VRoidPage<VRoidCharacterModel> {
        try await api.page("/api/search/character_models", query: options.queryItems)
    }

    public func characterModel(id: String) async throws -> VRoidCharacterModelDetail {
        try await api.get("/api/character_models/\(id)")
    }

    // MARK: - Lazy pagination

    /// All of the user's character models, fetched page by page on demand.
    public nonisolated func allCharacterModels(
        options: VRoidCharacterModelsOptions = VRoidCharacterModelsOptions()
    ) -> VRoidPageSequence<VRoidCharacterModel> {
        pageSequence { try await self.characterModels(options: options) }
    }

    /// All hearted models available to this application, fetched page by
    /// page on demand.
    public nonisolated func allHearts(
        options: VRoidHeartsOptions = VRoidHeartsOptions()
    ) -> VRoidPageSequence<VRoidCharacterModel> {
        pageSequence { try await self.hearts(options: options) }
    }

    /// All staff picks, fetched page by page on demand.
    public nonisolated func allStaffPicks(
        options: VRoidStaffPicksOptions = VRoidStaffPicksOptions()
    ) -> VRoidPageSequence<VRoidCharacterModel> {
        VRoidPageSequence(
            firstPage: { try await self.staffPicks(options: options) },
            nextPage: { try await self.staffPicks(pageAt: $0) }
        )
    }

    /// All search results, fetched page by page on demand.
    public nonisolated func allSearchResults(
        options: VRoidCharacterModelSearchOptions
    ) -> VRoidPageSequence<VRoidCharacterModel> {
        pageSequence { try await self.searchCharacterModels(options: options) }
    }

    private nonisolated func pageSequence(
        firstPage: @escaping @Sendable () async throws -> VRoidPage<VRoidCharacterModel>
    ) -> VRoidPageSequence<VRoidCharacterModel> {
        VRoidPageSequence(
            firstPage: firstPage,
            nextPage: { try await self.characterModels(pageAt: $0) }
        )
    }

    // MARK: - Download licenses

    public func downloadLicense(id: String) async throws -> VRoidDownloadLicense {
        try await api.get("/api/download_licenses/\(id)")
    }

    public func deleteDownloadLicense(id: String) async throws {
        try await api.delete("/api/download_licenses/\(id)")
    }

    // MARK: - Model download

    /// Downloads a model file into the encrypted cache, reusing the cached
    /// copy when the same version is already present with an unexpired
    /// download license. Concurrent requests for the same model share a
    /// single download.
    public func downloadModel(
        _ model: some VRoidCharacterModelDownloadable
    ) async throws -> DownloadedVRoidModel {
        let modelID = model.characterModelID
        let versionID = model.latestVersionID
        let downloadKey = DownloadKey(modelID: modelID, versionID: versionID)

        if let task = inFlightDownloads[downloadKey] {
            return try await task.value
        }
        let task = Task {
            try await performDownload(modelID: modelID, knownVersionID: versionID)
        }
        inFlightDownloads[downloadKey] = task
        defer { inFlightDownloads[downloadKey] = nil }
        return try await task.value
    }

    /// Returns the decrypted model data for a downloaded model.
    ///
    /// Throws ``VRoidHubError/cacheFailed`` if the cached file was evicted or
    /// corrupted; call ``downloadModel(_:)`` again in that case.
    public func modelData(for model: DownloadedVRoidModel) async throws -> Data {
        guard let data = await cache.modelData(
            modelID: model.characterModelID,
            versionID: model.characterModelVersionID
        ) else {
            throw VRoidHubError.cacheFailed
        }
        return data
    }

    /// Decrypts the model into a temporary file, passes its URL to
    /// `operation`, and deletes the file afterwards. The URL must not be used
    /// after `operation` returns.
    public func withModelFile<T: Sendable>(
        _ model: DownloadedVRoidModel,
        _ operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let data = try await modelData(for: model)
        let fileURL = try await cache.makeTemporaryPlaintextFile(data: data)
        do {
            let result = try await operation(fileURL)
            await cache.removeTemporaryFile(at: fileURL)
            return result
        } catch {
            await cache.removeTemporaryFile(at: fileURL)
            throw error
        }
    }

    // MARK: - Internals

    private func performDownload(modelID: String, knownVersionID: String?) async throws -> DownloadedVRoidModel {
        if let versionID = knownVersionID,
           let cached = await cachedDownloadedModel(modelID: modelID, versionID: versionID) {
            return cached
        }

        let license: VRoidDownloadLicense = try await api.post(
            "/api/download_licenses",
            formBody: ["character_model_id": modelID]
        )

        // The license response reveals and authorizes the current version. If
        // those exact encrypted bytes are cached, keep the new license and
        // avoid downloading the file again.
        if await cache.updateLicenseIfPresent(license) {
            return DownloadedVRoidModel(downloadLicense: license)
        }

        let data = try await downloader.downloadModelFile(licenseID: license.id)
        try await cache.store(modelData: data, license: license)
        return DownloadedVRoidModel(downloadLicense: license)
    }

    private func cachedDownloadedModel(modelID: String, versionID: String) async -> DownloadedVRoidModel? {
        guard let entry = await cache.validEntry(modelID: modelID, versionID: versionID) else {
            return nil
        }
        return DownloadedVRoidModel(
            downloadLicense: VRoidDownloadLicense(
                id: entry.downloadLicenseID,
                characterModelID: modelID,
                characterModelVersionID: versionID,
                expiresAt: entry.downloadLicenseExpiresAt
            )
        )
    }

    @MainActor
    private func makeUserAgent() throws -> any AuthorizationUserAgent {
        if let userAgentOverride {
            return userAgentOverride
        }
        switch configuration.callback {
        case .customScheme:
            return WebAuthenticationUserAgent()
        case .loopbackServer:
            #if os(macOS)
            return LoopbackUserAgent()
            #else
            throw VRoidHubError.invalidConfiguration("loopbackServer is only supported on macOS")
            #endif
        }
    }
}
