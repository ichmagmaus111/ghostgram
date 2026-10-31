// The attributed text of a text bubble after entities are applied and before layout (color
// swatches after hex colors…). Call site: ChatMessageTextBubbleContentNode, for every layout of a
// text bubble: handlers cache their own work per message version.

import Foundation
import UIKit
import Postbox
import TelegramCore
import AccountContext
import GGCore

public struct GGMessageTextContext {
    public let message: Message
    public let context: AccountContext
}

public enum GGMessageTextHooks {
    /// Transformer of the attributed text of a text bubble. Return the same object when nothing applies.
    public static let attributedText = GGHookPoint<(NSAttributedString, GGMessageTextContext) -> NSAttributedString>("messageText.attributedText")

    public static func attributedText(_ text: NSAttributedString, message: Message, context: AccountContext) -> NSAttributedString {
        if GGMessageTextHooks.attributedText.isEmpty {
            return text
        }
        let textContext = GGMessageTextContext(message: message, context: context)
        var result = text
        for handler in GGMessageTextHooks.attributedText.handlers {
            result = handler(result, textContext)
        }
        return result
    }
}
