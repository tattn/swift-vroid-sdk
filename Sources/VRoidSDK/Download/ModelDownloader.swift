import Foundation

/// Downloads model files via the download license flow:
/// `GET /api/download_licenses/{id}/download` responds with a 302 redirect to
/// a presigned file URL, which must be fetched without the API auth headers.
struct ModelDownloader: Sendable {
    let api: AuthenticatedAPIClient
    let transport: any HTTPTransport

    func downloadModelFile(licenseID: String) async throws -> Data {
        let response = try await api.sendRaw(
            method: "GET",
            path: "/api/download_licenses/\(licenseID)/download",
            followRedirects: false
        )

        switch response.statusCode {
        case 300..<400:
            guard let location = response.headerValue("Location"),
                  let fileURL = URL(string: location)
            else {
                throw VRoidHubError.downloadFailed
            }
            return try await downloadFile(at: fileURL)
        default:
            // The endpoint is specified to respond with a redirect; anything
            // else (including 2xx) must not be treated as model data.
            try api.validate(response)
            throw VRoidHubError.downloadFailed
        }
    }

    private func downloadFile(at url: URL) async throws -> Data {
        // Plain request: no Authorization or X-Api-Version headers must ever
        // be sent to the presigned file URL host.
        let request = URLRequest(url: url)
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode), !response.body.isEmpty else {
            throw VRoidHubError.downloadFailed
        }
        return response.body
    }
}
