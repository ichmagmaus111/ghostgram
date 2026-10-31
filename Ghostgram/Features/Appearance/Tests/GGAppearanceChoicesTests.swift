import Foundation
import XCTest

// Host tests of the choices that replaced switch pairs and the nine screen-edge rows (2026-10-27),
// compiled together with Settings/Sources/GGAppearanceChoices.swift only.
// Run: ./build-input/bazel-9.2.0-darwin-arm64 test //Ghostgram/Features/Appearance:GGAppearanceChoicesTests

final class GGAppearanceChoicesTests: XCTestCase {
    // MARK: Hidden reactions and formatting

    func testHiddenReactionsFromTwoSwitches() {
        XCTAssertNil(GGHiddenReactions.merged(inChats: nil, inChannels: nil))
        XCTAssertNil(GGHiddenReactions.merged(inChats: false, inChannels: false))
        XCTAssertEqual(GGHiddenReactions.merged(inChats: true, inChannels: nil), .chats)
        XCTAssertEqual(GGHiddenReactions.merged(inChats: false, inChannels: true), .channels)
        XCTAssertEqual(GGHiddenReactions.merged(inChats: true, inChannels: true), .all)
    }

    func testHiddenReactionsPlaces() {
        for value in GGHiddenReactions.allCases {
            XCTAssertEqual(GGHiddenReactions(inChats: value.inChats, inChannels: value.inChannels), value)
        }
        XCTAssertFalse(GGHiddenReactions.off.inChats || GGHiddenReactions.off.inChannels)
        XCTAssertTrue(GGHiddenReactions.chats.inChats && !GGHiddenReactions.chats.inChannels)
        XCTAssertTrue(!GGHiddenReactions.channels.inChats && GGHiddenReactions.channels.inChannels)
        XCTAssertTrue(GGHiddenReactions.all.inChats && GGHiddenReactions.all.inChannels)
    }

    func testHiddenFormattingFromTwoSwitches() {
        XCTAssertNil(GGHiddenFormatting.merged(inIncoming: nil, inOutgoing: false))
        XCTAssertEqual(GGHiddenFormatting.merged(inIncoming: true, inOutgoing: nil), .incoming)
        XCTAssertEqual(GGHiddenFormatting.merged(inIncoming: nil, inOutgoing: true), .outgoing)
        XCTAssertEqual(GGHiddenFormatting.merged(inIncoming: true, inOutgoing: true), .all)
        for value in GGHiddenFormatting.allCases {
            XCTAssertEqual(GGHiddenFormatting(inIncoming: value.inIncoming, inOutgoing: value.inOutgoing), value)
        }
    }

    func testRawValuesAreStable() {
        // Stored in the settings file: never rename.
        XCTAssertEqual(GGHiddenReactions.allCases.map { $0.rawValue }, ["off", "chats", "channels", "all"])
        XCTAssertEqual(GGHiddenFormatting.allCases.map { $0.rawValue }, ["off", "incoming", "outgoing", "all"])
        XCTAssertEqual(GGEdgeStyle.allCases.map { $0.rawValue }, ["off", "blur", "gradient"])
    }

    // MARK: Screen edges

    func testNothingStoredWritesNothing() {
        XCTAssertNil(GGEdgeMerge.merged(GGEdgeMerge.Old()))
        XCTAssertNil(GGEdgeMerge.merged(GGEdgeMerge.Old(blur: false, blurColor: "", gradient: false)))
    }

    func testBlurKeepsItsValues() {
        let merge = GGEdgeMerge.merged(GGEdgeMerge.Old(blur: true, blurColor: "112233", blurSize: 120.0, blurIntensity: 60.0, gradientColor: "445566", gradientSize: 30.0))
        XCTAssertEqual(merge, GGEdgeMerge(style: .blur, color: "112233", size: 120.0, intensity: 60.0))
    }

    func testBlurWithDefaultsKeepsTheOldBlurHeight() {
        XCTAssertEqual(GGEdgeMerge.merged(GGEdgeMerge.Old(blur: true)), GGEdgeMerge(style: .blur, size: 80.0))
    }

    func testGradientKeepsItsOldDefaultHeight() {
        // The gradient was 40 pt by default; the group's default is 80, so 40 is written.
        let merge = GGEdgeMerge.merged(GGEdgeMerge.Old(blurSize: 100.0, gradient: true, gradientHideInChatList: true))
        XCTAssertEqual(merge, GGEdgeMerge(style: .gradient, size: 40.0, hideInChatList: true))
    }

    func testBothOnPicksTheBlur() {
        let merge = GGEdgeMerge.merged(GGEdgeMerge.Old(blur: true, blurIntensity: 70.0, gradient: true, gradientColor: "AABBCC", gradientSize: 20.0, gradientIntensity: 30.0))
        XCTAssertEqual(merge?.style, .blur)
        XCTAssertNil(merge?.color)
        XCTAssertEqual(merge?.size, 80.0)
        XCTAssertEqual(merge?.intensity, 70.0)
    }

    func testBothOffKeepsTunedValuesBlurFirst() {
        let merge = GGEdgeMerge.merged(GGEdgeMerge.Old(blur: false, blurSize: 64.0, gradient: false, gradientColor: "AABBCC", gradientSize: 20.0, gradientIntensity: 30.0))
        XCTAssertEqual(merge, GGEdgeMerge(style: .off, color: "AABBCC", size: 64.0, intensity: 30.0))
    }

    func testValuesAreClamped() {
        let merge = GGEdgeMerge.merged(GGEdgeMerge.Old(blur: true, blurSize: 500.0, blurIntensity: -5.0))
        XCTAssertEqual(merge?.size, GGEdgeStyle.sizeRange.upperBound)
        XCTAssertEqual(merge?.intensity, 0.0)
        XCTAssertEqual(GGEdgeMerge.merged(GGEdgeMerge.Old(gradient: true, gradientSize: 1.0))?.size, GGEdgeStyle.sizeRange.lowerBound)
    }
}
