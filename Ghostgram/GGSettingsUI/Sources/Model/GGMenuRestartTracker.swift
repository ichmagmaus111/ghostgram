import Foundation

/// «Нужен перезапуск» without exit(0): remembers the value a `.requiresRestart` setting had in this
/// process before the menu first changed it. While the current value differs, the section shows
/// the restart footer; changing it back hides the footer again. Main thread only.
final class GGMenuRestartTracker {
    static let shared = GGMenuRestartTracker()

    private var launchValues: [String: Any] = [:]

    private init() {
    }

    func noteBeforeChange<Value: Equatable>(key: String, launchValue: Value) {
        assert(Thread.isMainThread)
        if self.launchValues[key] == nil {
            self.launchValues[key] = launchValue
        }
    }

    func differsFromLaunch<Value: Equatable>(key: String, current: Value) -> Bool {
        assert(Thread.isMainThread)
        guard let launchValue = self.launchValues[key] as? Value else {
            return false
        }
        return launchValue != current
    }
}
