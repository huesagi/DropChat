import Foundation

/// A plain mutex usable from synchronous code inside async functions.
/// (`NSLock.lock()` is marked unavailable from async contexts.)
public final class SyncLock: @unchecked Sendable {
    private let base = NSLock()

    public init() {}

    public func lock() { base.lock() }
    public func unlock() { base.unlock() }

    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        base.lock()
        defer { base.unlock() }
        return try body()
    }
}
