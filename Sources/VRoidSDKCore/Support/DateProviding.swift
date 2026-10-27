#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

/// Abstraction over the current time so that token expiration and cache
/// bookkeeping can be tested deterministically.
package protocol DateProviding: Sendable {
    var now: Date { get }
}

package struct SystemDateProvider: DateProviding {
    package init() {}

    package var now: Date { Date() }
}
