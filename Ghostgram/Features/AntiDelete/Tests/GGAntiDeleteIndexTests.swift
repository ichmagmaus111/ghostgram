import Foundation
import XCTest
import GGCore

final class GGAntiDeleteIndexTests: XCTestCase {
    private func entry(_ id: Int32, time: Int32, namespace: Int32 = 0, count: Int32 = 0, thread: Int64? = nil) -> GGAntiDeleteLogEntry {
        return GGAntiDeleteLogEntry(namespace: namespace, id: id, threadId: thread, time: time, source: GGAntiDeleteSource.remote.rawValue, count: count)
    }

    func testUpsertKeepsOneEntryPerMessageInTimeOrder() {
        var log = GGAntiDeletePeerLog()
        log.upsert([self.entry(3, time: 30), self.entry(1, time: 10)])
        log.upsert([self.entry(2, time: 20), self.entry(1, time: 40, count: 2)])
        XCTAssertEqual(log.entries.map(\.id), [2, 3, 1])
        XCTAssertEqual(log.entries.last?.count, 2)
        XCTAssertEqual(log.lastTime, 40)
        XCTAssertTrue(log.contains(GGAntiDeleteMessageRef(namespace: 0, id: 3)))
        XCTAssertFalse(log.contains(GGAntiDeleteMessageRef(namespace: 1, id: 3)))
    }

    func testNamespacesDoNotCollide() {
        // A secret chat has outgoing (Local) and incoming (SecretIncoming) messages with equal ids.
        var log = GGAntiDeletePeerLog()
        log.upsert([self.entry(5, time: 1, namespace: 1), self.entry(5, time: 2, namespace: 2)])
        XCTAssertEqual(log.count, 2)
        log.remove([GGAntiDeleteMessageRef(namespace: 1, id: 5)])
        XCTAssertEqual(log.entries.map(\.namespace), [2])
    }

    func testCapDropsTheOldestAndReportsThem() {
        var log = GGAntiDeletePeerLog()
        let dropped = log.upsert((1 ... 10).map { self.entry($0, time: $0) }, limit: 4)
        XCTAssertEqual(log.entries.map(\.id), [7, 8, 9, 10])
        XCTAssertEqual(dropped.map(\.id), [1, 2, 3, 4, 5, 6])
    }

    func testPruneRemovesOnlyOlderEntries() {
        var log = GGAntiDeletePeerLog(entries: (1 ... 5).map { self.entry($0, time: $0 * 100) })
        XCTAssertEqual(log.prune(olderThan: 100), [])
        let removed = log.prune(olderThan: 350)
        XCTAssertEqual(removed.map(\.id), [1, 2, 3])
        XCTAssertEqual(log.entries.map(\.id), [4, 5])
        XCTAssertEqual(log.prune(olderThan: 10_000).count, 2)
        XCTAssertTrue(log.isEmpty)
    }

    func testPagesAreNewestFirst() {
        let log = GGAntiDeletePeerLog(entries: (1 ... 7).map { self.entry($0, time: $0) })
        XCTAssertEqual(log.newestFirst(offset: 0, limit: 3).map(\.id), [7, 6, 5])
        XCTAssertEqual(log.newestFirst(offset: 3, limit: 3).map(\.id), [4, 3, 2])
        XCTAssertEqual(log.newestFirst(offset: 6, limit: 3).map(\.id), [1])
        XCTAssertEqual(log.newestFirst(offset: 9, limit: 3), [])
    }

    func testLogRoundTripAndDamagedData() {
        let log = GGAntiDeletePeerLog(entries: [
            self.entry(1, time: 10, thread: 77),
            GGAntiDeleteLogEntry(namespace: 2, id: -3, threadId: nil, time: 11, source: 6, count: 0, isOutgoing: true, isArchiveOnly: true),
            self.entry(9, time: 12, count: 4)
        ])
        let data = log.encode()
        XCTAssertEqual(GGAntiDeletePeerLog(data: data), log)
        XCTAssertNil(GGAntiDeletePeerLog(data: data.prefix(data.count - 3)))
        XCTAssertNil(GGAntiDeletePeerLog(data: Data([9, 0, 0, 0, 0])))
        XCTAssertNil(GGAntiDeletePeerLog(data: Data()))
    }

    func testSummaryFollowsLogs() {
        let peerA = GGPeerKey(namespace: 0, id: 100)!
        let peerB = GGPeerKey(namespace: 2, id: 200)!
        var summary = GGAntiDeleteSummary()
        summary.update(peer: peerA, log: GGAntiDeletePeerLog(entries: [self.entry(1, time: 50), self.entry(2, time: 60)]))
        summary.update(peer: peerB, log: GGAntiDeletePeerLog(entries: [self.entry(1, time: 70)]))
        XCTAssertEqual(summary.totalCount, 3)
        XCTAssertEqual(summary.count(for: peerA), 2)
        XCTAssertEqual(summary.sortedPeers.map { $0.peer }, [peerB, peerA])
        XCTAssertEqual(GGAntiDeleteSummary(data: summary.encode()), summary)
        summary.update(peer: peerB, log: GGAntiDeletePeerLog())
        XCTAssertEqual(summary.count(for: peerB), 0)
        XCTAssertEqual(summary.peers.count, 1)
    }

    func testArchivedContentRoundTrip() {
        let content = GGAntiDeleteArchivedContent(date: 1, deletedAt: 2, authorName: "Анна", authorUsername: nil, text: "привет 👋", mediaDescription: "photo")
        XCTAssertEqual(GGAntiDeleteArchivedContent(data: content.encode()), content)
    }

    func testBookmarkListOrderAndFilter() {
        let peer = GGPeerKey(namespace: 0, id: 1)!
        let other = GGPeerKey(namespace: 0, id: 2)!
        var list = GGBookmarkList()
        list.set(GGBookmarkEntry(message: GGMessageKey(peer: peer, namespace: 0, id: 20), threadId: nil, title: "b", createdAt: 1, messageDate: 200))
        list.set(GGBookmarkEntry(message: GGMessageKey(peer: peer, namespace: 0, id: 10), threadId: 5, title: "a", createdAt: 2, messageDate: 100))
        list.set(GGBookmarkEntry(message: GGMessageKey(peer: other, namespace: 0, id: 1), threadId: nil, title: "c", createdAt: 3, messageDate: 50))
        XCTAssertEqual(list.entries.map(\.title), ["c", "a", "b"])
        XCTAssertEqual(list.entries(peer: peer, threadId: nil).map(\.title), ["a", "b"])
        XCTAssertEqual(list.entries(peer: peer, threadId: 5).map(\.title), ["a"])
        // Setting again replaces, removing works by message.
        list.set(GGBookmarkEntry(message: GGMessageKey(peer: peer, namespace: 0, id: 20), threadId: nil, title: "b2", createdAt: 4, messageDate: 200))
        XCTAssertEqual(list.entries.count, 3)
        XCTAssertEqual(list.entries.first?.title, "b2")
        XCTAssertEqual(list.remove([GGMessageKey(peer: other, namespace: 0, id: 1)]), 1)
        XCTAssertEqual(GGBookmarkList(data: list.encode()), list)
    }

    func testBookmarkListReportsEvictedEntries() {
        let peer = GGPeerKey(namespace: 0, id: 1)!
        var list = GGBookmarkList()
        for id in 1 ... Int32(GGBookmarkList.maximumCount) {
            XCTAssertEqual(list.set(GGBookmarkEntry(message: GGMessageKey(peer: peer, namespace: 0, id: id), threadId: nil, title: "", createdAt: id, messageDate: id)), [])
        }
        // Re-setting one already in the list evicts nothing.
        XCTAssertEqual(list.set(GGBookmarkEntry(message: GGMessageKey(peer: peer, namespace: 0, id: 1), threadId: nil, title: "again", createdAt: 0, messageDate: 1)), [])
        // The next new one pushes out the oldest (now id 2) and says so.
        let evicted = list.set(GGBookmarkEntry(message: GGMessageKey(peer: peer, namespace: 0, id: 5000), threadId: nil, title: "", createdAt: 5000, messageDate: 5000))
        XCTAssertEqual(evicted.map(\.message.id), [2])
        XCTAssertEqual(list.entries.count, GGBookmarkList.maximumCount)
        XCTAssertNil(list.entry(for: GGMessageKey(peer: peer, namespace: 0, id: 2)))
    }

    func testInboxRecordRoundTrip() {
        let record = GGAntiDeleteInboxRecord(account: GGAccountID(rawValue: -42), kind: .edited, peer: GGPeerKey(namespace: 3, id: 99)!, entries: [self.entry(4, time: 9, namespace: 2, count: 3)])
        XCTAssertEqual(GGAntiDeleteInboxRecord(data: record.encode()), record)
        let empty = GGAntiDeleteInboxRecord(account: GGAccountID(rawValue: 1), kind: .deleted, peer: GGPeerKey(namespace: 3, id: 1)!, entries: [])
        XCTAssertEqual(GGAntiDeleteInboxRecord(data: empty.encode()), empty)
        XCTAssertNil(GGAntiDeleteInboxRecord(data: Data([2, 1, 2, 3])))
    }

    func testRetention() {
        XCTAssertNil(GGAntiDeleteRetention.never.cutoff(now: 1_000_000))
        XCTAssertEqual(GGAntiDeleteRetention.day.cutoff(now: 1_000_000), 1_000_000 - 86_400)
        XCTAssertEqual(GGAntiDeleteRetention(settingValue: "garbage"), .never)
        XCTAssertEqual(GGAntiDeleteRetention.fromLegacyHours(0), .never)
        XCTAssertEqual(GGAntiDeleteRetention.fromLegacyHours(6), .day)
        XCTAssertEqual(GGAntiDeleteRetention.fromLegacyHours(48), .week)
        XCTAssertEqual(GGAntiDeleteRetention.fromLegacyHours(168), .week)
    }
}
