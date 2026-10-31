import Foundation
import UIKit
import SwiftSignalKit
import ZipArchive
import GGCore

/// A custom icon pack: a directory `<packs>/<id>/` with `metadata.json` and the icon files it
/// names. The keys of `icons` are Telegram-for-Android drawable names (exteraGram's `.icons`
/// format), so a pack made on Android installs unchanged; `GGIconPackMapTable` says which iOS
/// asset each of them replaces.
///
///     { "schemaVersion": 1, "packName": "…", "packId": "custom.<uuid>", "author": "…",
///       "version": "1.0", "icons": { "<android name>": "<file inside the pack>", … } }
struct GGIconPack: Equatable {
    let id: String
    var name: String
    var author: String
    var version: String
    var icons: [String: String]
    let directory: String

    func fileURL(androidName: String) -> URL? {
        guard let fileName = self.icons[androidName] else {
            return nil
        }
        return GGIconPackStorage.resolve(fileName: fileName, inside: self.directory)
    }

    /// Number of iOS assets the pack actually replaces.
    var coveredAssetCount: Int {
        var count = 0
        for (_, names) in GGIconPackMapTable.androidNamesByAsset {
            if names.contains(where: { self.icons[$0] != nil && !GGIconPackMapTable.blacklist.contains($0) }) {
                count += 1
            }
        }
        return count
    }
}

enum GGIconPackError: Error {
    case invalidArchive
    case missingMetadata
    case metadataTooLarge
    case tooManyFiles
    case fileTooLarge
    case tooLarge
    case suspiciousCompression
    case storage

    var text: String {
        switch self {
        case .invalidArchive:
            return GGStrings.Interface.IconPacks.errorInvalid
        case .missingMetadata:
            return GGStrings.Interface.IconPacks.errorMetadata
        case .metadataTooLarge:
            return GGStrings.Interface.IconPacks.errorMetadataTooLarge
        case .tooManyFiles:
            return GGStrings.Interface.IconPacks.errorTooManyFiles
        case .fileTooLarge:
            return GGStrings.Interface.IconPacks.errorFileTooLarge
        case .tooLarge:
            return GGStrings.Interface.IconPacks.errorTooLarge
        case .suspiciousCompression:
            return GGStrings.Interface.IconPacks.errorCompression
        case .storage:
            return GGStrings.Interface.IconPacks.errorStorage
        }
    }
}

/// Files of the packs. Every method that touches the disk runs on `ggInterfaceQueue`; the list
/// is published as a signal (no polling, no notifications).
final class GGIconPackStorage {
    static let shared = GGIconPackStorage()
    static let fileExtension = "icons"

    private static let metadataFileName = "metadata.json"
    private static let maxEntries = 3000
    private static let maxUnpackedBytes: UInt64 = 100 * 1024 * 1024
    private static let maxFileBytes: UInt64 = 10 * 1024 * 1024
    private static let maxCompressionRatio: Double = 250.0
    private static let maxMetadataBytes: Int64 = 256 * 1024

    private let packsPromise = Promise<[GGIconPack]>()
    private var didLoad = false

    private init() {
    }

    var directory: String? {
        return ggInterfaceDirectory("iconpacks")
    }

    /// Installed packs, sorted by name; first value after the first disk read.
    var packs: Signal<[GGIconPack], NoError> {
        self.loadIfNeeded()
        return self.packsPromise.get()
    }

    private func loadIfNeeded() {
        if self.didLoad {
            return
        }
        self.didLoad = true
        self.reload()
    }

    func reload() {
        let directory = self.directory
        self.packsPromise.set(Signal<[GGIconPack], NoError> { subscriber in
            subscriber.putNext(GGIconPackStorage.readPacks(directory: directory))
            subscriber.putCompletion()
            return EmptyDisposable
        } |> runOn(ggInterfaceQueue))
    }

    private static func readPacks(directory: String?) -> [GGIconPack] {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        var result: [GGIconPack] = []
        for name in names {
            let packDirectory = (directory as NSString).appendingPathComponent(name)
            if let pack = GGIconPackStorage.readMetadata(directory: packDirectory), pack.id == name {
                result.append(pack)
            }
        }
        return result.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    static func isValidPackId(_ id: String) -> Bool {
        guard id.hasPrefix("custom."), id.count <= 80 else {
            return false
        }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// A file name inside a pack, resolved without leaving the pack directory.
    static func resolve(fileName: String, inside directory: String, requireExists: Bool = true) -> URL? {
        if fileName.isEmpty || fileName.hasPrefix("/") || fileName.contains("..") {
            return nil
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(fileName).standardizedFileURL
        let base = URL(fileURLWithPath: directory).standardizedFileURL.path
        guard url.path.hasPrefix(base + "/") else {
            return nil
        }
        if requireExists && !FileManager.default.fileExists(atPath: url.path) {
            return nil
        }
        return url
    }

    static func readMetadata(directory: String) -> GGIconPack? {
        let path = (directory as NSString).appendingPathComponent(GGIconPackStorage.metadataFileName)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), Int64(data.count) <= GGIconPackStorage.maxMetadataBytes else {
            return nil
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        guard let name = object["packName"] as? String, let id = object["packId"] as? String, GGIconPackStorage.isValidPackId(id) else {
            return nil
        }
        var icons: [String: String] = [:]
        if let rawIcons = object["icons"] as? [String: Any] {
            for (key, value) in rawIcons {
                guard let fileName = value as? String, GGIconPackStorage.resolve(fileName: fileName, inside: directory, requireExists: false) != nil else {
                    continue
                }
                icons[key] = fileName
            }
        }
        return GGIconPack(id: id, name: String(name.prefix(64)), author: String(((object["author"] as? String) ?? "").prefix(64)), version: String(((object["version"] as? String) ?? "1.0").prefix(16)), icons: icons, directory: directory)
    }

    static func writeMetadata(_ pack: GGIconPack) -> Bool {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "packName": pack.name,
            "packId": pack.id,
            "author": pack.author,
            "version": pack.version,
            "icons": pack.icons
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: (pack.directory as NSString).appendingPathComponent(GGIconPackStorage.metadataFileName)), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: Changes (each finishes with `reload()`)

    func create(name: String, author: String) -> Signal<GGIconPack, GGIconPackError> {
        let directory = self.directory
        return Signal { subscriber in
            guard let directory else {
                subscriber.putError(.storage)
                return EmptyDisposable
            }
            let id = "custom." + UUID().uuidString.lowercased()
            let packDirectory = (directory as NSString).appendingPathComponent(id)
            do {
                try FileManager.default.createDirectory(atPath: packDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                subscriber.putError(.storage)
                return EmptyDisposable
            }
            let pack = GGIconPack(id: id, name: String(name.prefix(64)), author: String(author.prefix(64)), version: "1.0", icons: [:], directory: packDirectory)
            if !GGIconPackStorage.writeMetadata(pack) {
                subscriber.putError(.storage)
                return EmptyDisposable
            }
            subscriber.putNext(pack)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(ggInterfaceQueue)
        |> afterCompleted { [weak self] in
            self?.reload()
        }
    }

    func update(_ pack: GGIconPack) -> Signal<Never, GGIconPackError> {
        return Signal { subscriber in
            if GGIconPackStorage.writeMetadata(pack) {
                subscriber.putCompletion()
            } else {
                subscriber.putError(.storage)
            }
            return EmptyDisposable
        }
        |> runOn(ggInterfaceQueue)
        |> afterCompleted { [weak self] in
            self?.reload()
        }
    }

    /// Stores a PNG for an Android name in the pack (a new file name, so caches never serve
    /// the old picture) and points the metadata at it.
    func setIcon(_ image: UIImage, androidName: String, in pack: GGIconPack) -> Signal<GGIconPack, GGIconPackError> {
        return Signal { subscriber in
            guard let data = image.pngData() else {
                subscriber.putError(.storage)
                return EmptyDisposable
            }
            let fileName = "\(androidName)_\(Int(Date().timeIntervalSince1970 * 1000)).png"
            var updated = pack
            let previous = updated.icons[androidName]
            do {
                try data.write(to: URL(fileURLWithPath: (pack.directory as NSString).appendingPathComponent(fileName)), options: .atomic)
            } catch {
                subscriber.putError(.storage)
                return EmptyDisposable
            }
            updated.icons[androidName] = fileName
            if !GGIconPackStorage.writeMetadata(updated) {
                subscriber.putError(.storage)
                return EmptyDisposable
            }
            if let previous, let url = GGIconPackStorage.resolve(fileName: previous, inside: pack.directory) {
                try? FileManager.default.removeItem(at: url)
            }
            subscriber.putNext(updated)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(ggInterfaceQueue)
        |> afterCompleted { [weak self] in
            self?.reload()
        }
    }

    func resetIcon(androidName: String, in pack: GGIconPack) -> Signal<GGIconPack, GGIconPackError> {
        return Signal { subscriber in
            var updated = pack
            if let previous = updated.icons.removeValue(forKey: androidName), let url = GGIconPackStorage.resolve(fileName: previous, inside: pack.directory) {
                try? FileManager.default.removeItem(at: url)
            }
            if !GGIconPackStorage.writeMetadata(updated) {
                subscriber.putError(.storage)
                return EmptyDisposable
            }
            subscriber.putNext(updated)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(ggInterfaceQueue)
        |> afterCompleted { [weak self] in
            self?.reload()
        }
    }

    func delete(_ pack: GGIconPack) -> Signal<Never, NoError> {
        return Signal { subscriber in
            try? FileManager.default.removeItem(atPath: pack.directory)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(ggInterfaceQueue)
        |> afterCompleted { [weak self] in
            self?.reload()
        }
    }

    /// The pack zipped as `<name>.icons` in a temporary directory (for sharing).
    func export(_ pack: GGIconPack) -> Signal<URL, GGIconPackError> {
        return Signal { subscriber in
            let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gg-icons-" + UUID().uuidString)
            try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: nil)
            let safeName = pack.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "_")
            let destination = temporary.appendingPathComponent((safeName.isEmpty ? "Icons" : safeName) + "." + GGIconPackStorage.fileExtension)
            // A link left in a pack by an older build would pack the file it points to.
            GGSafeUnzip.removeSymbolicLinks(in: pack.directory)
            if SSZipArchive.createZipFile(atPath: destination.path, withContentsOfDirectory: pack.directory) {
                subscriber.putNext(destination)
                subscriber.putCompletion()
            } else {
                subscriber.putError(.storage)
            }
            return EmptyDisposable
        }
        |> runOn(ggInterfaceQueue)
    }

    /// Checks an `.icons` archive and unpacks it into a temporary directory. The returned pack
    /// lives there until `install` moves it (or the caller drops it).
    func inspect(archive url: URL) -> Signal<GGIconPack, GGIconPackError> {
        return Signal { subscriber in
            guard let entries = SSZipArchive.getEntriesForFile(atPath: url.path) else {
                subscriber.putError(.invalidArchive)
                return EmptyDisposable
            }
            if entries.count > GGIconPackStorage.maxEntries {
                subscriber.putError(.tooManyFiles)
                return EmptyDisposable
            }
            var total: UInt64 = 0
            for entry in entries {
                let size = UInt64(entry.uncompressedSize)
                if size > GGIconPackStorage.maxFileBytes {
                    subscriber.putError(.fileTooLarge)
                    return EmptyDisposable
                }
                total += size
            }
            if total > GGIconPackStorage.maxUnpackedBytes {
                subscriber.putError(.tooLarge)
                return EmptyDisposable
            }
            let archiveSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if archiveSize > 0 && Double(total) / Double(archiveSize) > GGIconPackStorage.maxCompressionRatio {
                subscriber.putError(.suspiciousCompression)
                return EmptyDisposable
            }
            let temporary = (NSTemporaryDirectory() as NSString).appendingPathComponent("gg-icons-" + UUID().uuidString)
            // Never through a symbolic link, never out of the directory (GGSafeUnzip).
            guard GGSafeUnzip.unzip(archive: url.path, to: temporary) else {
                subscriber.putError(.invalidArchive)
                return EmptyDisposable
            }
            // A pack zipped with its folder has the metadata one level down.
            var root = temporary
            if !FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(GGIconPackStorage.metadataFileName)), let items = try? FileManager.default.contentsOfDirectory(atPath: root), items.count == 1 {
                root = (root as NSString).appendingPathComponent(items[0])
            }
            let metadataPath = (root as NSString).appendingPathComponent(GGIconPackStorage.metadataFileName)
            guard FileManager.default.fileExists(atPath: metadataPath) else {
                try? FileManager.default.removeItem(atPath: temporary)
                subscriber.putError(.missingMetadata)
                return EmptyDisposable
            }
            let metadataSize = (try? FileManager.default.attributesOfItem(atPath: metadataPath)[.size] as? NSNumber)?.int64Value ?? 0
            if metadataSize > GGIconPackStorage.maxMetadataBytes {
                try? FileManager.default.removeItem(atPath: temporary)
                subscriber.putError(.metadataTooLarge)
                return EmptyDisposable
            }
            guard let pack = GGIconPackStorage.readMetadata(directory: root) else {
                try? FileManager.default.removeItem(atPath: temporary)
                subscriber.putError(.missingMetadata)
                return EmptyDisposable
            }
            subscriber.putNext(pack)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(ggInterfaceQueue)
    }

    /// Moves an inspected pack into the packs directory (replacing a pack with the same id).
    func install(_ inspected: GGIconPack) -> Signal<GGIconPack, GGIconPackError> {
        let directory = self.directory
        return Signal { subscriber in
            guard let directory else {
                subscriber.putError(.storage)
                return EmptyDisposable
            }
            let destination = (directory as NSString).appendingPathComponent(inspected.id)
            try? FileManager.default.removeItem(atPath: destination)
            do {
                try FileManager.default.moveItem(atPath: inspected.directory, toPath: destination)
            } catch {
                subscriber.putError(.storage)
                return EmptyDisposable
            }
            guard let pack = GGIconPackStorage.readMetadata(directory: destination) else {
                subscriber.putError(.missingMetadata)
                return EmptyDisposable
            }
            subscriber.putNext(pack)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(ggInterfaceQueue)
        |> afterCompleted { [weak self] in
            self?.reload()
        }
    }

    /// Packs of the old client (`Documents/GGIconPacks/<id>/`) are copied once into the new place.
    /// The old client accepted any id without a slash; one this client does not accept gets a
    /// stable `custom.…` id of its own (the metadata and the order of enabled packs follow). Each
    /// pack is copied aside and moved in whole; the old directory goes only when every pack is
    /// here, otherwise the next launch tries again (packs already here are skipped).
    func migrateLegacyPacksIfNeeded() {
        ggInterfaceQueue.async {
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return
            }
            // One failed directory listing per launch when there is nothing to bring over.
            let legacy = documents.appendingPathComponent("GGIconPacks").path
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: legacy), let directory = self.directory else {
                return
            }
            var isComplete = true
            var renamed: [String: String] = [:]
            for name in names {
                let source = (legacy as NSString).appendingPathComponent(name)
                switch GGIconPackStorage.migrateLegacyPack(from: source, into: directory) {
                case .notAPack:
                    break
                case let .moved(oldId, newId):
                    if oldId != newId {
                        renamed[oldId] = newId
                    }
                case .failed:
                    isComplete = false
                }
            }
            if isComplete {
                try? FileManager.default.removeItem(atPath: legacy)
            }
            Queue.mainQueue().async {
                if !renamed.isEmpty {
                    InterfaceSettings.iconPacks.set(InterfaceSettings.iconPacks.value.map { renamed[$0] ?? $0 })
                }
                self.reload()
                GGIconPackResolver.shared.apply()
            }
        }
    }

    private enum LegacyPackResult {
        case notAPack
        case moved(oldId: String, newId: String)
        case failed
    }

    /// The id the old client's pack gets here: its own when valid, otherwise `custom.` + the old id
    /// with every other character replaced by `_` (the same old id always maps to the same new one).
    static func migratedPackId(_ oldId: String) -> String {
        if GGIconPackStorage.isValidPackId(oldId) {
            return oldId
        }
        var body = ""
        for character in oldId {
            if character.isLetter || character.isNumber || character == "." || character == "-" || character == "_" {
                body.append(character)
            } else {
                body.append("_")
            }
        }
        if body.hasPrefix("custom.") {
            body = String(body.dropFirst("custom.".count))
        }
        if body.isEmpty {
            body = "pack"
        }
        return String(("custom." + body).prefix(80))
    }

    private static func migrateLegacyPack(from source: String, into directory: String) -> LegacyPackResult {
        let fileManager = FileManager.default
        let metadataPath = (source as NSString).appendingPathComponent(GGIconPackStorage.metadataFileName)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)) else {
            return .notAPack
        }
        if Int64(data.count) > GGIconPackStorage.maxMetadataBytes {
            // Too big for this client to take: keep the old copy rather than lose it.
            return .failed
        }
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["packName"] is String, let oldId = object["packId"] as? String, !oldId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !oldId.contains("/"), !oldId.contains("\\"), oldId != ".", oldId != "..", !oldId.hasPrefix("base.") else {
            // The old client did not load such a directory either.
            return .notAPack
        }
        let newId = GGIconPackStorage.migratedPackId(oldId)
        let destination = (directory as NSString).appendingPathComponent(newId)
        if fileManager.fileExists(atPath: destination) {
            return .moved(oldId: oldId, newId: newId)
        }
        // Copied aside under a name `loadPacks` never takes (it is not the pack's id), then moved.
        let staging = (directory as NSString).appendingPathComponent(".migrating-" + newId)
        try? fileManager.removeItem(atPath: staging)
        do {
            try fileManager.copyItem(atPath: source, toPath: staging)
            if newId != oldId {
                object["packId"] = newId
                let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                try updated.write(to: URL(fileURLWithPath: (staging as NSString).appendingPathComponent(GGIconPackStorage.metadataFileName)), options: .atomic)
            }
            guard GGIconPackStorage.readMetadata(directory: staging)?.id == newId else {
                try? fileManager.removeItem(atPath: staging)
                return .failed
            }
            try fileManager.moveItem(atPath: staging, toPath: destination)
            return .moved(oldId: oldId, newId: newId)
        } catch {
            try? fileManager.removeItem(atPath: staging)
            return .failed
        }
    }
}
