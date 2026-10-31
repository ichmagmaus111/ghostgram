import Foundation
import SwiftSignalKit
import XCTest

final class GGForegroundTaskSchedulerTests: XCTestCase {
    private var time: Double = 1_000_000.0
    private var scheduled: [(Double, () -> Void)] = []
    private var lastRuns: [String: Double] = [:]

    private func makeScheduler() -> GGForegroundTaskScheduler {
        return GGForegroundTaskScheduler(
            now: { [unowned self] in
                return self.time
            },
            schedule: { [unowned self] delay, action in
                self.scheduled.append((delay, action))
            },
            readLastRun: { [unowned self] id in
                return self.lastRuns[id]
            },
            writeLastRun: { [unowned self] id, time in
                self.lastRuns[id] = time
            }
        )
    }

    private func runScheduled() {
        let actions = self.scheduled
        self.scheduled = []
        for (_, action) in actions {
            action()
        }
    }

    /// `done` hops to the main queue; let it run.
    private func drainMainQueue() {
        let drained = self.expectation(description: "main queue")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        self.wait(for: [drained], timeout: 2.0)
    }

    func testDueTaskRunsAfterItsDelayAndIsThrottled() {
        let scheduler = self.makeScheduler()
        var starts = 0
        scheduler.register(id: "a", minimumInterval: 3600, delay: 2.0) { done in
            starts += 1
            done()
            return EmptyDisposable
        }

        scheduler.applicationDidBecomeActive()
        XCTAssertEqual(self.scheduled.map { $0.0 }, [2.0])
        XCTAssertEqual(starts, 0, "nothing runs before the delay")
        self.runScheduled()
        XCTAssertEqual(starts, 1)
        self.drainMainQueue()
        XCTAssertEqual(self.lastRuns["a"], self.time)

        scheduler.applicationWillResignActive()
        self.time += 600
        scheduler.applicationDidBecomeActive()
        XCTAssertTrue(self.scheduled.isEmpty, "not again within the interval")

        scheduler.applicationWillResignActive()
        self.time += 3600
        scheduler.applicationDidBecomeActive()
        self.runScheduled()
        XCTAssertEqual(starts, 2)
    }

    func testRepeatedBecomeActiveDoesNotDuplicate() {
        let scheduler = self.makeScheduler()
        scheduler.register(id: "a", minimumInterval: 0, delay: 0) { _ in
            return EmptyDisposable
        }
        scheduler.applicationDidBecomeActive()
        scheduler.applicationDidBecomeActive()
        XCTAssertEqual(self.scheduled.count, 1)
    }

    func testTasksAreSpreadOut() {
        let scheduler = self.makeScheduler()
        for id in ["a", "b", "c"] {
            scheduler.register(id: id, minimumInterval: 0, delay: 1.0) { _ in
                return EmptyDisposable
            }
        }
        scheduler.applicationDidBecomeActive()
        XCTAssertEqual(self.scheduled.map { $0.0 }, [1.0, 1.5, 2.0])
    }

    func testResignCancelsPendingAndRunningTasks() {
        let scheduler = self.makeScheduler()
        var startedPending = false
        scheduler.register(id: "pending", minimumInterval: 60, delay: 5.0) { _ in
            startedPending = true
            return EmptyDisposable
        }
        scheduler.applicationDidBecomeActive()
        scheduler.applicationWillResignActive()
        self.runScheduled()
        XCTAssertFalse(startedPending, "a pending task never starts after resign")

        var disposed = false
        var finish: (() -> Void)?
        scheduler.register(id: "running", minimumInterval: 60, delay: 0) { done in
            finish = done
            return ActionDisposable {
                disposed = true
            }
        }
        scheduler.applicationDidBecomeActive()
        self.runScheduled()
        XCTAssertNotNil(finish)
        scheduler.applicationWillResignActive()
        XCTAssertTrue(disposed)
        finish?()
        self.drainMainQueue()
        XCTAssertNil(self.lastRuns["running"], "an interrupted run does not count")

        scheduler.applicationDidBecomeActive()
        XCTAssertFalse(self.scheduled.isEmpty, "it is retried on the next return")
    }

    func testClockGoingBackMakesTheTaskDue() {
        let scheduler = self.makeScheduler()
        self.lastRuns["a"] = self.time + 10_000
        scheduler.register(id: "a", minimumInterval: 3600, delay: 0) { _ in
            return EmptyDisposable
        }
        scheduler.applicationDidBecomeActive()
        XCTAssertEqual(self.scheduled.count, 1)
    }
}
