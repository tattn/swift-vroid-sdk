import Foundation

/// Abstraction over the current time so that token expiration and cache
/// bookkeeping can be tested deterministically.
protocol DateProviding: Sendable {
    var now: Date { get }
}

struct SystemDateProvider: DateProviding {
    var now: Date { Date() }
}
