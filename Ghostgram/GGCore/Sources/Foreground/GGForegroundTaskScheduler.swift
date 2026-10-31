import Foundation
import SwiftSignalKit

/// Background work that runs when the app comes back to the foreground, never more often than its
/// interval and never in the background.
///
///     GGForegroundTaskScheduler.shared.register(id: "masks.catalog", minimumInterval: 6 * 60 * 60) { done in
///         return GGNetwork.shared.fetch(request).start(next: { ... }, error: { _ in done() }, completed: done)
///     }
///
/// On `applicationDidBecomeActive` every due task is started after its `delay`, and tasks are
/// spread 0.5 s apart. `done` marks the run as finished (the interval counts from then; the time is
/// kept across launches). `applicationWillResignActive` cancels pending tasks and disposes running
/// ones: an unfinished run does not count, so it is retried on the next return. Main thread only.
public final class GGForegroundTaskScheduler {
    public static let shared = GGForegroundTaskScheduler()

    static let lastRunSetting = GGSetting<[String: Double]>("core.foregroundTasks.lastRun", default: [:], flags: [.noExport])
    static let stagger: Double = 0.5

    private final class TaskEntry {
        enum State {
            case idle
            case pending
            case running
        }

        let id: String
        let minimumInterval: Double
        let delay: Double
        let task: (@escaping () -> Void) -> Disposable
        var state: State = .idle
        var generation: Int = 0
        var disposable: Disposable?

        init(id: String, minimumInterval: Double, delay: Double, task: @escaping (@escaping () -> Void) -> Disposable) {
            self.id = id
            self.minimumInterval = minimumInterval
            self.delay = delay
            self.task = task
        }
    }

    private let now: () -> Double
    private let schedule: (Double, @escaping () -> Void) -> Void
    private let readLastRun: (String) -> Double?
    private let writeLastRun: (String, Double) -> Void

    private var tasks: [TaskEntry] = []
    private var isActive = false
    private var generation = 0

    private convenience init() {
        self.init(
            now: {
                return Date().timeIntervalSince1970
            },
            schedule: { delay, action in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
            },
            readLastRun: { id in
                return GGForegroundTaskScheduler.lastRunSetting.value[id]
            },
            writeLastRun: { id, time in
                var values = GGForegroundTaskScheduler.lastRunSetting.value
                values[id] = time
                GGForegroundTaskScheduler.lastRunSetting.set(values)
            }
        )
    }

    init(now: @escaping () -> Double, schedule: @escaping (Double, @escaping () -> Void) -> Void, readLastRun: @escaping (String) -> Double?, writeLastRun: @escaping (String, Double) -> Void) {
        self.now = now
        self.schedule = schedule
        self.readLastRun = readLastRun
        self.writeLastRun = writeLastRun
    }

    /// `minimumInterval` — not more often than this, in seconds (kept across launches);
    /// `delay` — seconds after becoming active before the task starts.
    public func register(id: String, minimumInterval: Double, delay: Double = 2.0, task: @escaping (_ done: @escaping () -> Void) -> Disposable) {
        assert(Thread.isMainThread)
        if self.tasks.contains(where: { $0.id == id }) {
            assertionFailure("Foreground task \(id) is registered twice")
            return
        }
        self.tasks.append(TaskEntry(id: id, minimumInterval: max(0.0, minimumInterval), delay: max(0.0, delay), task: task))
    }

    public func applicationDidBecomeActive() {
        assert(Thread.isMainThread)
        if self.isActive {
            return
        }
        self.isActive = true
        self.generation += 1
        let generation = self.generation
        let now = self.now()
        var offset: Double = 0.0
        for entry in self.tasks where entry.state == .idle && self.isDue(entry, now: now) {
            entry.state = .pending
            entry.generation = generation
            self.schedule(entry.delay + offset, { [weak self, weak entry] in
                guard let strongSelf = self, let entry = entry else {
                    return
                }
                strongSelf.start(entry, generation: generation)
            })
            offset += GGForegroundTaskScheduler.stagger
        }
    }

    /// Cancels pending tasks and disposes running ones.
    public func applicationWillResignActive() {
        assert(Thread.isMainThread)
        self.isActive = false
        self.generation += 1
        for entry in self.tasks {
            switch entry.state {
            case .idle:
                break
            case .pending:
                entry.state = .idle
            case .running:
                entry.state = .idle
                let disposable = entry.disposable
                entry.disposable = nil
                disposable?.dispose()
            }
        }
    }

    private func isDue(_ entry: TaskEntry, now: Double) -> Bool {
        guard let lastRun = self.readLastRun(entry.id) else {
            return true
        }
        if lastRun > now {
            // The clock went back: do not wait for it to catch up.
            return true
        }
        return now - lastRun >= entry.minimumInterval
    }

    private func start(_ entry: TaskEntry, generation: Int) {
        guard self.isActive, entry.state == .pending, entry.generation == generation else {
            return
        }
        entry.state = .running
        let done: () -> Void = { [weak self, weak entry] in
            DispatchQueue.main.async {
                guard let strongSelf = self, let entry = entry else {
                    return
                }
                strongSelf.finish(entry, generation: generation)
            }
        }
        let disposable = entry.task(done)
        if entry.state == .running && entry.generation == generation {
            entry.disposable = disposable
        } else {
            disposable.dispose()
        }
    }

    private func finish(_ entry: TaskEntry, generation: Int) {
        guard entry.state == .running, entry.generation == generation else {
            return
        }
        entry.state = .idle
        entry.disposable = nil
        self.writeLastRun(entry.id, self.now())
    }
}
