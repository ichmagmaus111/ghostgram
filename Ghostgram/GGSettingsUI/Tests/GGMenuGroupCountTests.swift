import Foundation
import XCTest

// Host tests of the summary on an expandable row without a master switch (2026-10-27), compiled
// together with Sources/Model/GGMenuGroupCount.swift only.
// Run: ./build-input/bazel-9.2.0-darwin-arm64 test //Ghostgram/GGSettingsUI:GGSettingsUIModelTests

final class GGMenuGroupCountTests: XCTestCase {
    private func hidden(_ count: GGMenuGroupCount) -> String {
        return "скрыто: \(count.selected) из \(count.total)"
    }

    func testCountsTheVisibleChildren() {
        XCTAssertEqual(GGMenuGroupCount(values: [true, false, true, false]), GGMenuGroupCount(selected: 2, total: 4))
        XCTAssertEqual(GGMenuGroupCount(values: [false, false, false, false]), GGMenuGroupCount(selected: 0, total: 4))
        XCTAssertEqual(GGMenuGroupCount(values: [true, true, true, true]), GGMenuGroupCount(selected: 4, total: 4))
        XCTAssertEqual(GGMenuGroupCount(values: []), GGMenuGroupCount(selected: 0, total: 0))
    }

    func testNothingOnShowsNothing() {
        var calls = 0
        let summary = GGMenuGroupCount(values: [false, false, false, false]).summary { count in
            calls += 1
            return self.hidden(count)
        }
        XCTAssertNil(summary)
        // The feature's text is not even built.
        XCTAssertEqual(calls, 0)
        XCTAssertNil(GGMenuGroupCount(values: []).summary(self.hidden))
    }

    func testSummaryOfWhatIsOn() {
        XCTAssertEqual(GGMenuGroupCount(values: [true, false, true, false]).summary(self.hidden), "скрыто: 2 из 4")
        XCTAssertEqual(GGMenuGroupCount(values: [false, false, false, true]).summary(self.hidden), "скрыто: 1 из 4")
        XCTAssertEqual(GGMenuGroupCount(values: [true, true, true, true]).summary(self.hidden), "скрыто: 4 из 4")
    }
}
