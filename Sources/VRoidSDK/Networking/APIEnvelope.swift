import Foundation

/// The response envelope shared by all VRoid Hub API endpoints.
struct APIEnvelope<Payload: Decodable>: Decodable {
    let data: Payload?
    let error: APIErrorPayload?
    let links: APILinks?

    enum CodingKeys: String, CodingKey {
        case data
        case error
        case links = "_links"
    }
}

struct APIErrorPayload: Decodable {
    let code: String?
    let message: String?
}

struct APILinks: Decodable {
    let next: APILink?
}

struct APILink: Decodable {
    let href: String
}

struct EmptyPayload: Decodable {}
