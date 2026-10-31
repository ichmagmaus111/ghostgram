import Foundation
import XCTest

final class GGMigrationsTests: XCTestCase {
    private var directory: GGTestDirectory!
    private var suiteName: String!
    private var legacyStore: UserDefaults!

    override func setUp() {
        super.setUp()
        GGTestSettings.touchAll()
        self.directory = GGTestDirectory()
        GGSettingsStore.shared.resetForTesting(environment: self.directory.environment())
        GGMigrations.resetForTesting()
        self.suiteName = "GGCoreTests.legacy.\(UUID().uuidString)"
        self.legacyStore = UserDefaults(suiteName: self.suiteName)
    }

    override func tearDown() {
        GGMigrations.resetForTesting()
        self.legacyStore.removePersistentDomain(forName: self.suiteName)
        GGSettingsStore.shared.flushSynchronously()
        GGSettingsStore.shared.resetForTesting(environment: nil)
        self.directory.remove()
        super.tearDown()
    }

    private var legacy: GGLegacyDefaults {
        return GGLegacyDefaults(stores: [self.legacyStore])
    }

    func testGlobalMigrationRunsOnceAndIsRemembered() {
        self.legacyStore.set(true, forKey: "GhostMode.hideReadReceipts")
        var runs = 0
        GGMigrations.registerGlobal(id: "test.v1") { legacy in
            runs += 1
            if let value = legacy.bool("GhostMode.hideReadReceipts") {
                GGTestSettings.toggle.set(value)
                legacy.removeLegacyKey("GhostMode.hideReadReceipts")
            }
        }
        GGMigrations.runPending(legacy: self.legacy)
        XCTAssertEqual(runs, 1)
        XCTAssertTrue(GGTestSettings.toggle.value)
        XCTAssertNil(self.legacyStore.object(forKey: "GhostMode.hideReadReceipts"))

        GGMigrations.runPending(legacy: self.legacy)
        XCTAssertEqual(runs, 1)

        // The flag survives a relaunch.
        GGSettingsStore.shared.flushSynchronously()
        GGSettingsStore.shared.resetForTesting(environment: self.directory.environment())
        GGMigrations.runPending(legacy: self.legacy)
        XCTAssertEqual(runs, 1)
        XCTAssertTrue(GGMigrations.completedGlobal.value.contains("test.v1"))
    }

    func testMigrationsDoNotRunInExtensions() {
        GGSettingsStore.shared.resetForTesting(environment: self.directory.environment(process: .share))
        var runs = 0
        GGMigrations.registerGlobal(id: "test.extension") { _ in
            runs += 1
        }
        GGMigrations.runPending(legacy: self.legacy)
        XCTAssertEqual(runs, 0)
    }

    func testAccountMigrationRunsPerAccount() {
        let first = GGAccountID(rawValue: 11)
        let second = GGAccountID(rawValue: 12)
        GGSettingsStore.shared.registerAccount(first, basePath: self.directory.makeDirectory("a11"))
        var seen: [GGAccountID] = []
        GGMigrations.registerAccount(id: "test.account.v1") { _, account in
            seen.append(account)
            GGTestSettings.accountToggle.set(true, for: account)
        }
        GGMigrations.runPending(legacy: self.legacy)
        XCTAssertEqual(seen, [first])
        XCTAssertTrue(GGTestSettings.accountToggle.value(for: first))

        GGSettingsStore.shared.registerAccount(second, basePath: self.directory.makeDirectory("a12"))
        GGMigrations.runPendingAccountMigrations(for: second, legacy: self.legacy)
        XCTAssertEqual(seen, [first, second])

        GGMigrations.runPending(legacy: self.legacy)
        XCTAssertEqual(seen, [first, second])
    }

    func testAccountPeerMigrationRunsOnceThePeerIsKnown() {
        let account = GGAccountID(rawValue: 21)
        let peer = GGLegacyKeys.peerKey(fromLegacyInt64: 777000)
        GGSettingsStore.shared.registerAccount(account, basePath: self.directory.makeDirectory("a21"))
        var seen: [(GGAccountID, GGPeerKey)] = []
        GGMigrations.registerAccountPeer(id: "test.accountPeer.v1") { _, account, peer in
            seen.append((account, peer))
            GGTestSettings.accountToggle.set(true, for: account)
        }

        // The peer is not known yet: nothing runs and nothing is marked done.
        GGMigrations.runPending(legacy: self.legacy)
        XCTAssertTrue(seen.isEmpty)
        XCTAssertFalse(GGMigrations.completedAccount.value(for: account).contains("test.accountPeer.v1"))

        GGMigrations.accountPeerDidLoad(account, peer: peer)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, account)
        XCTAssertEqual(seen.first?.1, peer)
        XCTAssertTrue(GGTestSettings.accountToggle.value(for: account))

        // Once per account: neither a restart of the account nor the global pass run it again.
        GGMigrations.accountPeerDidLoad(account, peer: peer)
        GGMigrations.runPending(legacy: self.legacy)
        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(GGMigrations.completedAccount.value(for: account).contains("test.accountPeer.v1"))
    }

    func testAccountPeerMigrationOfAKnownPeerRunsFromTheGlobalPass() {
        let account = GGAccountID(rawValue: 22)
        let peer = GGLegacyKeys.peerKey(fromLegacyInt64: 777001)
        GGSettingsStore.shared.registerAccount(account, basePath: self.directory.makeDirectory("a22"))
        GGMigrations.accountPeerDidLoad(account, peer: peer)
        var runs = 0
        GGMigrations.registerAccountPeer(id: "test.accountPeer.late") { _, _, _ in
            runs += 1
        }
        GGMigrations.runPending(legacy: self.legacy)
        XCTAssertEqual(runs, 1)
    }

    func testLegacyDefaultsTypedReaders() {
        self.legacyStore.set(true, forKey: "b")
        self.legacyStore.set("1", forKey: "bs")
        self.legacyStore.set(42, forKey: "i")
        self.legacyStore.set("43", forKey: "is")
        self.legacyStore.set(1.5, forKey: "d")
        self.legacyStore.set("text", forKey: "s")
        self.legacyStore.set(Data([1, 2]), forKey: "data")
        self.legacyStore.set(["a", "b"], forKey: "sa")
        self.legacyStore.set(["a", 1] as [Any], forKey: "mixed")

        let legacy = self.legacy
        XCTAssertEqual(legacy.bool("b"), true)
        XCTAssertEqual(legacy.bool("bs"), true)
        XCTAssertEqual(legacy.int("i"), 42)
        XCTAssertEqual(legacy.int("is"), 43)
        XCTAssertEqual(legacy.double("d"), 1.5)
        XCTAssertEqual(legacy.string("s"), "text")
        XCTAssertNil(legacy.string("i"))
        XCTAssertEqual(legacy.data("data"), Data([1, 2]))
        XCTAssertEqual(legacy.stringArray("sa"), ["a", "b"])
        XCTAssertNil(legacy.stringArray("mixed"))
        XCTAssertNil(legacy.bool("absent"))
    }

    func testLegacyAccountProfileKey() {
        XCTAssertEqual(GGLegacyDefaults.sanitizedAccountText(GGAccountID(rawValue: 123)), "AccountRecordId_rawValue__123_")
        XCTAssertEqual(GGLegacyDefaults.sanitizedAccountText(GGAccountID(rawValue: -5)), "AccountRecordId_rawValue___5_")

        let profile: [String: Any] = ["GhostMode.isEnabled": true]
        self.legacyStore.set(profile, forKey: "GG.accountConfigs.snapshots.ghostgram.AccountRecordId_rawValue__123_")
        let loaded = self.legacy.legacyAccountProfile(for: GGAccountID(rawValue: 123))
        XCTAssertEqual(loaded?["GhostMode.isEnabled"] as? Bool, true)
        XCTAssertNil(self.legacy.legacyAccountProfile(for: GGAccountID(rawValue: 124)))
    }

    /// With the old profiles on, the shared keys belong to the active account only.
    func testLegacyAccountValue() {
        let active = GGAccountID(rawValue: 123)
        let other = GGAccountID(rawValue: 124)
        let otherWithProfile = GGAccountID(rawValue: 125)
        self.legacyStore.set("777", forKey: "GG.hyperlinkSpoof.targetId")
        self.legacyStore.set(["GG.hyperlinkSpoof.targetId": "555"], forKey: "GG.accountConfigs.snapshots.ghostgram.AccountRecordId_rawValue__123_")
        self.legacyStore.set(["GhostMode.isEnabled": true], forKey: "GG.accountConfigs.snapshots.ghostgram.AccountRecordId_rawValue__125_")

        // Profiles off: everybody has the shared value.
        XCTAssertEqual(self.legacy.legacyAccountValue("GG.hyperlinkSpoof.targetId", for: active) as? String, "777")
        XCTAssertEqual(self.legacy.legacyAccountValue("GG.hyperlinkSpoof.targetId", for: other) as? String, "777")

        self.legacyStore.set(true, forKey: "GG.accountConfigs.enabled.ghostgram")
        self.legacyStore.set("AccountRecordId_rawValue__123_", forKey: "GG.accountConfigs.activeAccountId.ghostgram")
        // The active account: the live shared value, not its older profile.
        XCTAssertEqual(self.legacy.legacyAccountValue("GG.hyperlinkSpoof.targetId", for: active) as? String, "777")
        // Others: their profile only.
        XCTAssertNil(self.legacy.legacyAccountValue("GG.hyperlinkSpoof.targetId", for: other))
        XCTAssertNil(self.legacy.legacyAccountValue("GG.hyperlinkSpoof.targetId", for: otherWithProfile))
        XCTAssertEqual(self.legacy.legacyAccountValue("GhostMode.isEnabled", for: otherWithProfile) as? Bool, true)
    }
}
