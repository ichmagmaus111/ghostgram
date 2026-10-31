import Foundation
import XCTest

// Host tests of «Без перехода к следующему каналу и теме» as one switch (2026-10-27), compiled together
// with Sources/Messages/GGScrollToNextMerge.swift (target GGFeaturesSharedTests).
// Run: ./build-input/bazel-9.2.0-darwin-arm64 test //Ghostgram/Features/Shared:GGFeaturesSharedTests

final class GGScrollToNextMergeTests: XCTestCase {
    func testEitherOldSwitchTurnsTheOneOn() {
        XCTAssertNil(GGScrollToNextMerge.merged(channel: nil, topic: nil))
        XCTAssertEqual(GGScrollToNextMerge.merged(channel: true, topic: nil), true)
        XCTAssertEqual(GGScrollToNextMerge.merged(channel: nil, topic: true), true)
        XCTAssertEqual(GGScrollToNextMerge.merged(channel: true, topic: false), true)
        XCTAssertEqual(GGScrollToNextMerge.merged(channel: false, topic: true), true)
        XCTAssertEqual(GGScrollToNextMerge.merged(channel: true, topic: true), true)
    }

    func testBothStoredOffStaysOff() {
        XCTAssertEqual(GGScrollToNextMerge.merged(channel: false, topic: false), false)
        XCTAssertEqual(GGScrollToNextMerge.merged(channel: false, topic: nil), false)
        XCTAssertEqual(GGScrollToNextMerge.merged(channel: nil, topic: false), false)
    }
}
