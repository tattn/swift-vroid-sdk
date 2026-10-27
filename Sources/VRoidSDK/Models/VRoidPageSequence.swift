import Foundation
public import VRoidSDKCore

/// Lazily iterates the items of a paginated listing, fetching the next page
/// by following `_links.next` whenever the current one is exhausted.
///
/// ```swift
/// for try await model in client.allCharacterModels() {
///     print(model.id)
/// }
/// ```
public struct VRoidPageSequence<Item: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Item

    let firstPage: @Sendable () async throws -> VRoidPage<Item>
    let nextPage: @Sendable (URL) async throws -> VRoidPage<Item>

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(firstPage: firstPage, nextPage: nextPage)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let nextPage: @Sendable (URL) async throws -> VRoidPage<Item>
        private var buffer: [Item] = []
        /// The pending fetch: the first page initially, then the next-page
        /// fetch derived from each response, `nil` once exhausted.
        private var fetchNext: (@Sendable () async throws -> VRoidPage<Item>)?

        init(
            firstPage: @escaping @Sendable () async throws -> VRoidPage<Item>,
            nextPage: @escaping @Sendable (URL) async throws -> VRoidPage<Item>
        ) {
            self.nextPage = nextPage
            self.fetchNext = firstPage
        }

        public mutating func next() async throws -> Item? {
            while buffer.isEmpty {
                guard let fetch = fetchNext else { return nil }
                let page = try await fetch()
                buffer = page.items
                if let nextURL = page.next {
                    let nextPage = nextPage
                    fetchNext = { try await nextPage(nextURL) }
                } else {
                    fetchNext = nil
                }
            }
            return buffer.removeFirst()
        }
    }
}
