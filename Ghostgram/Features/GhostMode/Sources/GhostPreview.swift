import Foundation
import UIKit
import GGCore
import GGSettingsUI
import GGFeaturesShared

/// The «Приватность» preview: a mini chat as the other person sees you. The header is your own
/// avatar with «в сети» / «был(а) недавно»; while ghost mode keeps your read receipt their message
/// stays at one check (no mark by the time — the owner had it removed). It follows the switches of
/// the account the menu is open for.
enum GGGhostPreview {
    static func register() {
        GGMenuRegistry.register(GGMenuRow(
            id: "ghostMode.preview",
            section: .privacyPreview,
            order: 100,
            title: { "" },
            kind: .preview(.miniChat(GGMiniChatConfiguration(scope: "ghostMode", height: 196.0, content: { context in
                let account = context.accountID
                let hidesOnline = GGGhostPolicy.isFunctionOn(.online, account: account)
                let hidesReads = GGGhostPolicy.isFunctionOn(.readReceipts, account: account)
                let status: String
                let statusIsAccent: Bool
                if hidesOnline {
                    status = GGStrings.GhostMode.Preview.recently
                    statusIsAccent = false
                } else {
                    status = GGStrings.GhostMode.Preview.online
                    statusIsAccent = true
                }
                var question = GGPreviewMessage(id: 1, isOutgoing: true, text: GGStrings.GhostMode.Preview.question, ageSeconds: 240)
                if hidesReads {
                    question.isUnread = true
                }
                var messages = [question]
                if !hidesReads {
                    messages.append(GGPreviewMessage(id: 2, isOutgoing: false, text: GGStrings.GhostMode.Preview.answer, ageSeconds: 120))
                }
                return GGMiniChatContent(header: GGMiniChatHeader(peer: .account, status: status, statusIsAccent: statusIsAccent), messages: messages)
            })))
        ))
    }
}
