import Foundation

enum AppIdentity {
    /// Distinguishes host apps in per-user locations that unsandboxed apps
    /// share (the caches directory and legacy keychain items), so that two
    /// apps embedding the SDK never interfere with each other.
    static let identifier = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
}
