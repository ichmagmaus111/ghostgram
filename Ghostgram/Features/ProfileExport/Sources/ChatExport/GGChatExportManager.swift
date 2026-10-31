import Foundation
import UIKit
import LocalAuthentication
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ZipArchive
import GGCore

// One export at a time. The manager owns the running job, keeps the app alive while it works
// (`beginBackgroundTask`), lists the jobs left on disk (to continue or delete), and removes temporary
// trees: a finished export is deleted once it has been saved or shared, abandoned ones after a week.

final class GGChatExportManager {
    static let shared = GGChatExportManager()

    private static let staleFinishedAge: Double = 24.0 * 60.0 * 60.0
    private static let staleAnyAge: Double = 7.0 * 24.0 * 60.0 * 60.0

    private let ioQueue = Queue(name: "org.ghostgram.chatExport.io", qos: .utility)

    // Main thread only.
    private(set) var current: GGChatExportJob?
    private let currentProgress = ValuePromise<GGChatExportProgress?>(nil, ignoreRepeated: true)
    private let progressDisposable = MetaDisposable()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let changesPipe = ValuePipe<Void>()

    private init() {
    }

    /// The running (or just finished) job's progress, on the main thread.
    var progress: Signal<GGChatExportProgress?, NoError> {
        return self.currentProgress.get()
    }

    /// Jobs on disk changed (started, finished, deleted).
    var changes: Signal<Void, NoError> {
        return .single(Void()) |> then(self.changesPipe.signal())
    }

    // MARK: - Starting

    static func environment(context: AccountContext) -> GGChatExportEnvironment {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        return GGChatExportEnvironment(accountPeerId: context.account.peerId, strings: presentationData.strings, nameDisplayOrder: presentationData.nameDisplayOrder, dateTimeFormat: presentationData.dateTimeFormat)
    }

    /// Starts a new export. False when one is already running.
    func start(context: AccountContext, mode: GGChatExportMode, title: String) -> Bool {
        assert(Thread.isMainThread)
        if let current = self.current, self.isRunning(current) {
            return false
        }
        guard let root = GGChatExportJob.rootDirectory else {
            return false
        }
        let id = UUID().uuidString
        let directory = root.appendingPathComponent(id, isDirectory: true)
        guard GGProfileExportPaths.ensureDirectory(directory, excludeFromBackup: true) else {
            return false
        }
        let journal = GGChatExportJob.makeJournal(id: id, accountId: context.account.id.int64, mode: mode, options: GGChatExportSettings.currentOptions(), title: title)
        self.run(GGChatExportJob(context: context, journal: journal, directory: directory, environment: GGChatExportManager.environment(context: context)))
        return true
    }

    /// Continues a job left on disk (the app was closed, the disk was full, …).
    func resume(context: AccountContext, journal: GGChatExportJournal) -> Bool {
        assert(Thread.isMainThread)
        if let current = self.current, self.isRunning(current) {
            return false
        }
        guard let root = GGChatExportJob.rootDirectory, journal.accountId == context.account.id.int64 else {
            return false
        }
        let directory = root.appendingPathComponent(journal.id, isDirectory: true)
        self.run(GGChatExportJob(context: context, journal: journal, directory: directory, environment: GGChatExportManager.environment(context: context)))
        return true
    }

    private var lastProgress: GGChatExportProgress?

    /// An export is running now.
    var isBusy: Bool {
        guard let current = self.current else {
            return false
        }
        return self.isRunning(current)
    }

    private func isRunning(_ job: GGChatExportJob) -> Bool {
        return self.lastProgress?.jobId == job.id && self.lastProgress?.isRunning == true
    }

    private func run(_ job: GGChatExportJob) {
        self.current = job
        self.beginBackgroundTask()
        self.progressDisposable.set((job.progress
        |> deliverOnMainQueue).start(next: { [weak self] progress in
            guard let self = self else {
                return
            }
            self.lastProgress = progress
            self.currentProgress.set(progress)
            if !progress.isRunning {
                self.endBackgroundTask()
                self.changesPipe.putNext(Void())
            }
        }))
        job.start()
        self.changesPipe.putNext(Void())
    }

    /// Continues the current job after it stopped (no space, a write error).
    func retry() {
        assert(Thread.isMainThread)
        guard let job = self.current else {
            return
        }
        self.beginBackgroundTask()
        job.start()
    }

    /// Stops the running job and deletes what it wrote.
    func cancel() {
        assert(Thread.isMainThread)
        guard let job = self.current else {
            return
        }
        self.current = nil
        self.lastProgress = nil
        self.progressDisposable.set(nil)
        self.currentProgress.set(nil)
        self.endBackgroundTask()
        job.cancel(completion: { [weak self] in
            self?.changesPipe.putNext(Void())
        })
    }

    /// Deletes a job's folder (a finished export after it was saved, an abandoned one).
    func discard(jobId: String) {
        assert(Thread.isMainThread)
        if let job = self.current, job.id == jobId {
            if self.isRunning(job) {
                self.cancel()
                return
            }
            self.current = nil
            self.lastProgress = nil
            self.progressDisposable.set(nil)
            self.currentProgress.set(nil)
        }
        guard let root = GGChatExportJob.rootDirectory else {
            return
        }
        let directory = root.appendingPathComponent(jobId, isDirectory: true)
        self.ioQueue.async {
            try? FileManager.default.removeItem(at: directory)
            Queue.mainQueue().async {
                self.changesPipe.putNext(Void())
            }
        }
    }

    private func beginBackgroundTask() {
        if self.backgroundTask != .invalid {
            return
        }
        self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ghostgram.chatExport", expirationHandler: { [weak self] in
            // The system wants the app suspended: the job continues on return, or from its journal.
            self?.endBackgroundTask()
        })
    }

    private func endBackgroundTask() {
        if self.backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }

    // MARK: - Jobs on disk

    /// Journals of this account's jobs that are not running (to continue or delete), newest first.
    func storedJobs(accountId: Int64) -> Signal<[GGChatExportJournal], NoError> {
        let read = Signal<[GGChatExportJournal], NoError> { subscriber in
            var result: [GGChatExportJournal] = []
            if let root = GGChatExportJob.rootDirectory, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
                for name in names {
                    let url = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("job.json")
                    if let data = try? Data(contentsOf: url), let journal = try? JSONDecoder().decode(GGChatExportJournal.self, from: data), journal.accountId == accountId {
                        result.append(journal)
                    }
                }
            }
            subscriber.putNext(result.sorted(by: { $0.createdAt > $1.createdAt }))
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(self.ioQueue)
        return self.changes
        |> mapToSignal { _ -> Signal<[GGChatExportJournal], NoError> in
            return read
        }
        |> deliverOnMainQueue
        |> map { [weak self] journals -> [GGChatExportJournal] in
            guard let self = self, let current = self.current, self.isRunning(current) else {
                return journals
            }
            return journals.filter { $0.id != current.id }
        }
    }

    /// At launch, off the main thread: finished exports older than a day and anything older than a
    /// week are deleted, so temporary trees never pile up.
    func removeStaleJobs() {
        self.ioQueue.async {
            guard let root = GGChatExportJob.rootDirectory, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
                return
            }
            let now = Date().timeIntervalSince1970
            for name in names {
                let directory = root.appendingPathComponent(name, isDirectory: true)
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("job.json")), let journal = try? JSONDecoder().decode(GGChatExportJournal.self, from: data) else {
                    try? FileManager.default.removeItem(at: directory)
                    continue
                }
                let age = now - Double(journal.createdAt)
                if (journal.stage == .finished && age > GGChatExportManager.staleFinishedAge) || age > GGChatExportManager.staleAnyAge {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
        }
    }

    // MARK: - Archive

    private static let storedExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "mp4", "mov", "webm", "ogg", "oga", "mp3", "m4a", "tgs", "zip"]

    /// The regular files of a finished tree with their names in the archive: `<folder>/<path inside>`,
    /// so the archive unpacks into the same tree (`ChatExport_<date>/messages.html`, `photos/…`,
    /// `css/…`). The names are the enumerator's own relative paths — never a prefix cut off an
    /// absolute path: the tree's URL says `/var/mobile/…` while a URL enumerator answers
    /// `/private/var/mobile/…`, which made every file land flat in the archive's root (the account
    /// export: one `messages.html` per chat, all under the same name).
    static func archiveEntries(folder: URL) -> [(url: URL, name: String)] {
        guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else {
            return []
        }
        let root = folder.lastPathComponent
        var result: [(url: URL, name: String)] = []
        while let relative = enumerator.nextObject() as? String {
            guard let type = enumerator.fileAttributes?[.type] as? FileAttributeType, type == .typeRegular else {
                continue
            }
            result.append((folder.appendingPathComponent(relative), root + "/" + relative))
        }
        return result
    }

    /// Packs a finished tree into `<name>.zip` next to it, on a background queue. Media are stored
    /// without compression (they are compressed already), text is deflated. Progress 0…1; the
    /// result is the archive's URL. Disposing stops it and removes the partial archive.
    func archive(folder: URL) -> Signal<(Float, URL?), NoError> {
        return Signal { subscriber in
            let cancelled = Atomic<Bool>(value: false)
            let archiveURL = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".zip")
            self.ioQueue.async {
                try? FileManager.default.removeItem(at: archiveURL)
                let files = GGChatExportManager.archiveEntries(folder: folder)
                let archive = SSZipArchive(path: archiveURL.path)
                guard archive.open() else {
                    subscriber.putNext((1.0, nil))
                    subscriber.putCompletion()
                    return
                }
                var ok = true
                for (index, file) in files.enumerated() {
                    if cancelled.with({ $0 }) {
                        ok = false
                        break
                    }
                    let level: Int32 = GGChatExportManager.storedExtensions.contains(file.url.pathExtension.lowercased()) ? 0 : -1
                    if !archive.writeFile(atPath: file.url.path, withFileName: file.name, compressionLevel: level, password: nil, aes: false) {
                        ok = false
                        break
                    }
                    subscriber.putNext((Float(index + 1) / Float(max(1, files.count)), nil))
                }
                let closed = archive.close()
                if ok && closed {
                    subscriber.putNext((1.0, archiveURL))
                } else {
                    try? FileManager.default.removeItem(at: archiveURL)
                    subscriber.putNext((1.0, nil))
                }
                subscriber.putCompletion()
            }
            return ActionDisposable {
                let _ = cancelled.swap(true)
            }
        }
    }
}

/// Face ID / Touch ID / the device passcode before any export (single chat or the whole account).
/// A device without a passcode lets the export through: there is nothing to check against.
enum GGChatExportAuth {
    static func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(true)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason, reply: { success, _ in
            DispatchQueue.main.async {
                completion(success)
            }
        })
    }
}
