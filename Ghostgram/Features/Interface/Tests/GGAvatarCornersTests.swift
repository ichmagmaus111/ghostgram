import Foundation
import XCTest

// Host tests of «Скругление углов» (one setting since 2026-10-27), compiled together with
// Sources/Settings/GGAvatarCorners.swift only.
// Run: ./build-input/bazel-9.2.0-darwin-arm64 test //Ghostgram/Features/Interface:GGAvatarCornersTests

final class GGAvatarCornersTests: XCTestCase {
    func testShape() {
        XCTAssertFalse(GGAvatarCorners.isSquare(GGAvatarCorners.round))
        XCTAssertEqual(GGAvatarCorners.squareness("0"), 0.0)
        XCTAssertEqual(GGAvatarCorners.squareness("50"), 0.5)
        XCTAssertEqual(GGAvatarCorners.squareness("100"), 1.0)
        XCTAssertTrue(GGAvatarCorners.isSquare("25"))
        // Garbage and out-of-range values never break the shape.
        XCTAssertEqual(GGAvatarCorners.squareness("square"), 0.0)
        XCTAssertEqual(GGAvatarCorners.squareness("250"), 1.0)
        XCTAssertEqual(GGAvatarCorners.squareness("-5"), 0.0)
    }

    func testOptionsStartWithTheCircleAndEndWithTheSquare() {
        XCTAssertEqual(GGAvatarCorners.options.first, GGAvatarCorners.round)
        XCTAssertEqual(GGAvatarCorners.options.last, "100")
    }

    func testMergeOfBuild185() {
        // Off or never touched: the circle (the default), nothing to write.
        XCTAssertNil(GGAvatarCorners.merged(square: nil, squareness: nil))
        XCTAssertNil(GGAvatarCorners.merged(square: false, squareness: "50"))
        XCTAssertNil(GGAvatarCorners.merged(square: nil, squareness: "25"))
        // On: the level, absent = the old default 100.
        XCTAssertEqual(GGAvatarCorners.merged(square: true, squareness: nil), "100")
        XCTAssertEqual(GGAvatarCorners.merged(square: true, squareness: "50"), "50")
        XCTAssertEqual(GGAvatarCorners.merged(square: true, squareness: "75"), "75")
        // An odd stored value goes to the nearest level, never to the circle.
        XCTAssertEqual(GGAvatarCorners.merged(square: true, squareness: "0"), "25")
        XCTAssertEqual(GGAvatarCorners.merged(square: true, squareness: "x"), "100")
    }

    func testOldGhostgram() {
        XCTAssertNil(GGAvatarCorners.fromLegacy(square: nil, level: 50))
        XCTAssertNil(GGAvatarCorners.fromLegacy(square: false, level: 100))
        XCTAssertEqual(GGAvatarCorners.fromLegacy(square: true, level: nil), "100")
        XCTAssertEqual(GGAvatarCorners.fromLegacy(square: true, level: 40), "50")
        XCTAssertEqual(GGAvatarCorners.fromLegacy(square: true, level: 10), "25")
        XCTAssertEqual(GGAvatarCorners.fromLegacy(square: true, level: 90), "100")
    }
}
