import Foundation
import os
import UIKit
import SwiftSignalKit
import Display
import AccountContext

/// A lock for short, rarely contended sections (snapshot swaps). The lock word has its own
/// allocation so its address never moves.
final class GGProfileExportLock {
    private let storage: UnsafeMutablePointer<os_unfair_lock>

    init() {
        self.storage = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.storage.initialize(to: os_unfair_lock())
    }

    deinit {
        self.storage.deinitialize(count: 1)
        self.storage.deallocate()
    }

    @inline(__always)
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        os_unfair_lock_lock(self.storage)
        defer {
            os_unfair_lock_unlock(self.storage)
        }
        return try body()
    }
}

/// Where this feature keeps its own files.
enum GGProfileExportPaths {
    /// `Library/Caches/ghostgram/<name>`: data that can always be fetched again (badge table,
    /// badge pictures). Never backed up; the system may purge it.
    static func cachesDirectory(_ name: String) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("ghostgram", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// `Library/Application Support/ghostgram/<name>`: work that must survive a relaunch (export jobs).
    /// Excluded from backup.
    static func supportDirectory(_ name: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("ghostgram", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    @discardableResult
    static func ensureDirectory(_ url: URL, excludeFromBackup: Bool) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return false
        }
        if excludeFromBackup {
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableURL.setResourceValues(values)
        }
        return true
    }
}

/// The controller on top of the account's main navigation stack (for bulletins and pushes from
/// places that have no controller of their own: a badge in a list row, the chat header).
func ggProfileExportTopController(context: AccountContext) -> (NavigationController, ViewController)? {
    guard let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController else {
        return nil
    }
    guard let topController = navigationController.topViewController as? ViewController else {
        return nil
    }
    return (navigationController, topController)
}

/// t.me links go through the in-app resolver and are pushed on the given stack (`openExternalUrl`
/// would reset the stack to the chat list).
func ggProfileExportOpenTelegramLink(context: AccountContext, url: String, navigationController: NavigationController) {
    let _ = (context.sharedContext.resolveUrl(context: context, peerId: nil, url: url, skipUrlAuth: true)
    |> take(1)
    |> deliverOnMainQueue).start(next: { [weak navigationController] resolvedUrl in
        guard let navigationController = navigationController else {
            return
        }
        context.sharedContext.openResolvedUrl(
            resolvedUrl,
            context: context,
            urlContext: .generic,
            navigationController: navigationController,
            forceExternal: false,
            forceUpdate: false,
            openPeer: { [weak navigationController] peer, _ in
                guard let navigationController = navigationController else {
                    return
                }
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(
                    navigationController: navigationController,
                    context: context,
                    chatLocation: .peer(peer),
                    keepStack: .always
                ))
            },
            sendFile: nil,
            sendSticker: nil,
            sendEmoji: nil,
            requestMessageActionUrlAuth: nil,
            joinVoiceChat: nil,
            present: { [weak navigationController] controller, _ in
                (navigationController?.topViewController as? ViewController)?.present(controller, in: .window(.root))
            },
            dismissInput: {},
            contentContext: nil,
            progress: nil,
            completion: nil
        )
    })
}
