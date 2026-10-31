import Foundation
import SwiftSignalKit
import GGCore

// Subscriptions and their servers. Too large and too structured for a settings value, so they live
// in one versioned file of their own (`<appGroup>/ghostgram/vless/subscriptions.json`), not in
// UserDefaults. Reads come from an in-memory snapshot; writes replace the snapshot at once and the
// file on the store's queue, atomically. One unreadable subscription is dropped, never the list.

public final class GGVlessStore {
    public static let shared = GGVlessStore()

    private struct FileFormat: Codable {
        var version: Int
        var subscriptions: [GGVlessLossy<GGVlessSubscription>]
    }

    private let queue = DispatchQueue(label: "org.ghostgram.vless.store", qos: .utility)
    private var lock = os_unfair_lock()
    private var snapshot: [GGVlessSubscription] = []
    private let loadLock = NSLock()
    /// Guarded by `loadLock`.
    private var loaded = false
    private let promise = ValuePromise<[GGVlessSubscription]>([], ignoreRepeated: true)

    private init() {
    }

    private var fileURL: URL? {
        guard let appGroupPath = GGCore.environment?.appGroupPath else {
            return nil
        }
        return URL(fileURLWithPath: appGroupPath).appendingPathComponent("ghostgram/vless/subscriptions.json")
    }

    /// Loads the file once, off the main thread (the controller's queue at launch). Getters never
    /// touch the disk: before the load they return an empty list and the signal emits after it.
    public func loadIfNeeded() {
        // Concurrent callers wait for the one load: an early edit must see the file's contents.
        self.loadLock.lock()
        defer {
            self.loadLock.unlock()
        }
        if self.loaded {
            return
        }
        var subscriptions: [GGVlessSubscription] = []
        if let url = self.fileURL, let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(FileFormat.self, from: data), file.version == 1 {
            subscriptions = file.subscriptions.compactMap { $0.value }
        }
        os_unfair_lock_lock(&self.lock)
        self.snapshot = subscriptions
        os_unfair_lock_unlock(&self.lock)
        self.loaded = true
        self.promise.set(subscriptions)
    }

    public var subscriptions: [GGVlessSubscription] {
        os_unfair_lock_lock(&self.lock)
        let value = self.snapshot
        os_unfair_lock_unlock(&self.lock)
        return value
    }

    public var subscriptionsSignal: Signal<[GGVlessSubscription], NoError> {
        return self.promise.get()
    }

    public func server(id: String) -> (GGVlessSubscription, GGVlessServer)? {
        for subscription in self.subscriptions {
            if let server = subscription.servers.first(where: { $0.id == id }) {
                return (subscription, server)
            }
        }
        return nil
    }

    /// Applies `f` to the list and persists the result. Loads first if the launch load has not run
    /// yet, so an early edit never overwrites the file with an empty list.
    public func update(_ f: (inout [GGVlessSubscription]) -> Void) {
        self.loadIfNeeded()
        os_unfair_lock_lock(&self.lock)
        var value = self.snapshot
        f(&value)
        let changed = value != self.snapshot
        self.snapshot = value
        os_unfair_lock_unlock(&self.lock)
        if !changed {
            return
        }
        self.promise.set(value)
        guard let url = self.fileURL else {
            return
        }
        self.queue.async {
            let file = FileFormat(version: 1, subscriptions: value.map { GGVlessLossy(value: $0) })
            guard let data = try? JSONEncoder().encode(file) else {
                return
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                GGLog.warning("vless", "subscriptions file was not written")
            }
        }
    }
}

/// Decodes to nil instead of failing the enclosing array.
struct GGVlessLossy<T: Codable>: Codable {
    let value: T?

    init(value: T?) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try? container.decode(T.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }
}
