import Foundation
import XCTest

final class GGSharedInboxTests: XCTestCase {
    private var directory: GGTestDirectory!

    override func setUp() {
        super.setUp()
        self.directory = GGTestDirectory()
    }

    override func tearDown() {
        self.directory.remove()
        super.tearDown()
    }

    func testAppendThenDrainInOrder() {
        let path = self.directory.subpath("inbox")
        let writer = GGSharedInbox(name: "deletions", directoryPath: path, maximumSize: 1024)
        let reader = GGSharedInbox(name: "deletions", directoryPath: path, maximumSize: 1024)
        writer.append(Data("one".utf8))
        writer.append(Data())
        writer.append(Data("three".utf8))
        XCTAssertEqual(reader.drain(), [Data("one".utf8), Data(), Data("three".utf8)])
        XCTAssertEqual(reader.drain(), [])
        writer.append(Data("four".utf8))
        XCTAssertEqual(reader.drain(), [Data("four".utf8)])
    }

    func testDrainWithoutFileIsEmpty() {
        let inbox = GGSharedInbox(name: "nothing", directoryPath: self.directory.subpath("inbox"), maximumSize: 1024)
        XCTAssertEqual(inbox.drain(), [])
    }

    func testFullInboxDropsNewRecords() {
        let inbox = GGSharedInbox(name: "small", directoryPath: self.directory.subpath("inbox"), maximumSize: 16)
        inbox.append(Data(repeating: 1, count: 8))
        inbox.append(Data(repeating: 2, count: 8))
        XCTAssertEqual(inbox.drain(), [Data(repeating: 1, count: 8)])
    }

    func testTornTailIsDiscarded() throws {
        let path = self.directory.subpath("inbox")
        let inbox = GGSharedInbox(name: "torn", directoryPath: path, maximumSize: 1024)
        inbox.append(Data("whole".utf8))
        let file = (path as NSString).appendingPathComponent("torn")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        let _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data([0, 0, 0, 9, 65, 66]))
        try handle.close()
        XCTAssertEqual(inbox.drain(), [Data("whole".utf8)])
    }

    func testRecordParsing() {
        let data = Data([0, 0, 0, 2, 7, 8, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(GGSharedInbox.parseRecords(data, maximumSize: 100), [Data([7, 8]), Data()])
        XCTAssertEqual(GGSharedInbox.parseRecords(Data([255, 255, 255, 255, 1]), maximumSize: 100), [])
    }

    func testNames() {
        XCTAssertTrue(GGSharedInbox.isValidName("antiDelete.v1"))
        XCTAssertFalse(GGSharedInbox.isValidName("../escape"))
        XCTAssertFalse(GGSharedInbox.isValidName(".."))
        XCTAssertFalse(GGSharedInbox.isValidName(""))
    }

    func testConcurrentAppendsAreNotInterleaved() {
        let path = self.directory.subpath("inbox")
        let inbox = GGSharedInbox(name: "concurrent", directoryPath: path, maximumSize: 1 << 20)
        let group = DispatchGroup()
        for worker in 0 ..< 4 {
            group.enter()
            DispatchQueue.global().async {
                let writer = GGSharedInbox(name: "concurrent", directoryPath: path, maximumSize: 1 << 20)
                for index in 0 ..< 50 {
                    writer.append(Data(repeating: UInt8(worker), count: 10 + index))
                }
                group.leave()
            }
        }
        group.wait()
        let records = inbox.drain()
        XCTAssertEqual(records.count, 200)
        for record in records {
            XCTAssertTrue(Set(record).count == 1, "every record holds one writer's bytes")
        }
    }
}
