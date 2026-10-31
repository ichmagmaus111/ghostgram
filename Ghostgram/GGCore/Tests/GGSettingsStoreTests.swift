import Foundation
import SwiftSignalKit
import XCTest

/// Settings used only by these tests. Declared once: a second declaration of a key asserts.
enum GGTestSettings {
    static let toggle = GGSetting<Bool>("test.toggle", default: false)
    static let counter = GGSetting<Int>("test.counter", default: 7)
    static let title = GGSetting<String>("test.title", default: "")
    static let optionalText = GGSetting<String?>("test.optionalText", default: nil)
    static let list = GGSetting<[String]>("test.list", default: [])
    static let peers = GGSetting<Set<GGPeerKey>>("test.peers", default: [])
    static let shared = GGSetting<Bool>("test.sharedFlag", default: false, scope: .appGroup, flags: [.extensions])
    static let secret = GGSetting<String>("test.secret", default: "", flags: [.noExport])
    static let restart = GGSetting<Bool>("test.restart", default: false, flags: [.requiresRestart])
    static let exceptions = GGAccountSetting<[String]>("test.exceptions", default: [])
    static let accountToggle = GGAccountSetting<Bool>("test.accountToggle", default: false)
    static let accountSecret = GGAccountSetting<String>("test.accountSecret", default: "", flags: [.noExport])

    static func touchAll() {
        let _ = GGTestSettings.toggle
        let _ = GGTestSettings.counter
        let _ = GGTestSettings.title
        let _ = GGTestSettings.optionalText
        let _ = GGTestSettings.list
        let _ = GGTestSettings.peers
        let _ = GGTestSettings.shared
        let _ = GGTestSettings.secret
        let _ = GGTestSettings.restart
        let _ = GGTestSettings.exceptions
        let _ = GGTestSettings.accountToggle
        let _ = GGTestSettings.accountSecret
    }
}

final class GGSettingsStoreTests: XCTestCase {
    private var directory: GGTestDirectory!

    override func setUp() {
        super.setUp()
        GGTestSettings.touchAll()
        self.directory = GGTestDirectory()
        GGSettingsStore.shared.resetForTesting(environment: self.directory.environment())
    }

    override func tearDown() {
        GGSettingsStore.shared.flushSynchronously()
        GGSettingsStore.shared.resetForTesting(environment: nil)
        self.directory.remove()
        self.directory = nil
        super.tearDown()
    }

    private func reload(process: GGProcessKind = .app) {
        GGSettingsStore.shared.flushSynchronously()
        GGSettingsStore.shared.resetForTesting(environment: self.directory.environment(process: process))
    }

    // MARK: - Values and signals

    func testDefaultSetResetAndIsDefault() {
        XCTAssertEqual(GGTestSettings.counter.value, 7)
        XCTAssertTrue(GGTestSettings.counter.isDefault)

        GGTestSettings.counter.set(42)
        XCTAssertEqual(GGTestSettings.counter.value, 42)
        XCTAssertFalse(GGTestSettings.counter.isDefault)

        GGTestSettings.counter.reset()
        XCTAssertEqual(GGTestSettings.counter.value, 7)
        XCTAssertTrue(GGTestSettings.counter.isDefault)
    }

    func testOptionalAndCollectionValues() {
        GGTestSettings.optionalText.set("a")
        GGTestSettings.list.set(["x", "y"])
        let peer = GGPeerKey(namespace: 2, id: 1234567890)!
        GGTestSettings.peers.set([peer])
        self.reload()
        XCTAssertEqual(GGTestSettings.optionalText.value, "a")
        XCTAssertEqual(GGTestSettings.list.value, ["x", "y"])
        XCTAssertEqual(GGTestSettings.peers.value, [peer])

        GGTestSettings.optionalText.set(nil)
        self.reload()
        XCTAssertNil(GGTestSettings.optionalText.value)
    }

    func testSignalDeliversCurrentValueThenDistinctChanges() {
        GGTestSettings.counter.set(1)
        let recorder = GGSignalRecorder(GGTestSettings.counter.signal)
        GGTestSettings.counter.set(2)
        GGTestSettings.counter.set(2)
        GGTestSettings.counter.set(3)
        GGTestSettings.counter.set(1)
        XCTAssertEqual(recorder.values, [1, 2, 3, 1])
        recorder.dispose()
        GGTestSettings.counter.set(9)
        XCTAssertEqual(recorder.values, [1, 2, 3, 1])
    }

    func testRevisionGrowsOnEveryChange() {
        let recorder = GGSignalRecorder(GGSettingsStore.shared.revision)
        XCTAssertEqual(recorder.values.count, 1)
        GGTestSettings.toggle.set(true)
        GGTestSettings.toggle.set(true)
        GGTestSettings.title.set("x")
        let values = recorder.values
        XCTAssertEqual(values.count, 3)
        XCTAssertTrue(values[1] > values[0] && values[2] > values[1])
        recorder.dispose()
    }

    // MARK: - Files

    func testGlobalValueIsWrittenAndReloaded() {
        GGTestSettings.title.set("hello")
        GGSettingsStore.shared.flushSynchronously()
        let stored = self.directory.storedValues(self.directory.globalFilePath)
        XCTAssertEqual(stored?["test.title"] as? String, "hello")

        GGSettingsStore.shared.resetForTesting(environment: nil)
        XCTAssertEqual(GGTestSettings.title.value, "")
        GGSettingsStore.shared.resetForTesting(environment: self.directory.environment())
        XCTAssertEqual(GGTestSettings.title.value, "hello")
    }

    func testDefaultValuesAreNotWritten() {
        GGTestSettings.toggle.set(true)
        GGSettingsStore.shared.flushSynchronously()
        XCTAssertEqual(self.directory.storedValues(self.directory.globalFilePath)?["test.toggle"] as? Bool, true)

        GGTestSettings.toggle.set(false)
        GGSettingsStore.shared.flushSynchronously()
        let stored = self.directory.storedValues(self.directory.globalFilePath)
        XCTAssertNotNil(stored)
        XCTAssertNil(stored?["test.toggle"])
    }

    func testUnknownKeysSurviveRewrite() {
        self.directory.writeFile(self.directory.globalFilePath, "{\"version\":1,\"values\":{\"future.feature\":{\"a\":[1,2]},\"test.counter\":11}}")
        self.reload()
        XCTAssertEqual(GGTestSettings.counter.value, 11)

        GGTestSettings.counter.set(12)
        GGSettingsStore.shared.flushSynchronously()
        let stored = self.directory.storedValues(self.directory.globalFilePath)
        XCTAssertEqual(stored?["test.counter"] as? Int, 12)
        let future = stored?["future.feature"] as? [String: Any]
        XCTAssertEqual(future?["a"] as? [Int], [1, 2])
    }

    func testWritesAreCoalesced() {
        for value in 0 ..< 50 {
            GGTestSettings.counter.set(100 + value)
        }
        // Nothing is on disk before the coalescing delay.
        XCTAssertNil(self.directory.storedValues(self.directory.globalFilePath))

        let written = self.expectation(description: "coalesced write")
        DispatchQueue.main.asyncAfter(deadline: .now() + GGSettingsStore.coalescingDelay + 0.5) {
            written.fulfill()
        }
        self.wait(for: [written], timeout: 5.0)
        GGSettingsStore.shared.flushSynchronously()
        XCTAssertEqual(self.directory.storedValues(self.directory.globalFilePath)?["test.counter"] as? Int, 149)
    }

    func testFlushWritesWithoutWaitingForTheDelay() {
        GGTestSettings.counter.set(5)
        GGSettingsStore.shared.flush()
        GGSettingsStore.shared.flushSynchronously()
        XCTAssertEqual(self.directory.storedValues(self.directory.globalFilePath)?["test.counter"] as? Int, 5)
    }

    func testAppGroupScopeGoesToSharedFile() {
        GGTestSettings.shared.set(true)
        GGSettingsStore.shared.flushSynchronously()
        XCTAssertEqual(self.directory.storedValues(self.directory.sharedFilePath)?["test.sharedFlag"] as? Bool, true)
        XCTAssertNil(self.directory.storedValues(self.directory.globalFilePath)?["test.sharedFlag"])
    }

    func testExtensionReadsOnlyTheSharedFile() {
        GGTestSettings.shared.set(true)
        GGTestSettings.title.set("app only")
        self.reload(process: .notificationService)
        XCTAssertTrue(GGTestSettings.shared.value)
        XCTAssertEqual(GGTestSettings.title.value, "")
    }

    /// iOS keeps the notification service's process between pushes while the app changes the files:
    /// the extension reads them again on the next push (shared.json and the push account's file).
    func testExtensionReadsChangedFilesAgain() {
        let account = GGAccountID(rawValue: 303)
        let basePath = self.directory.makeDirectory("telegram-data", "account-303")
        let accountFile = GGSettingsStore.accountFilePath(basePath: basePath)
        GGSettingsStore.shared.registerAccount(account, basePath: basePath)
        GGTestSettings.shared.set(true)
        GGTestSettings.accountToggle.set(true, for: account)
        self.reload(process: .notificationService)
        GGSettingsStore.shared.registerAccount(account, basePath: basePath)
        XCTAssertTrue(GGTestSettings.shared.value)
        XCTAssertTrue(GGTestSettings.accountToggle.value(for: account))

        let recorder = GGSignalRecorder(GGTestSettings.shared.signal)
        self.directory.writeFile(self.directory.sharedFilePath, "{\"version\":1,\"values\":{}}")
        self.directory.writeFile(accountFile, "{\"version\":1,\"values\":{}}")
        GGSettingsStore.shared.reloadFromDisk()
        XCTAssertFalse(GGTestSettings.shared.value)
        XCTAssertFalse(GGTestSettings.accountToggle.value(for: account))
        XCTAssertEqual(recorder.values, [true, false])
        recorder.dispose()

        // The next push registers the account again: its file is read again too.
        self.directory.writeFile(accountFile, "{\"version\":1,\"values\":{\"test.accountToggle\":true}}")
        GGSettingsStore.shared.registerAccount(account, basePath: basePath)
        XCTAssertTrue(GGTestSettings.accountToggle.value(for: account))
        // Extensions still never write.
        XCTAssertEqual(self.directory.storedValues(accountFile)?["test.accountToggle"] as? Bool, true)
    }

    /// In the app memory is the truth (it may hold changes not written yet): no reload.
    func testAppDoesNotReloadFromDisk() {
        GGTestSettings.shared.set(true)
        self.directory.writeFile(self.directory.sharedFilePath, "{\"version\":1,\"values\":{}}")
        GGSettingsStore.shared.reloadFromDisk()
        XCTAssertTrue(GGTestSettings.shared.value)
    }

    func testDamagedFileIsMovedAsideAndDefaultsAreUsed() {
        self.directory.writeFile(self.directory.globalFilePath, "{not json")
        self.reload()
        XCTAssertEqual(GGTestSettings.counter.value, 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.directory.globalFilePath + ".damaged"))

        GGTestSettings.counter.set(8)
        GGSettingsStore.shared.flushSynchronously()
        XCTAssertEqual(self.directory.storedValues(self.directory.globalFilePath)?["test.counter"] as? Int, 8)
    }

    func testNewerFileFormatIsNeverOverwritten() {
        let text = "{\"version\":2,\"values\":{\"test.counter\":21}}"
        self.directory.writeFile(self.directory.globalFilePath, text)
        self.reload()
        XCTAssertEqual(GGTestSettings.counter.value, 21)
        GGTestSettings.counter.set(22)
        GGSettingsStore.shared.flushSynchronously()
        let data = FileManager.default.contents(atPath: self.directory.globalFilePath)
        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, text)
    }

    func testStoredValueOfAnotherTypeReadsTheDefault() {
        self.directory.writeFile(self.directory.globalFilePath, "{\"version\":1,\"values\":{\"test.counter\":\"seven\"}}")
        self.reload()
        XCTAssertEqual(GGTestSettings.counter.value, 7)
    }

    // MARK: - Accounts

    func testAccountValuesAreSeparateAndLiveInTheAccountDirectory() {
        let first = GGAccountID(rawValue: 101)
        let second = GGAccountID(rawValue: -202)
        let firstPath = self.directory.makeDirectory("telegram-data", "account-101")
        let secondPath = self.directory.makeDirectory("telegram-data", "account-202")
        GGSettingsStore.shared.registerAccount(first, basePath: firstPath)
        GGSettingsStore.shared.registerAccount(second, basePath: secondPath)
        XCTAssertEqual(GGSettingsStore.shared.registeredAccounts, [second, first])

        GGTestSettings.exceptions.set(["0:1"], for: first)
        XCTAssertEqual(GGTestSettings.exceptions.value(for: first), ["0:1"])
        XCTAssertEqual(GGTestSettings.exceptions.value(for: second), [])
        XCTAssertTrue(GGTestSettings.exceptions.isDefault(for: second))

        GGSettingsStore.shared.flushSynchronously()
        let firstFile = GGSettingsStore.accountFilePath(basePath: firstPath)
        XCTAssertEqual(self.directory.storedValues(firstFile)?["test.exceptions"] as? [String], ["0:1"])
        XCTAssertNil(self.directory.storedValues(GGSettingsStore.accountFilePath(basePath: secondPath)))
        XCTAssertNil(self.directory.storedValues(self.directory.globalFilePath)?["test.exceptions"])

        GGSettingsStore.shared.unregisterAccount(first)
        XCTAssertEqual(GGTestSettings.exceptions.value(for: first), [])
        GGSettingsStore.shared.registerAccount(first, basePath: firstPath)
        XCTAssertEqual(GGTestSettings.exceptions.value(for: first), ["0:1"])
    }

    func testAccountSignalIsPerAccount() {
        let first = GGAccountID(rawValue: 1)
        let second = GGAccountID(rawValue: 2)
        GGSettingsStore.shared.registerAccount(first, basePath: self.directory.makeDirectory("a1"))
        GGSettingsStore.shared.registerAccount(second, basePath: self.directory.makeDirectory("a2"))
        let recorder = GGSignalRecorder(GGTestSettings.accountToggle.signal(for: first))
        GGTestSettings.accountToggle.set(true, for: second)
        GGTestSettings.accountToggle.set(true, for: first)
        GGTestSettings.accountToggle.set(false, for: first)
        XCTAssertEqual(recorder.values, [false, true, false])
        recorder.dispose()
    }

    func testWriteForUnregisteredAccountIsIgnored() {
        let account = GGAccountID(rawValue: 77)
        GGTestSettings.accountToggle.set(true, for: account)
        XCTAssertFalse(GGTestSettings.accountToggle.value(for: account))
    }

    func testRemovedAccountDirectoryIsNotRecreated() {
        let account = GGAccountID(rawValue: 5)
        let basePath = self.directory.makeDirectory("telegram-data", "account-5")
        GGSettingsStore.shared.registerAccount(account, basePath: basePath)
        GGTestSettings.accountToggle.set(true, for: account)
        try? FileManager.default.removeItem(atPath: basePath)
        GGSettingsStore.shared.unregisterAccount(account)
        GGSettingsStore.shared.flushSynchronously()
        XCTAssertFalse(FileManager.default.fileExists(atPath: basePath))
    }

    // MARK: - Export / import / reset

    func testExportSkipsSecretsAndImportRestores() {
        let account = GGAccountID(rawValue: 9)
        GGSettingsStore.shared.registerAccount(account, basePath: self.directory.makeDirectory("acc9"))
        GGTestSettings.counter.set(33)
        GGTestSettings.title.set("exported")
        GGTestSettings.secret.set("hash")
        GGTestSettings.exceptions.set(["2:5"], for: account)
        GGTestSettings.accountSecret.set("token", for: account)

        let data = GGSettingsStore.shared.exportData(accounts: [account])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("test.secret"))
        XCTAssertFalse(text.contains("test.accountSecret"))
        XCTAssertTrue(text.contains("test.counter"))

        GGSettingsStore.shared.resetAll(accounts: [account])
        XCTAssertEqual(GGTestSettings.counter.value, 7)
        XCTAssertEqual(GGTestSettings.exceptions.value(for: account), [])
        // Secrets survive "reset all".
        XCTAssertEqual(GGTestSettings.secret.value, "hash")
        XCTAssertEqual(GGTestSettings.accountSecret.value(for: account), "token")

        let diff: GGSettingsImportDiff
        do {
            diff = try GGSettingsStore.shared.importPreview(data)
        } catch {
            XCTFail("import preview failed: \(error)")
            return
        }
        let counterChange = diff.changes.first(where: { $0.key == "test.counter" })
        XCTAssertEqual(counterChange?.oldValue, "7")
        XCTAssertEqual(counterChange?.newValue, "33")
        XCTAssertEqual(counterChange?.scope, .global)
        let accountChange = diff.changes.first(where: { $0.key == "test.exceptions" })
        XCTAssertEqual(accountChange?.account, account)
        XCTAssertEqual(accountChange?.scope, .account)
        XCTAssertNil(diff.changes.first(where: { $0.key == "test.toggle" }), "unchanged values are not in the diff")

        GGSettingsStore.shared.applyImport(diff)
        XCTAssertEqual(GGTestSettings.counter.value, 33)
        XCTAssertEqual(GGTestSettings.title.value, "exported")
        XCTAssertEqual(GGTestSettings.exceptions.value(for: account), ["2:5"])
    }

    func testImportBumpsRevisionOnce() {
        GGTestSettings.counter.set(1)
        GGTestSettings.title.set("a")
        let data = GGSettingsStore.shared.exportData(accounts: [])
        GGSettingsStore.shared.resetAll(accounts: [])
        let diff = try? GGSettingsStore.shared.importPreview(data)
        XCTAssertEqual(diff?.changes.count, 2)
        let recorder = GGSignalRecorder(GGSettingsStore.shared.revision)
        if let diff = diff {
            GGSettingsStore.shared.applyImport(diff)
        }
        XCTAssertEqual(recorder.values.count, 2)
        recorder.dispose()
    }

    func testImportRejectsForeignAndNewerFiles() {
        XCTAssertThrowsError(try GGSettingsStore.shared.importPreview(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? GGSettingsImportError, .invalidFormat)
        }
        XCTAssertThrowsError(try GGSettingsStore.shared.importPreview(Data("{\"format\":\"other\",\"version\":1}".utf8))) { error in
            XCTAssertEqual(error as? GGSettingsImportError, .invalidFormat)
        }
        XCTAssertThrowsError(try GGSettingsStore.shared.importPreview(Data("{\"format\":\"ghostgram.settings\",\"version\":2}".utf8))) { error in
            XCTAssertEqual(error as? GGSettingsImportError, .unsupportedVersion(2))
        }
    }

    func testImportSortsOutUnknownSecretAndMistypedKeys() {
        let text = """
        {"format":"ghostgram.settings","version":1,
         "global":{"test.counter":"many","test.secret":"stolen","nobody.knows":1,"test.toggle":true},
         "appGroup":{},"accounts":{}}
        """
        guard let diff = try? GGSettingsStore.shared.importPreview(Data(text.utf8)) else {
            XCTFail("import preview failed")
            return
        }
        XCTAssertEqual(diff.unknownKeys, ["nobody.knows"])
        XCTAssertEqual(diff.skippedKeys, ["test.counter", "test.secret"])
        XCTAssertEqual(diff.changes.map { $0.key }, ["test.toggle"])
        GGSettingsStore.shared.applyImport(diff)
        XCTAssertEqual(GGTestSettings.secret.value, "")
        XCTAssertTrue(GGTestSettings.toggle.value)
    }

    func testImportMapsTheOnlyAccountSection() {
        let here = GGAccountID(rawValue: 1000)
        GGSettingsStore.shared.registerAccount(here, basePath: self.directory.makeDirectory("acc1000"))
        let text = """
        {"format":"ghostgram.settings","version":1,"global":{},"appGroup":{},
         "accounts":{"555":{"test.accountToggle":true}}}
        """
        guard let diff = try? GGSettingsStore.shared.importPreview(Data(text.utf8)) else {
            XCTFail("import preview failed")
            return
        }
        XCTAssertEqual(diff.unmatchedAccounts, [])
        XCTAssertEqual(diff.changes.first?.account, here)

        let other = GGAccountID(rawValue: 2000)
        GGSettingsStore.shared.registerAccount(other, basePath: self.directory.makeDirectory("acc2000"))
        guard let ambiguous = try? GGSettingsStore.shared.importPreview(Data(text.utf8)) else {
            XCTFail("import preview failed")
            return
        }
        XCTAssertEqual(ambiguous.unmatchedAccounts, [GGAccountID(rawValue: 555)])
        guard let mapped = try? GGSettingsStore.shared.importPreview(Data(text.utf8), accountMapping: [GGAccountID(rawValue: 555): other]) else {
            XCTFail("import preview failed")
            return
        }
        XCTAssertEqual(mapped.changes.first?.account, other)
    }

    // MARK: - Registry

    func testRegistryKnowsDeclaredSettings() {
        let _ = GGLocalization.languageOverride
        let keys = GGSettingsStore.shared.registeredKeys
        XCTAssertTrue(keys.contains("test.toggle"))
        XCTAssertTrue(keys.contains("test.exceptions"))
        XCTAssertTrue(keys.contains("core.language"))
        XCTAssertTrue(GGTestSettings.restart.flags.contains(.requiresRestart))
        XCTAssertEqual(GGTestSettings.shared.scope, .appGroup)
    }

    #if DEBUG
    func testUnreadSettingsAreReported() {
        let _ = GGTestSettings.toggle.value
        let unread = GGSettingsStore.shared.debugUnreadKeys()
        XCTAssertFalse(unread.contains("test.toggle"))
        XCTAssertTrue(unread.contains("test.restart"), "declared, shown in a menu, never read: a dead toggle")
    }
    #endif

    func testKeyValidation() {
        XCTAssertTrue(GGSettingsStore.isValidKey("ghostMode.hideReadReceipts"))
        XCTAssertTrue(GGSettingsStore.isValidKey("a.b.c2"))
        XCTAssertFalse(GGSettingsStore.isValidKey("ghostMode"))
        XCTAssertFalse(GGSettingsStore.isValidKey("GhostMode.x"))
        XCTAssertFalse(GGSettingsStore.isValidKey("ghost-mode.x"))
        XCTAssertFalse(GGSettingsStore.isValidKey("ghostMode..x"))
        XCTAssertFalse(GGSettingsStore.isValidKey("ghostMode.x "))
    }

    func testReadIsCheap() {
        GGTestSettings.toggle.set(true)
        let iterations = 1_000_000
        var count = 0
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< iterations {
            if GGTestSettings.toggle.value {
                count += 1
            }
        }
        let perRead = (CFAbsoluteTimeGetCurrent() - start) / Double(iterations)
        XCTAssertEqual(count, iterations)
        // Generous bound for unoptimized test builds; the target in release is tens of nanoseconds.
        XCTAssertLessThan(perRead, 2.0e-6)
    }
}
