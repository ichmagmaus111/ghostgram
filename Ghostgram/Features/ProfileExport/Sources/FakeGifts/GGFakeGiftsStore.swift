import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import GGCore

// Fake gifts: local copies of any gift, shown only on the user's own profile and only on this
// device. Nothing goes to the server.
//
// Storage is per account: `<account>/ghostgram/fake-gifts.json` (versioned Codable), next to the
// account's own data, so it leaves with the account. The file is read on this class's queue, and
// only while the feature is on. What the profile shows is kept in memory already resolved (sender
// peers looked up once per change), so a gift list push only concatenates.

enum GGFakeGiftsSettings {
    static let isEnabled = GGSetting<Bool>("fakeGifts.isEnabled", default: false)
    /// Fake gifts moved from the old client, waiting for the store to merge them into the account's
    /// file (a migration only writes settings). Service state, never exported.
    static let legacyImport = GGAccountSetting<Data>("fakeGifts.legacyImport", default: Data(), flags: [.noExport])

    static func declare() {
        let _ = GGFakeGiftsSettings.isEnabled
        let _ = GGFakeGiftsSettings.legacyImport
    }
}

/// One fake gift as stored. The gift itself is kept as it was copied; what the profile shows
/// (owner = you, the original-info line of a collectible) is derived when it is resolved.
struct GGFakeGiftRecord: Codable, Equatable {
    var localId: Int64
    var gift: StarGift
    var fromPeer: GGPeerKey?
    var nameHidden: Bool
    var date: Int32
    var text: String?
    var entities: [MessageTextEntity]?
    var savedToProfile: Bool
    var pinnedToTop: Bool
    var number: Int32?
    /// When the gift's media was last refreshed from the server (file references expire).
    var refreshedAt: Int32
}

private struct GGFakeGiftsFile: Codable {
    var version: Int
    var nextLocalId: Int64
    var items: [GGFakeGiftRecord]
}

final class GGFakeGiftsStore {
    static let shared = GGFakeGiftsStore()

    private static let refreshInterval: Int32 = 24 * 60 * 60

    private final class AccountEntry {
        let id: AccountRecordId
        let peerId: PeerId
        let fileURL: URL
        weak var postbox: Postbox?
        var records: [GGFakeGiftRecord]?
        var nextLocalId: Int64 = -1
        var refreshStarted = false
        let resolveDisposable = MetaDisposable()

        init(id: AccountRecordId, peerId: PeerId, basePath: String, postbox: Postbox) {
            self.id = id
            self.peerId = peerId
            self.fileURL = URL(fileURLWithPath: basePath).appendingPathComponent("ghostgram", isDirectory: true).appendingPathComponent("fake-gifts.json")
            self.postbox = postbox
        }
    }

    private let queue = Queue(name: "org.ghostgram.fakeGifts", qos: .utility)
    /// Queue only.
    private var entries: [PeerId: AccountEntry] = [:]

    private let lock = GGProfileExportLock()
    /// What the profile shows, per account peer. Read on the main thread on every gift list push.
    private var resolved: [PeerId: [ProfileGiftsContext.State.StarGift]] = [:]
    private var recordSnapshots: [PeerId: [GGFakeGiftRecord]] = [:]

    private let changesPipe = ValuePipe<PeerId>()

    private init() {
    }

    // MARK: - Reading (any thread)

    func resolvedGifts(accountPeerId: PeerId) -> [ProfileGiftsContext.State.StarGift] {
        return self.lock.withLock {
            return self.resolved[accountPeerId] ?? []
        }
    }

    func records(accountPeerId: PeerId) -> [GGFakeGiftRecord] {
        return self.lock.withLock {
            return self.recordSnapshots[accountPeerId] ?? []
        }
    }

    /// Current records first, then every change of this account's list.
    func recordsSignal(accountPeerId: PeerId) -> Signal<[GGFakeGiftRecord], NoError> {
        return .single(self.records(accountPeerId: accountPeerId))
        |> then(self.changesPipe.signal()
        |> filter { $0 == accountPeerId }
        |> map { [weak self] _ -> [GGFakeGiftRecord] in
            return self?.records(accountPeerId: accountPeerId) ?? []
        })
    }

    /// The local id when `reference` points at one of this account's fake gifts.
    static func localId(of reference: StarGiftReference?, accountPeerId: PeerId) -> Int64? {
        guard let reference = reference, case let .peer(peerId, id) = reference, peerId == accountPeerId, id < 0 else {
            return nil
        }
        return id
    }

    // MARK: - Accounts

    /// `GGAccountHooks.accountWillStart` (the thread that creates the account).
    func accountWillStart(_ start: GGAccountStartContext) {
        if start.isSupplementary || GGCore.environment?.process.isApp != true {
            return
        }
        let entry = AccountEntry(id: start.id, peerId: start.peerId, basePath: start.basePath, postbox: start.postbox)
        self.queue.async {
            self.entries[start.peerId] = entry
            if GGFakeGiftsSettings.isEnabled.value {
                self.load(entry)
            }
        }
    }

    func accountWillBeRemoved(_ id: AccountRecordId) {
        self.queue.async {
            guard let (peerId, entry) = self.entries.first(where: { $0.value.id == id }) else {
                return
            }
            entry.resolveDisposable.dispose()
            self.entries.removeValue(forKey: peerId)
            self.lock.withLock {
                self.resolved.removeValue(forKey: peerId)
                self.recordSnapshots.removeValue(forKey: peerId)
            }
        }
    }

    /// The feature was turned on or off. Off: nothing is read or kept in memory (the files stay —
    /// "Delete all" deletes them).
    func setEnabled(_ enabled: Bool) {
        self.queue.async {
            for (_, entry) in self.entries {
                if enabled {
                    self.load(entry)
                } else {
                    entry.resolveDisposable.set(nil)
                    entry.records = nil
                }
            }
            if !enabled {
                let peerIds = Array(self.entries.keys)
                self.lock.withLock {
                    self.resolved.removeAll()
                    self.recordSnapshots.removeAll()
                }
                for peerId in peerIds {
                    self.changesPipe.putNext(peerId)
                }
                Queue.mainQueue().async {
                    GGFakeGiftsPendingPoints.storeDidChange()
                }
            }
        }
    }

    // MARK: - Changes

    /// Adds a copy of a gift to the account's profile. `completion` on the main thread.
    func add(accountPeerId: PeerId, gift: StarGift, fromPeer: PeerId?, nameHidden: Bool, date: Int32, text: String?, entities: [MessageTextEntity]?, number: Int32?, completion: @escaping (Int64?) -> Void) {
        self.queue.async {
            guard let entry = self.entries[accountPeerId] else {
                Queue.mainQueue().async {
                    completion(nil)
                }
                return
            }
            if entry.records == nil {
                self.readFile(entry)
            }
            var records = entry.records ?? []
            let localId = entry.nextLocalId
            entry.nextLocalId = min(localId - 1, -1)
            let record = GGFakeGiftRecord(localId: localId, gift: gift, fromPeer: fromPeer?.ggKey, nameHidden: nameHidden, date: date, text: text, entities: entities, savedToProfile: true, pinnedToTop: false, number: number, refreshedAt: Int32(Date().timeIntervalSince1970))
            records.insert(record, at: 0)
            self.commit(entry, records: records)
            Queue.mainQueue().async {
                completion(localId)
            }
        }
    }

    /// Hide / pin from the profile: the shown list changes at once (the profile pushes
    /// its state right after the action), the file follows on the queue.
    func updateFlags(accountPeerId: PeerId, localId: Int64, savedToProfile: Bool?, pinnedToTop: Bool?) {
        self.lock.withLock {
            if var gifts = self.resolved[accountPeerId], let index = gifts.firstIndex(where: { GGFakeGiftsStore.localId(of: $0.reference, accountPeerId: accountPeerId) == localId }) {
                var gift = gifts[index]
                if let savedToProfile = savedToProfile {
                    gift = gift.withSavedToProfile(savedToProfile)
                }
                if let pinnedToTop = pinnedToTop {
                    gift = gift.withPinnedToTop(pinnedToTop)
                }
                gifts[index] = gift
                self.resolved[accountPeerId] = gifts
            }
        }
        self.update(accountPeerId: accountPeerId, localId: localId, { record in
            if let savedToProfile = savedToProfile {
                record.savedToProfile = savedToProfile
            }
            if let pinnedToTop = pinnedToTop {
                record.pinnedToTop = pinnedToTop
            }
        })
    }

    func update(accountPeerId: PeerId, localId: Int64, _ transform: @escaping (inout GGFakeGiftRecord) -> Void) {
        self.queue.async {
            guard let entry = self.entries[accountPeerId], var records = entry.records, let index = records.firstIndex(where: { $0.localId == localId }) else {
                return
            }
            transform(&records[index])
            records[index].localId = localId
            self.commit(entry, records: records)
        }
    }

    func remove(accountPeerId: PeerId, localId: Int64) {
        self.queue.async {
            guard let entry = self.entries[accountPeerId], var records = entry.records else {
                return
            }
            records.removeAll(where: { $0.localId == localId })
            self.commit(entry, records: records)
        }
    }

    /// Deletes the account's fake gifts and their file.
    func removeAll(accountPeerId: PeerId) {
        self.queue.async {
            guard let entry = self.entries[accountPeerId] else {
                return
            }
            entry.records = []
            try? FileManager.default.removeItem(at: entry.fileURL)
            self.publish(entry, records: [], gifts: [])
        }
    }

    // MARK: - Media refresh

    /// File references in a stored gift expire. Once per session per account (while the own
    /// profile's gifts are shown), plain gifts older than a day get fresh media from the gift catalog
    /// cached on the device. Nothing is asked from the server: «nothing is sent» is the feature's
    /// promise, and a request by slug told the server which collectibles the user hangs on himself.
    /// A collectible keeps the media it was copied with (already downloaded files stay in the cache).
    func refreshIfNeeded(account: Account) {
        let accountPeerId = account.peerId
        self.queue.async { [self] in
            guard let entry = self.entries[accountPeerId], !entry.refreshStarted, let records = entry.records, !records.isEmpty else {
                return
            }
            entry.refreshStarted = true
            let now = Int32(Date().timeIntervalSince1970)
            let hasStaleGeneric = records.contains { record in
                if case .generic = record.gift {
                    return now - record.refreshedAt > GGFakeGiftsStore.refreshInterval
                }
                return false
            }
            if !hasStaleGeneric {
                return
            }
            let engine = TelegramEngine(account: account)
            let _ = (engine.payments.cachedStarGifts()
            |> take(1)
            |> deliverOn(self.queue)).start(next: { [weak self] catalog in
                guard let self = self, let entry = self.entries[accountPeerId], var records = entry.records else {
                    return
                }
                var catalogById: [Int64: StarGift] = [:]
                for gift in catalog ?? [] {
                    if case let .generic(generic) = gift {
                        catalogById[generic.id] = gift
                    }
                }
                var changed = false
                for index in records.indices where now - records[index].refreshedAt > GGFakeGiftsStore.refreshInterval {
                    if case let .generic(generic) = records[index].gift, let fresh = catalogById[generic.id] {
                        records[index].gift = fresh
                        records[index].refreshedAt = now
                        changed = true
                    }
                }
                if changed {
                    self.commit(entry, records: records)
                }
            })
        }
    }

    // MARK: - Private (queue)

    private func load(_ entry: AccountEntry) {
        if entry.records == nil {
            self.readFile(entry)
        }
        self.resolve(entry)
    }

    private func readFile(_ entry: AccountEntry) {
        var records: [GGFakeGiftRecord] = []
        if let data = try? Data(contentsOf: entry.fileURL), let file = try? JSONDecoder().decode(GGFakeGiftsFile.self, from: data), file.version == 1 {
            records = file.items
            entry.nextLocalId = min(file.nextLocalId, (records.map { $0.localId }.min() ?? 0) - 1, -1)
        }
        entry.records = records
        // Gifts moved from the old client by the migration.
        let accountId = entry.id.gg
        let legacy = GGFakeGiftsSettings.legacyImport.value(for: accountId)
        if !legacy.isEmpty {
            let imported = GGFakeGiftsLegacy.records(from: legacy, accountPeerId: entry.peerId, firstLocalId: entry.nextLocalId)
            if !imported.isEmpty {
                entry.records = imported + records
                entry.nextLocalId = min(entry.nextLocalId, (imported.map { $0.localId }.min() ?? 0) - 1)
                self.writeFile(entry)
            }
            Queue.mainQueue().async {
                GGFakeGiftsSettings.legacyImport.reset(for: accountId)
            }
        }
    }

    private func writeFile(_ entry: AccountEntry) {
        let file = GGFakeGiftsFile(version: 1, nextLocalId: entry.nextLocalId, items: entry.records ?? [])
        guard let data = try? JSONEncoder().encode(file) else {
            return
        }
        try? FileManager.default.createDirectory(at: entry.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try? data.write(to: entry.fileURL, options: .atomic)
    }

    private func commit(_ entry: AccountEntry, records: [GGFakeGiftRecord]) {
        entry.records = records
        self.writeFile(entry)
        self.resolve(entry)
    }

    /// Looks the senders up once and publishes what the profile shows.
    private func resolve(_ entry: AccountEntry) {
        guard let records = entry.records else {
            return
        }
        guard GGFakeGiftsSettings.isEnabled.value, let postbox = entry.postbox else {
            self.publish(entry, records: records, gifts: [])
            return
        }
        let accountPeerId = entry.peerId
        let senderIds = Set(records.compactMap { $0.fromPeer.map(PeerId.init(ggKey:)) })
        entry.resolveDisposable.set((postbox.transaction { transaction -> [PeerId: EnginePeer] in
            var peers: [PeerId: EnginePeer] = [:]
            for peerId in senderIds {
                if let peer = transaction.getPeer(peerId) {
                    peers[peerId] = EnginePeer(peer)
                }
            }
            return peers
        }
        |> deliverOn(self.queue)).start(next: { [weak self, weak entry] peers in
            guard let self = self, let entry = entry, entry.records == records else {
                return
            }
            let gifts = records.map { GGFakeGiftsStore.profileGift($0, accountPeerId: accountPeerId, peers: peers) }
            self.publish(entry, records: records, gifts: gifts)
        }))
    }

    private func publish(_ entry: AccountEntry, records: [GGFakeGiftRecord], gifts: [ProfileGiftsContext.State.StarGift]) {
        let peerId = entry.peerId
        self.lock.withLock {
            self.resolved[peerId] = gifts
            self.recordSnapshots[peerId] = records
        }
        self.changesPipe.putNext(peerId)
        Queue.mainQueue().async {
            GGFakeGiftsPendingPoints.storeDidChange()
        }
    }

    /// What the profile shows for a record: a collectible is owned by you and its original-info line
    /// names the chosen sender, date and caption.
    static func profileGift(_ record: GGFakeGiftRecord, accountPeerId: PeerId, peers: [PeerId: EnginePeer]) -> ProfileGiftsContext.State.StarGift {
        let fromPeerId = record.fromPeer.map(PeerId.init(ggKey:))
        let fromPeer = fromPeerId.flatMap { peers[$0] }
        var gift = record.gift
        if case let .unique(uniqueGift) = gift {
            var attributes = uniqueGift.attributes.filter { attribute in
                if case .originalInfo = attribute {
                    return false
                }
                return true
            }
            attributes.append(.originalInfo(senderPeerId: record.nameHidden ? nil : fromPeerId, recipientPeerId: accountPeerId, date: record.date, text: record.text, entities: record.entities))
            gift = .unique(StarGift.UniqueGift(
                id: uniqueGift.id,
                giftId: uniqueGift.giftId,
                title: uniqueGift.title,
                number: uniqueGift.number,
                slug: uniqueGift.slug,
                owner: .peerId(accountPeerId),
                attributes: attributes,
                availability: uniqueGift.availability,
                giftAddress: nil,
                resellAmounts: nil,
                resellForTonOnly: false,
                releasedBy: uniqueGift.releasedBy,
                valueAmount: uniqueGift.valueAmount,
                valueCurrency: uniqueGift.valueCurrency,
                valueUsdAmount: uniqueGift.valueUsdAmount,
                flags: uniqueGift.flags,
                themePeerId: nil,
                peerColor: uniqueGift.peerColor,
                hostPeerId: nil,
                minOfferStars: nil,
                craftChancePermille: nil
            ))
        }
        return ProfileGiftsContext.State.StarGift(
            gift: gift,
            reference: .peer(peerId: accountPeerId, id: record.localId),
            fromPeer: record.nameHidden ? nil : fromPeer,
            date: record.date,
            text: record.text,
            entities: record.entities,
            nameHidden: record.nameHidden,
            savedToProfile: record.savedToProfile,
            pinnedToTop: record.pinnedToTop,
            convertStars: nil,
            canUpgrade: false,
            canExportDate: nil,
            upgradeStars: nil,
            transferStars: nil,
            canTransferDate: nil,
            canResaleDate: nil,
            collectionIds: nil,
            prepaidUpgradeHash: nil,
            upgradeSeparate: false,
            dropOriginalDetailsStars: nil,
            number: record.number,
            isRefunded: false,
            canCraftAt: nil
        )
    }
}

/// The old client's format: `GG.fakeGifts.items.<PeerId.toInt64()>` — a JSON array of
/// `{gift: ProfileGiftsContext.State.StarGift, fromPeerId: Int64?}` in `UserDefaults.standard`.
enum GGFakeGiftsLegacy {
    private struct Item: Decodable {
        let gift: ProfileGiftsContext.State.StarGift
        let fromPeerId: Int64?
    }

    static func records(from data: Data, accountPeerId: PeerId, firstLocalId: Int64) -> [GGFakeGiftRecord] {
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else {
            return []
        }
        var nextLocalId = min(firstLocalId, -1)
        var result: [GGFakeGiftRecord] = []
        for item in items {
            // A collectible was stored already rewritten (owner = you); the original-info line is
            // derived again when it is shown, so the stored copy is taken as it is.
            let gift = item.gift.gift
            let fromPeer = item.fromPeerId.map { GGLegacyKeys.peerKey(fromLegacyInt64: $0) }
            result.append(GGFakeGiftRecord(localId: nextLocalId, gift: gift, fromPeer: fromPeer, nameHidden: item.gift.nameHidden, date: item.gift.date, text: item.gift.text, entities: item.gift.entities, savedToProfile: item.gift.savedToProfile, pinnedToTop: item.gift.pinnedToTop, number: item.gift.number, refreshedAt: 0))
            nextLocalId -= 1
        }
        return result
    }

    /// Registered from the module's `register()`: moves the toggle, and each account's list (keyed by
    /// the account's `PeerId.toInt64()` in the old client) into `GGFakeGiftsSettings.legacyImport`,
    /// which the store merges into the account's file when it reads it. The peer migration runs when
    /// the account starts, before `GGAccountHooks.accountWillStart` (where the store reads the file).
    static func registerMigrations() {
        GGMigrations.registerGlobal(id: "fakeGifts.v1") { legacy in
            if let enabled = legacy.bool("GG.fakeGifts.enabled") {
                GGFakeGiftsSettings.isEnabled.set(enabled)
                legacy.removeLegacyKey("GG.fakeGifts.enabled")
            }
            legacy.removeLegacyKey("GG.fakeGifts.nextLocalId")
        }
        GGMigrations.registerAccountPeer(id: "fakeGifts.items.v1") { legacy, account, peer in
            guard let legacyPeerId = GGLegacyKeys.legacyInt64(of: peer) else {
                return
            }
            let key = "GG.fakeGifts.items.\(legacyPeerId)"
            if let data = legacy.data(key) {
                GGFakeGiftsSettings.legacyImport.set(data, for: account)
                legacy.removeLegacyKey(key)
            }
        }
    }
}
