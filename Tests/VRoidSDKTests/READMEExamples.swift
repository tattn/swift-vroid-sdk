import Foundation
import VRoidSDK

/// Compile-only mirror of the README code samples, using the public API just
/// like an SDK consumer. Never executed; keeps the README honest as the API
/// evolves. Lines that depend on VRMKit are replaced by comments.
@MainActor
private enum READMEExamples {
    // README: Setup
    static func setup() -> VRoidHubClient {
        #if os(macOS)
        let callback = OAuthCallback.loopbackServer(redirectURI: URL(string: "http://127.0.0.1")!)
        #else
        let callback = OAuthCallback.customScheme(redirectURI: URL(string: "myapp://oauth/vroid")!)
        #endif

        let configuration = VRoidHubConfiguration(
            credential: VRoidCredential(
                clientID: "YOUR_CLIENT_ID",
                clientSecret: "YOUR_CLIENT_SECRET"
            ),
            callback: callback
        )

        return VRoidHubClient(configuration: configuration)
    }

    // README: Sign in
    static func signIn(client: VRoidHubClient) async throws {
        // Restore a previous session, or run the OAuth flow.
        let account: VRoidAccount
        if let restored = try await client.restoreSession() {
            account = restored
        } else {
            account = try await client.signIn()
        }
        print(account.user.name ?? "")
    }

    // README: List character models
    static func listCharacterModels(client: VRoidHubClient) async throws {
        var page = try await client.characterModels()
        for model in page.items {
            print(model.name ?? model.id)
        }

        // `page.next` is the only end-of-pagination signal.
        if let next = page.next {
            page = try await client.characterModels(pageAt: next)
        }
        _ = page

        // Or iterate all pages lazily.
        for try await model in client.allCharacterModels() {
            print(model.id)
        }
    }

    // README: Hearted models, staff picks, and keyword search
    static func otherListings(client: VRoidHubClient) async throws {
        let hearts = try await client.hearts(
            options: VRoidHeartsOptions(filters: VRoidCharacterModelFilters(isDownloadable: true))
        )

        let results = try await client.searchCharacterModels(
            options: VRoidCharacterModelSearchOptions(keyword: "cat", sort: .newestFirst)
        )

        let picks = try await client.staffPicks()
        _ = (hearts, results, picks)
    }

    // README: Download a model and load it with VRMKit
    static func download(client: VRoidHubClient, model: VRoidCharacterModel) async throws {
        let downloaded = try await client.downloadModel(model)

        // Preferred: the decrypted bytes never touch the disk.
        let data = try await client.modelData(for: downloaded)
        _ = data // let vrm = try VRMLoader().load(withData: data)

        _ = try await client.withModelFile(downloaded) { url in
            url // try VRMLoader().load(withUrl: url)
        }
    }

    // README: Conditions of use
    static func conditionsOfUse(model: VRoidCharacterModel) {
        if let conditions = model.usageConditions {
            switch conditions.modification {
            case .allowed: break
            case .disallowed: break
            case .unspecified: break // the uploader has not set this condition
            case .unknown: break // never treat unknown values as permission
            }
        }
        _ = model.license
        _ = model.latestCharacterModelVersion?.vrmMeta
    }
}
