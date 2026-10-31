import Foundation
import UIKit
import TelegramCore
import AccountContext
import GGHooks
import GGFeaturesShared

/// «Показывать прежние версии под текстом»: the versions go into their own node under the text
/// of the bubble (`GGMessageDecoration.footnote`), so they are neither selected nor copied with
/// the message text and keep their own transparency.
/// Drawn by ChatMessageTextBubbleContentNode (`GGMessageFootnote`, `GGMessageDecoration.footnote`).
func ggApplyEditHistoryFootnote(_ decoration: inout GGMessageDecoration, history: GGEditHistoryMessageAttribute, context: AccountContext) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let value = GGAntiDeleteDecorations.versionsText(history, presentationData: presentationData)
    if value.text.isEmpty {
        return
    }
    let alpha = GGAntiDeleteSettings.alpha(forTransparency: GGAntiDeleteSettings.versionsTransparency.value)
    decoration.footnote = GGMessageFootnote(text: value.text, entities: value.entities, alpha: alpha)
}
