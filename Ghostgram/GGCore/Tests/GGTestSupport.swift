import Foundation
import SwiftSignalKit
import XCTest

/// A fresh temporary App Group for one test; removed in `tearDown`.
final class GGTestDirectory {
    let path: String

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GGCoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        self.path = url.path
    }

    func subpath(_ components: String...) -> String {
        var result = self.path
        for component in components {
            result = (result as NSString).appendingPathComponent(component)
        }
        return result
    }

    func makeDirectory(_ components: String...) -> String {
        var result = self.path
        for component in components {
            result = (result as NSString).appendingPathComponent(component)
        }
        try? FileManager.default.createDirectory(atPath: result, withIntermediateDirectories: true, attributes: nil)
        return result
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: self.path)
    }

    func environment(process: GGProcessKind = .app) -> GGCoreEnvironment {
        return GGCoreEnvironment(appGroupPath: self.path, process: process)
    }

    var globalFilePath: String {
        return self.subpath("ghostgram", "settings", "global.json")
    }

    var sharedFilePath: String {
        return self.subpath("ghostgram", "settings", "shared.json")
    }

    func writeFile(_ path: String, _ text: String) {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// The `values` object of a settings file, or nil when the file is missing or damaged.
    func storedValues(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        return object["values"] as? [String: Any]
    }
}

/// Collects the values a signal delivers.
final class GGSignalRecorder<T> {
    private let lock = NSLock()
    private var storage: [T] = []
    private var disposable: Disposable?

    init(_ signal: Signal<T, NoError>) {
        self.disposable = signal.start(next: { [weak self] value in
            guard let self = self else {
                return
            }
            self.lock.lock()
            self.storage.append(value)
            self.lock.unlock()
        })
    }

    var values: [T] {
        self.lock.lock()
        let values = self.storage
        self.lock.unlock()
        return values
    }

    func dispose() {
        self.disposable?.dispose()
        self.disposable = nil
    }
}
