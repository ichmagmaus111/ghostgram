import Foundation
import UIKit
import CryptoKit
import SwiftSignalKit
import GGCore

/// An entry of the server's mask catalog (`catalog.json`). The format is the old one plus optional
/// integrity fields: `version` (a newer one replaces the cached copy) and SHA-256 of the manifest
/// and of every asset, checked after download.
struct GGMaskCatalogEntry: Codable, Equatable {
    let id: String
    let name: [String: String]
    let category: String?
    let thumbnail: String
    let manifest: String
    let version: Int?
    let manifestSha256: String?
    let assetsSha256: [String: String]?

    func displayName(languageCode: String) -> String {
        if let value = self.name[languageCode], !value.isEmpty {
            return value
        }
        if let value = self.name["en"], !value.isEmpty {
            return value
        }
        return self.name.values.first(where: { !$0.isEmpty }) ?? self.id
    }
}

private struct GGMaskCatalogFile: Codable {
    let schemaVersion: Int?
    let catalogVersion: Int?
    let masks: [GGMaskCatalogEntry]
}

/// The catalog of masks on Ghostgram's server and the cache of downloaded masks.
///
/// - Only `GGNetwork`: an ephemeral session, the user's SOCKS5 proxy, nothing about the user in the
///   request, nothing sent while an MTProxy / WEB proxy is on.
/// - The catalog is accepted only with a valid `X-GG-Signature` from `signingKeys`; manifests and
///   assets come only from the catalog's own host and are checked against the hashes it lists.
/// - Conditional GET (ETag), at most every 6 h, and only while masks are in use; the screens ask for
///   it, nothing polls.
/// - Everything lives in Caches (`ghostgram/masks/`), never in UserDefaults or Documents, with a
///   size limit (least recently used masks go first).
/// - A mask that failed to download is not retried until it is picked again.
final class GGMaskCatalog {
    static let shared = GGMaskCatalog()

    static let catalogURL = URL(string: "https://ghostpixel.win/masks/catalog.json")!
    /// P-256 public keys of the catalog signature (64-byte x‖y, X9.63 or DER). Provided by the
    /// owner of the server; while the list is empty the catalog is not fetched at all — unsigned
    /// data is never used (see the W3-2 report).
    static let signingKeys: [Data] = []

    static let refreshInterval: Double = 6.0 * 60.0 * 60.0
    static let minimumCacheLimitMB = 50

    private let queue = Queue(name: "org.ghostgram.masks.catalog")
    private let entriesPromise = ValuePromise<[GGMaskCatalogEntry]>([], ignoreRepeated: true)
    private var entriesValue: [GGMaskCatalogEntry] = []
    private var didLoadCache = false
    private var isRefreshing = false
    private let refreshDisposable = MetaDisposable()
    private var preparing: [String: [(GGPreparedMask?) -> Void]] = [:]
    private let preparationDisposables = DisposableSet()

    var root: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ghostgram/masks", isDirectory: true)
    }

    private var catalogFile: URL {
        return self.root.appendingPathComponent("catalog.json")
    }

    func directory(id: String) -> URL {
        return self.root.appendingPathComponent("remote", isDirectory: true).appendingPathComponent(GGMaskStore.safeComponent(id), isDirectory: true)
    }

    static var isAvailable: Bool {
        return !GGMaskCatalog.signingKeys.isEmpty
    }

    // MARK: Entries

    var entries: Signal<[GGMaskCatalogEntry], NoError> {
        self.queue.async {
            self.loadCacheIfNeeded()
        }
        return self.entriesPromise.get()
    }

    private let snapshotLock = NSLock()
    private var snapshot: [GGMaskCatalogEntry] = []

    /// Any thread: the last loaded catalog (empty until the first screen asked for it).
    func entry(id: String) -> GGMaskCatalogEntry? {
        self.snapshotLock.lock()
        defer {
            self.snapshotLock.unlock()
        }
        return self.snapshot.first(where: { $0.id == id })
    }

    private func setEntries(_ entries: [GGMaskCatalogEntry]) {
        self.entriesValue = entries
        self.snapshotLock.lock()
        self.snapshot = entries
        self.snapshotLock.unlock()
        self.entriesPromise.set(entries)
    }

    private func loadCacheIfNeeded() {
        if self.didLoadCache {
            return
        }
        self.didLoadCache = true
        if let data = try? Data(contentsOf: self.catalogFile), let file = try? JSONDecoder().decode(GGMaskCatalogFile.self, from: data) {
            self.setEntries(file.masks)
        }
    }

    /// Fetches the catalog when it is older than 6 h (or `force`). Masks must be in use.
    func refreshIfNeeded(force: Bool = false) {
        guard GGMaskCatalog.isAvailable else {
            GGLog.info("masks", "catalog: no signing key configured, not fetched")
            return
        }
        let fetchedAt = GGMaskSettings.catalogFetchedAt.value
        let now = Date().timeIntervalSince1970
        if !force && now - fetchedAt < GGMaskCatalog.refreshInterval {
            return
        }
        self.queue.async { [self] in
            self.loadCacheIfNeeded()
            if self.isRefreshing {
                return
            }
            self.isRefreshing = true
            let etag = GGMaskSettings.catalogETag.value
            let request = GGNetworkRequest(url: GGMaskCatalog.catalogURL, etag: etag.isEmpty || self.entriesValue.isEmpty ? nil : etag, signingKeys: GGMaskCatalog.signingKeys, maxBytes: 2 * 1024 * 1024)
            self.refreshDisposable.set((GGNetwork.shared.fetch(request) |> deliverOn(self.queue)).start(next: { [weak self] response in
                guard let self else {
                    return
                }
                self.isRefreshing = false
                GGMaskSettings.catalogFetchedAt.set(Date().timeIntervalSince1970)
                if response.notModified {
                    return
                }
                guard let data = response.data, let file = try? JSONDecoder().decode(GGMaskCatalogFile.self, from: data) else {
                    GGLog.warning("masks", "catalog: unreadable response kept the previous catalog")
                    return
                }
                try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
                try? data.write(to: self.catalogFile, options: [.atomic])
                GGMaskSettings.catalogETag.set(response.etag ?? "")
                self.setEntries(file.masks)
            }, error: { [weak self] error in
                guard let self else {
                    return
                }
                self.queue.async {
                    self.isRefreshing = false
                }
                GGLog.info("masks", "catalog fetch failed: \(error)")
            }))
        }
    }

    // MARK: Masks

    /// A catalog mask ready to render: from the cache, else downloaded (manifest, then assets).
    /// Called when the mask is picked, never per frame.
    func prepare(id: String, completion: @escaping (GGPreparedMask?) -> Void) {
        self.queue.async { [self] in
            self.loadCacheIfNeeded()
            if var waiting = self.preparing[id] {
                waiting.append(completion)
                self.preparing[id] = waiting
                return
            }
            let entry = self.entriesValue.first(where: { $0.id == id })
            let directory = self.directory(id: id)
            if let cached = self.cachedMask(id: id, entry: entry, directory: directory) {
                self.touch(directory)
                completion(cached)
                return
            }
            guard let entry, GGMaskCatalog.isAvailable, let manifestUrl = self.trustedURL(entry.manifest) else {
                completion(nil)
                return
            }
            self.preparing[id] = [completion]
            self.preparationDisposables.add((GGNetwork.shared.fetch(GGNetworkRequest(url: manifestUrl, maxBytes: 1024 * 1024)) |> deliverOn(self.queue)).start(next: { [weak self] response in
                guard let self else {
                    return
                }
                guard let data = response.data, GGMaskCatalog.matches(data, sha256: entry.manifestSha256), let manifest = try? JSONDecoder().decode(GGMaskManifest.self, from: data) else {
                    self.finishPreparation(id: id, result: nil)
                    return
                }
                self.downloadAssets(entry: entry, manifest: manifest, manifestData: data, baseUrl: manifestUrl.deletingLastPathComponent(), directory: directory)
            }, error: { [weak self] _ in
                self?.finishPreparation(id: id, result: nil)
            }))
        }
    }

    private func cachedMask(id: String, entry: GGMaskCatalogEntry?, directory: URL) -> GGPreparedMask? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")), let manifest = try? JSONDecoder().decode(GGMaskManifest.self, from: data) else {
            return nil
        }
        // A newer version in the catalog replaces the cached copy.
        if let version = entry?.version {
            let cachedVersion = (try? String(contentsOf: directory.appendingPathComponent("version"), encoding: .utf8)).flatMap { Int($0) } ?? 0
            if cachedVersion < version {
                return nil
            }
        }
        return GGPreparedMask(selection: .catalog(id), manifest: manifest, assets: GGMaskAssets(directory: directory.appendingPathComponent("assets", isDirectory: true)))
    }

    private func downloadAssets(entry: GGMaskCatalogEntry, manifest: GGMaskManifest, manifestData: Data, baseUrl: URL, directory: URL) {
        let names = Array(manifest.referencedAssets)
        var downloaded: [String: Data] = [:]
        func next(_ index: Int) {
            if index >= names.count {
                let fileManager = FileManager.default
                try? fileManager.removeItem(at: directory)
                let assets = directory.appendingPathComponent("assets", isDirectory: true)
                try? fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
                for (name, data) in downloaded {
                    try? data.write(to: assets.appendingPathComponent(GGMaskStore.safeComponent(name)), options: [.atomic])
                }
                try? manifestData.write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic])
                try? String(entry.version ?? 0).write(to: directory.appendingPathComponent("version"), atomically: true, encoding: .utf8)
                self.enforceLimit()
                self.finishPreparation(id: entry.id, result: GGPreparedMask(selection: .catalog(entry.id), manifest: manifest, assets: GGMaskAssets(directory: assets)))
                return
            }
            let name = names[index]
            guard let url = self.trustedURL(baseUrl.appendingPathComponent("assets").appendingPathComponent(GGMaskStore.safeComponent(name)).absoluteString) else {
                self.finishPreparation(id: entry.id, result: nil)
                return
            }
            self.preparationDisposables.add((GGNetwork.shared.fetch(GGNetworkRequest(url: url, maxBytes: 8 * 1024 * 1024)) |> deliverOn(self.queue)).start(next: { [weak self] response in
                guard let self else {
                    return
                }
                guard let data = response.data, GGMaskCatalog.matches(data, sha256: entry.assetsSha256?[name]) else {
                    self.finishPreparation(id: entry.id, result: nil)
                    return
                }
                downloaded[name] = data
                next(index + 1)
            }, error: { [weak self] _ in
                self?.finishPreparation(id: entry.id, result: nil)
            }))
        }
        next(0)
    }

    private func finishPreparation(id: String, result: GGPreparedMask?) {
        let completions = self.preparing.removeValue(forKey: id) ?? []
        for completion in completions {
            completion(result)
        }
    }

    /// Only https URLs on the catalog's own host.
    private func trustedURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https", url.host?.lowercased() == GGMaskCatalog.catalogURL.host?.lowercased() else {
            return nil
        }
        return url
    }

    private static func matches(_ data: Data, sha256: String?) -> Bool {
        guard let sha256, !sha256.isEmpty else {
            return true
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == sha256.lowercased()
    }

    // MARK: Thumbnails

    func thumbnail(entry: GGMaskCatalogEntry) -> Signal<UIImage?, NoError> {
        let file = self.directory(id: entry.id).appendingPathComponent("thumbnail")
        return Signal { subscriber in
            if let image = UIImage(contentsOfFile: file.path) {
                subscriber.putNext(image)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            guard GGMaskCatalog.isAvailable, let url = self.trustedURL(entry.thumbnail) else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            return (GGNetwork.shared.fetch(GGNetworkRequest(url: url, maxBytes: 512 * 1024)) |> deliverOn(self.queue)).start(next: { response in
                var image: UIImage?
                if let data = response.data, let decoded = UIImage(data: data) {
                    image = GGMaskStore.downscaled(decoded, maxSide: 160.0)
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let jpeg = image?.jpegData(compressionQuality: 0.8) {
                        try? jpeg.write(to: file, options: [.atomic])
                    }
                }
                subscriber.putNext(image)
                subscriber.putCompletion()
            }, error: { _ in
                subscriber.putNext(nil)
                subscriber.putCompletion()
            })
        }
    }

    // MARK: Cache

    private func touch(_ directory: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
    }

    /// Least recently used masks go first until the cache fits the limit.
    private func enforceLimit() {
        let limit = Int64(max(GGMaskCatalog.minimumCacheLimitMB, Int(GGMaskSettings.cacheLimit.value) ?? 200)) * 1024 * 1024
        let remote = self.root.appendingPathComponent("remote", isDirectory: true)
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(at: remote, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }
        var items = urls.map { url -> (URL, Date, Int64) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date(timeIntervalSince1970: 0.0)
            return (url, date, GGMaskStore.directorySize(url))
        }
        var total = items.reduce(Int64(0)) { $0 + $1.2 }
        items.sort(by: { $0.1 < $1.1 })
        for item in items where total > limit {
            try? fileManager.removeItem(at: item.0)
            total -= item.2
        }
    }

    func cacheSize(completion: @escaping (Int64) -> Void) {
        self.queue.async {
            let size = GGMaskStore.directorySize(self.root.appendingPathComponent("remote", isDirectory: true))
            DispatchQueue.main.async {
                completion(size)
            }
        }
    }

    func clearCache(completion: (() -> Void)? = nil) {
        self.queue.async {
            try? FileManager.default.removeItem(at: self.root.appendingPathComponent("remote", isDirectory: true))
            if let completion {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }
}
