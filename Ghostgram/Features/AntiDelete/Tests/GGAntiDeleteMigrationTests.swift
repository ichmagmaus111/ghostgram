import Foundation
import XCTest
import GGCore

/// The old Ghostgram's files → typed records (the import into Postbox is on top of these).
final class GGAntiDeleteMigrationTests: XCTestCase {
    private let privatePeer = GGPeerKey(namespace: 0, id: 777000)!
    private let channelPeer = GGPeerKey(namespace: 2, id: 1234567890)!

    private func legacy(_ peer: GGPeerKey) -> Int64 {
        return GGLegacyKeys.legacyInt64(of: peer)!
    }

    private func json(_ object: Any) -> Data {
        return try! JSONSerialization.data(withJSONObject: object, options: [])
    }

    func testDeletedArchiveIsParsedLeniently() {
        let data = self.json([
            ["globalId": 5, "peerId": self.legacy(self.channelPeer), "messageId": 15, "timestamp": 1000, "deletedAt": 1100, "authorId": 1, "authorName": "Канал", "text": "пост", "threadId": 3],
            ["peerId": "not a number", "messageId": 1, "text": "broken"],
            ["globalId": 6, "peerId": self.legacy(self.privatePeer), "messageId": 16, "timestamp": 2000, "deletedAt": 2100, "authorUsername": "user", "text": "", "mediaDescription": "Фото"],
            // A duplicate of the first record (the old archive kept appending): the first one wins.
            ["globalId": 5, "peerId": self.legacy(self.channelPeer), "messageId": 15, "timestamp": 1000, "deletedAt": 9999, "text": "copy"]
        ])
        let entries = GGAntiDeleteLegacyParser.deletedArchive(data)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].peer, self.channelPeer)
        XCTAssertEqual(entries[0].messageId, 15)
        XCTAssertEqual(entries[0].text, "пост")
        XCTAssertEqual(entries[0].threadId, 3)
        XCTAssertEqual(entries[0].deletedAt, 1100)
        XCTAssertEqual(entries[1].peer, self.privatePeer)
        XCTAssertEqual(entries[1].authorUsername, "user")
        XCTAssertEqual(entries[1].mediaDescription, "Фото")
        XCTAssertEqual(GGAntiDeleteLegacyParser.deletedArchive(Data("garbage".utf8)), [])
    }

    func testEditHistoryKeysKeepTheWholePeerId() {
        let key = "\(self.legacy(self.channelPeer))_42"
        let data = self.json([
            key: [["text": "v2", "editDate": 20], ["text": "v1", "editDate": 10]],
            "bad key": [["text": "x", "editDate": 1]],
            "\(self.legacy(self.privatePeer))_7": []
        ])
        let entries = GGAntiDeleteLegacyParser.editHistory(data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].message, GGMessageKey(peer: self.channelPeer, namespace: 0, id: 42))
        XCTAssertEqual(entries[0].versions.map(\.text), ["v1", "v2"])
    }

    func testLocalEditsTakeTheLastVersion() {
        let data = self.json(["\(self.legacy(self.privatePeer))_3": ["first", "second"], "\(self.legacy(self.privatePeer))_4": [""]])
        let edits = GGAntiDeleteLegacyParser.localEdits(data)
        XCTAssertEqual(edits, [GGLegacyLocalEdit(message: GGMessageKey(peer: self.privatePeer, namespace: 0, id: 3), text: "second")])
    }

    func testBookmarks() {
        let data = self.json([
            ["peerId": self.legacy(self.privatePeer), "namespace": 0, "id": 9, "title": "Важное", "timestamp": 500, "createdAt": 600.7],
            ["peerId": self.legacy(self.privatePeer), "namespace": 0, "id": 9, "title": "Дубль", "timestamp": 500, "createdAt": 601.0]
        ])
        let bookmarks = GGAntiDeleteLegacyParser.bookmarks(data)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks[0].title, "Важное")
        XCTAssertEqual(bookmarks[0].messageDate, 500)
        XCTAssertEqual(bookmarks[0].createdAt, 600)
    }

    func testStashRoundTrip() {
        let stash = GGAntiDeleteLegacyStash(editHistory: Data([1, 2, 3]), archiveMirror: nil)
        XCTAssertEqual(GGAntiDeleteLegacyStash(data: stash.encode()), stash)
        XCTAssertTrue(GGAntiDeleteLegacyStash(editHistory: nil, archiveMirror: nil).isEmpty)
    }

    func testExportDropsSecretChatsBothWays() {
        let secret = GGPeerKey(namespace: 3, id: 5)!
        let file = GGAntiDeleteExportFile(account: GGAccountID(rawValue: 7), exportedAt: 1, deleted: [
            GGAntiDeleteExportFile.Deleted(message: GGMessageKey(peer: self.privatePeer, namespace: 0, id: 1), thread: nil, date: 1, deletedAt: 2, author: "A", username: nil, text: "t", media: nil),
            GGAntiDeleteExportFile.Deleted(message: GGMessageKey(peer: secret, namespace: 2, id: 1), thread: nil, date: 1, deletedAt: 2, author: "S", username: nil, text: "secret", media: nil)
        ], edited: [])
        guard let data = file.encode() else {
            return XCTFail("encode")
        }
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
        guard case let .success(decoded) = GGAntiDeleteExportFile.decode(data) else {
            return XCTFail("decode")
        }
        XCTAssertEqual(decoded.deleted.count, 1)
        XCTAssertEqual(decoded.account, GGAccountID(rawValue: 7))

        var newer = file
        newer.version = 99
        let newerData = try! JSONEncoder().encode(newer)
        XCTAssertEqual(GGAntiDeleteExportFile.decode(newerData).failureValue, .unsupportedVersion(99))
        XCTAssertEqual(GGAntiDeleteExportFile.decode(Data("{}".utf8)).failureValue, .invalidFormat)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case let .failure(error) = self {
            return error
        }
        return nil
    }
}
