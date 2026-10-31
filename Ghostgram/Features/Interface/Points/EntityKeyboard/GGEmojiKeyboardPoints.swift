// Compiled into EntityKeyboard (filegroup //Ghostgram/Features/Interface:EntityKeyboardPointSources).
// Owner: W2-5 (SG-G9). Used by EntityKeyboard, ChatEntityKeyboardInputNode and TelegramUI's
// ChatInterfaceInputContexts (they all depend on EntityKeyboard).

import Foundation
import GGCore

public struct GGEmojiKeyboardStyle: Equatable {
    /// The keyboard opens on emoji, and the input panel's sticker button becomes the emoji one.
    public var emojiTabFirst: Bool
    /// Telegram's standard emoji come right after the recent ones, before the packs.
    public var standardEmojiFirst: Bool

    public init(emojiTabFirst: Bool, standardEmojiFirst: Bool) {
        self.emojiTabFirst = emojiTabFirst
        self.standardEmojiFirst = standardEmojiFirst
    }

    public static let upstream = GGEmojiKeyboardStyle(emojiTabFirst: false, standardEmojiFirst: false)
}

public enum GGEmojiKeyboardHooks {
    /// Provider of the style (first registered wins); asked when a keyboard is built or laid out.
    public static let style = GGHookPoint<() -> GGEmojiKeyboardStyle>("emojiKeyboard.style")
}

public func ggEmojiKeyboardStyle() -> GGEmojiKeyboardStyle {
    if GGEmojiKeyboardHooks.style.isEmpty {
        return .upstream
    }
    return GGEmojiKeyboardHooks.style.handlers[0]()
}

/// The emoji groups with the standard ("static") group moved right after "recent".
func ggStandardEmojiFirst(_ groups: [EmojiPagerContentComponent.ItemGroup]) -> [EmojiPagerContentComponent.ItemGroup] {
    guard let staticIndex = groups.firstIndex(where: { ($0.groupId.base as? String) == "static" }) else {
        return groups
    }
    var result = groups
    let staticGroup = result.remove(at: staticIndex)
    let recentIndex = result.firstIndex(where: { ($0.groupId.base as? String) == "recent" })
    result.insert(staticGroup, at: (recentIndex ?? -1) + 1)
    return result
}
