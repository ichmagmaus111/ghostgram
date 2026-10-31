import Foundation
import os

/// A lock for short critical sections that are almost never contended. The lock word lives in its
/// own allocation, so its address never moves (an inline `os_unfair_lock` in a Swift class may).
final class GGUnfairLock {
    private let storage: UnsafeMutablePointer<os_unfair_lock>

    init() {
        self.storage = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.storage.initialize(to: os_unfair_lock())
    }

    deinit {
        self.storage.deinitialize(count: 1)
        self.storage.deallocate()
    }

    @inline(__always)
    func lock() {
        os_unfair_lock_lock(self.storage)
    }

    @inline(__always)
    func unlock() {
        os_unfair_lock_unlock(self.storage)
    }

    @inline(__always)
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        os_unfair_lock_lock(self.storage)
        defer {
            os_unfair_lock_unlock(self.storage)
        }
        return try body()
    }
}

/// Lets a subscriber through only with versions newer than the last one it saw. A value read at
/// subscription time can then never be delivered after a newer one that raced it.
final class GGVersionGate {
    private let lock = GGUnfairLock()
    private var lastVersion: UInt64?

    func pass(_ version: UInt64) -> Bool {
        return self.lock.withLock {
            if let lastVersion = self.lastVersion, version <= lastVersion {
                return false
            }
            self.lastVersion = version
            return true
        }
    }
}
