import Foundation
import XCTest

// Host tests of the one send delay (since 2026-10-27), compiled together with
// Sources/GhostMode/GGSendDelaySeconds.swift (target GGFeaturesSharedTests).
// Run: ./build-input/bazel-9.2.0-darwin-arm64 test //Ghostgram/Features/Shared:GGFeaturesSharedTests

final class GGSendDelaySecondsTests: XCTestCase {
    func testDefaultIsTheLargerOldDefault() {
        XCTAssertEqual(GGSendDelaySeconds.defaultValue, 20.0)
        XCTAssertTrue(GGSendDelaySeconds.range.contains(GGSendDelaySeconds.defaultValue))
    }

    func testMergeTakesTheLargerOfTheTwo() {
        // Nothing stored: the default already is max(12, 20).
        XCTAssertNil(GGSendDelaySeconds.merged(text: nil, media: nil))
        XCTAssertEqual(GGSendDelaySeconds.merged(text: 30.0, media: nil), 30.0)
        XCTAssertEqual(GGSendDelaySeconds.merged(text: 15.0, media: nil), 20.0)
        XCTAssertEqual(GGSendDelaySeconds.merged(text: nil, media: 90.0), 90.0)
        XCTAssertEqual(GGSendDelaySeconds.merged(text: 45.0, media: 25.0), 45.0)
        XCTAssertEqual(GGSendDelaySeconds.merged(text: 12.0, media: 180.0), 180.0)
    }

    func testValuesStayInTheRange() {
        XCTAssertEqual(GGSendDelaySeconds.merged(text: 500.0, media: nil), 180.0)
        XCTAssertEqual(GGSendDelaySeconds.clamped(3.0), 12.0)
        XCTAssertEqual(GGSendDelaySeconds.clamped(.nan), GGSendDelaySeconds.defaultValue)
        XCTAssertEqual(GGSendDelaySeconds.clamped(61.0), 61.0)
    }
}
