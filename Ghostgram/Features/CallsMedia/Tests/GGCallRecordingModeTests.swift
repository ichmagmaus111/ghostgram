import Foundation
import XCTest

// Host tests of «Записывать звонки» as one choice (2026-10-27), compiled together with
// Sources/Settings/GGCallRecordingMode.swift only.
// Run: ./build-input/bazel-9.2.0-darwin-arm64 test //Ghostgram/Features/CallsMedia:GGCallRecordingModeTests

final class GGCallRecordingModeTests: XCTestCase {
    func testMergeOfTheTwoOldSwitches() {
        // Nothing stored: keep the default.
        XCTAssertNil(GGCallRecordingMode.merged(audio: nil, video: nil))
        // Video on wins, also without audio (a video-only setting is not a choice any more).
        XCTAssertEqual(GGCallRecordingMode.merged(audio: true, video: true), .audioAndVideo)
        XCTAssertEqual(GGCallRecordingMode.merged(audio: false, video: true), .audioAndVideo)
        XCTAssertEqual(GGCallRecordingMode.merged(audio: nil, video: true), .audioAndVideo)
        // Audio only.
        XCTAssertEqual(GGCallRecordingMode.merged(audio: true, video: false), .audio)
        XCTAssertEqual(GGCallRecordingMode.merged(audio: true, video: nil), .audio)
        // Both stored off, or one stored off and the other never written.
        XCTAssertEqual(GGCallRecordingMode.merged(audio: false, video: false), .off)
        XCTAssertEqual(GGCallRecordingMode.merged(audio: false, video: nil), .off)
        XCTAssertEqual(GGCallRecordingMode.merged(audio: nil, video: false), .off)
    }

    func testWhatEachChoiceRecords() {
        XCTAssertFalse(GGCallRecordingMode.off.isOn)
        XCTAssertFalse(GGCallRecordingMode.off.recordsVideo)
        XCTAssertTrue(GGCallRecordingMode.audio.isOn)
        XCTAssertFalse(GGCallRecordingMode.audio.recordsVideo)
        XCTAssertTrue(GGCallRecordingMode.audioAndVideo.isOn)
        XCTAssertTrue(GGCallRecordingMode.audioAndVideo.recordsVideo)
    }

    func testStoredValues() {
        // The raw values are what `calls.record` stores: they must not change.
        XCTAssertEqual(GGCallRecordingMode.allCases.map(\.rawValue), ["off", "audio", "audioAndVideo"])
        for mode in GGCallRecordingMode.allCases {
            XCTAssertEqual(GGCallRecordingMode.resolved(mode.rawValue), mode)
        }
        XCTAssertEqual(GGCallRecordingMode.resolved(""), .off)
        XCTAssertEqual(GGCallRecordingMode.resolved("video"), .off)
    }
}
