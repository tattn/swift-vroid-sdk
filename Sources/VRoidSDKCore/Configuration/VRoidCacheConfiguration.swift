/// Settings for the encrypted persistent model cache.
public struct VRoidCacheConfiguration: Sendable {
    /// Maximum number of models kept in the cache. Least recently used models
    /// are evicted first.
    ///
    /// Must be at least 1: downloaded models are read from the cache, so it
    /// cannot be disabled — a freshly downloaded model would evict itself.
    public var maximumModelCount: Int

    /// Optional cap on the total encrypted bytes kept in the cache; `nil`
    /// applies no byte limit. Least recently used models are evicted first.
    /// The most recently stored model is never evicted, so a single model
    /// larger than the cap can exceed it.
    public var maximumTotalBytes: Int?

    public init(maximumModelCount: Int = 10, maximumTotalBytes: Int? = nil) {
        precondition(maximumModelCount >= 1, "maximumModelCount must be at least 1")
        if let maximumTotalBytes {
            precondition(maximumTotalBytes >= 1, "maximumTotalBytes must be at least 1")
        }
        self.maximumModelCount = maximumModelCount
        self.maximumTotalBytes = maximumTotalBytes
    }
}
