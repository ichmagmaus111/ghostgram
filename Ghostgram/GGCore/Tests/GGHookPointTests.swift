import Foundation
import XCTest

final class GGHookPointTests: XCTestCase {
    override func tearDown() {
        GGHookRegistry.unfreezeForTesting()
        super.tearDown()
    }

    func testEmptyPoint() {
        let point = GGHookPoint<(Int) -> Int>("test.empty")
        XCTAssertTrue(point.isEmpty)
        XCTAssertTrue(point.handlers.isEmpty)
    }

    func testHandlersRunInOrderThenRegistrationOrder() {
        let point = GGHookPoint<(String) -> String>("test.order")
        point.register({ $0 + "b" }, order: 10)
        point.register({ $0 + "a" }, order: -5)
        point.register({ $0 + "c" }, order: 10)
        point.register({ $0 + "z" })
        XCTAssertFalse(point.isEmpty)
        let result = point.handlers.reduce("") { text, handler in
            return handler(text)
        }
        XCTAssertEqual(result, "azbc")
    }

    func testFreezeIsVisible() {
        XCTAssertFalse(GGHookRegistry.isFrozen)
        GGHookRegistry.freeze()
        XCTAssertTrue(GGHookRegistry.isFrozen)
    }

    func testHandlersAreReadableFromOtherThreadsAfterFreeze() {
        let point = GGHookPoint<() -> Int>("test.threads")
        point.register({ 1 })
        point.register({ 2 })
        GGHookRegistry.freeze()
        let done = self.expectation(description: "background reads")
        DispatchQueue.global().async {
            var sum = 0
            for _ in 0 ..< 1000 {
                if !point.isEmpty {
                    sum += point.handlers.reduce(0) { $0 + $1() }
                }
            }
            XCTAssertEqual(sum, 3000)
            done.fulfill()
        }
        self.wait(for: [done], timeout: 5.0)
    }
}
