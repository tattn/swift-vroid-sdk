# swift-vroid-sdk

A native Swift SDK for the [VRoid Hub API](https://developer.vroid.com/api/).

> [!IMPORTANT]
> This is an **unofficial** SDK. It is not affiliated with or endorsed by pixiv Inc.
> "VRoid" is a trademark of pixiv Inc.

## Features

- Sign in with a VRoid Hub account, with session restore across launches
- Native sign-in on both platforms: `ASWebAuthenticationSession` on iOS, the user's default browser on macOS
- Fetch the account, its character models, hearted models, staff picks, and keyword search — with pagination, including lazy `for try await` iteration
- Download model files, managing download licenses for you
- Encrypted local cache: repeated loads don't re-download, and an updated model is never served stale
- Conditions of use for both VRM 0.x and VRM 1.0 models, normalized into one structure ready to display

Parsing and rendering VRM files is out of scope. Pair this SDK with a VRM
library such as [VRMKit](https://github.com/tattn/VRMKit); the two are
intentionally independent and connect through plain `Data`/`URL` values.

## Requirements

- iOS 18+ / macOS 15+
- Swift 6.3+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/tattn/swift-vroid-sdk.git", from: "0.1.0"),
]
```

## Setup

Register an application on the [VRoid Hub developer page](https://hub.vroid.com/oauth/applications)
and configure a redirect URI:

- **iOS**: a custom URL scheme, e.g. `myapp://oauth/vroid`
- **macOS**: a loopback URI, e.g. `http://127.0.0.1`

```swift
import VRoidSDK

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

let client = VRoidHubClient(configuration: configuration)
```

Alternatively, load the `credential.json.bytes` file offered on the
application management page. Its registered redirect URI decides the callback:
a loopback URI starts the local callback server, a custom URL scheme is
intercepted by `ASWebAuthenticationSession`.

```swift
let url = Bundle.main.url(forResource: "credential.json", withExtension: "bytes")!
let client = VRoidHubClient(configuration: try VRoidHubConfiguration(credentialFileAt: url))
```

> [!NOTE]
> A client secret embedded in a distributed app cannot be kept truly secret.
> This mirrors the official Unity SDK's distribution model. If your app needs
> real secrecy, exchange the authorization code on your own backend instead.

## Usage

### Sign in

```swift
// Restore a previous session, or run the OAuth flow.
let account: VRoidAccount
if let restored = try await client.restoreSession() {
    account = restored
} else {
    account = try await client.signIn()
}
print(account.user.name ?? "")
```

### List character models

```swift
var page = try await client.characterModels()
for model in page.items {
    print(model.name ?? model.id)
}

// `page.next` is the only end-of-pagination signal.
if let next = page.next {
    page = try await client.characterModels(pageAt: next)
}

// Or iterate all pages lazily.
for try await model in client.allCharacterModels() {
    print(model.id)
}
```

Hearted models, staff picks, and keyword search work the same way. Hearts and
search accept usage-condition filters:

```swift
let hearts = try await client.hearts(
    options: VRoidHeartsOptions(filters: VRoidCharacterModelFilters(isDownloadable: true))
)

let results = try await client.searchCharacterModels(
    options: VRoidCharacterModelSearchOptions(keyword: "cat", sort: .newestFirst)
)

let picks = try await client.staffPicks()
```

One exception: staff picks pages have their own shape, so follow their `next`
URLs with `staffPicks(pageAt:)` instead of `characterModels(pageAt:)`
(`allStaffPicks()` handles this for you).

### Download a model and load it with VRMKit

```swift
import VRMKit

let downloaded = try await client.downloadModel(model)

// Preferred: the decrypted bytes never touch the disk.
let data = try await client.modelData(for: downloaded)
let vrm = try VRMLoader().load(withData: data)
```

For loaders that require a file URL, use the scoped variant. The temporary
plaintext file is deleted when the closure returns:

```swift
let vrm = try await client.withModelFile(downloaded) { url in
    try VRMLoader().load(withUrl: url)
}
```

Downloaded files are cached encrypted and keyed by model **and version**, so
repeated downloads reuse the cache while the download license is valid, and an
updated model is never served from a stale cache.

### Conditions of use

VRoid Hub requires integrating apps to present each model's conditions of use.
`usageConditions` normalizes VRM 0.x (`license`) and VRM 1.0 (`vrm_meta`)
models into one structure:

```swift
if let conditions = model.usageConditions {
    switch conditions.modification {
    case .allowed: ...
    case .disallowed: ...
    case .unspecified: ... // the uploader has not set this condition
    case .unknown(let raw): ... // never treat unknown values as permission
    }
}
```

The raw API values remain available via `model.license` and
`model.latestCharacterModelVersion?.vrmMeta`. Wording shown to users is your
app's responsibility; official approval requires labels matching VRoid Hub's.

## App approval

Unapproved applications are rate limited, show a warning to users, and can
only load models the signed-in user uploaded or is permitted to download.
See the [official documentation](https://developer.vroid.com/api/) for the
approval process.

## License

swift-vroid-sdk is released under the MIT license. See [LICENSE](LICENSE).
