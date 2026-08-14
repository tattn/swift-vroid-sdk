public import Foundation

/// One page of a paginated API response.
///
/// `next` mirrors the API's `_links.next.href` and is the only signal for
/// whether more pages exist. Do not infer the end of pagination from
/// `items.count`; the API may return fewer items than requested even when
/// more pages follow.
public struct VRoidPage<Element: Sendable>: Sendable {
    public let items: [Element]
    public let next: URL?
}
