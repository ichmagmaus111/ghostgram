import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TopMessageReactions
import GGCore

/// «Свои недавние реакции» (custom_recent_reactions): the reaction panel of a message starts with
/// the user's own ordered set (builtin emoji and custom emoji), optionally followed by Telegram's
/// own top reactions. Channels keep Telegram's list. Custom emoji files are resolved once and kept
/// in memory, not on every build of the panel.
enum GGCustomReactions {
    /// The Android plugin's default set: 👍 👎 ❤ 🔥 🥳 😱 😢 (builtin reactions are stored without
    /// U+FE0F, as Telegram stores `MessageReaction.Reaction.builtin`).
    static let defaultList: [String] = ["e:\u{1F44D}", "e:\u{1F44E}", "e:\u{2764}", "e:\u{1F525}", "e:\u{1F973}", "e:\u{1F631}", "e:\u{1F622}"]

    /// Resolved custom emoji files by id (any thread).
    private static let files = Atomic<[Int64: TelegramMediaFile]>(value: [:])

    enum Entry: Equatable {
        case builtin(String)
        case custom(Int64)

        var stringValue: String {
            switch self {
            case let .builtin(value):
                return "e:" + value
            case let .custom(id):
                return "doc:\(id)"
            }
        }

        init?(_ string: String) {
            if string.hasPrefix("e:") {
                let value = String(string.dropFirst(2)).replacingOccurrences(of: "\u{FE0F}", with: "")
                if value.isEmpty {
                    return nil
                }
                self = .builtin(value)
            } else if string.hasPrefix("doc:"), let id = Int64(string.dropFirst(4)) {
                self = .custom(id)
            } else {
                return nil
            }
        }
    }

    /// Valid entries once each, in order.
    static func normalized(_ items: [String]) -> [String] {
        var result: [String] = []
        for item in items {
            guard let entry = Entry(item) else {
                continue
            }
            let value = entry.stringValue
            if !result.contains(value) {
                result.append(value)
            }
        }
        return result
    }

    static var entries: [Entry] {
        return InterfaceSettings.customReactionsList.value.compactMap(Entry.init)
    }

    static func register() {
        GGRecentReactionsHooks.topReactions.register({ signal, context, message in
            guard InterfaceSettings.customReactions.value else {
                return signal
            }
            if let channel = message.peers[message.id.peerId] as? TelegramChannel, case .broadcast = channel.info {
                return signal
            }
            let entries = GGCustomReactions.entries
            if entries.isEmpty {
                return signal
            }
            let appendStandard = InterfaceSettings.customReactionsAppendStandard.value
            return combineLatest(signal, GGCustomReactions.resolvedFiles(context: context, entries: entries))
            |> map { upstream, files -> [RecentReactionItem] in
                var result: [RecentReactionItem] = []
                for entry in entries {
                    switch entry {
                    case let .builtin(value):
                        result.append(RecentReactionItem(.builtin(value)))
                    case let .custom(id):
                        if let file = files[id] {
                            result.append(RecentReactionItem(.custom(TelegramMediaFile.Accessor(file))))
                        }
                    }
                }
                if appendStandard {
                    let existing = Set(result.map { $0.id.id })
                    for item in upstream where !existing.contains(item.id.id) {
                        result.append(item)
                    }
                }
                return result
            }
        })
    }

    /// The files of the custom entries: cached ones at once, the rest resolved (once) through
    /// Telegram's inline sticker resolver.
    static func resolvedFiles(context: AccountContext, entries: [Entry]) -> Signal<[Int64: TelegramMediaFile], NoError> {
        let ids = entries.compactMap { entry -> Int64? in
            if case let .custom(id) = entry {
                return id
            }
            return nil
        }
        if ids.isEmpty {
            return .single([:])
        }
        let cached = GGCustomReactions.files.with { $0 }
        let missing = ids.filter { cached[$0] == nil }
        if missing.isEmpty {
            return .single(cached)
        }
        return .single(cached)
        |> then(context.engine.stickers.resolveInlineStickers(fileIds: missing)
        |> map { resolved -> [Int64: TelegramMediaFile] in
            return GGCustomReactions.files.modify { current in
                var updated = current
                for (id, file) in resolved {
                    updated[id] = file
                }
                return updated
            }
        })
    }

    /// Remembers files the editor already has (no network round trip later).
    static func remember(_ file: TelegramMediaFile) {
        let _ = GGCustomReactions.files.modify { current in
            var updated = current
            updated[file.fileId.id] = file
            return updated
        }
    }
}
