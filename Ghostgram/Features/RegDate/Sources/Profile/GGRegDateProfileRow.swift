import Foundation
import UIKit
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext
import UndoUI
import GGCore
import GGHooks

/// «Дата регистрации» in the info section of every user's and bot's profile, the own profile too
/// (that is where the ID row is; the Settings tab has no info rows). The value follows `precision` and
/// `source`, the account's age is on the right, a long press copies it; a tap does nothing, like the
/// ID row (owner, build 201: the explanation alert went). Off (`regDate.show`): no row, no work, no request.
enum GGRegDateProfileRow {
    static func register() {
        // After the ID / data center / dates of GGProfileDecor (order 100).
        GGPeerInfoHooks.infoRows.register({ info in
            return GGRegDateProfileRow.rows(info)
        }, order: 110)
    }

    /// Asked on every layout of the profile: memory and snapshots only (GGRegDate).
    private static func rows(_ info: GGPeerInfoContext) -> [GGPeerInfoRow] {
        if !GGRegDateSettings.show.value {
            return []
        }
        // A secret chat's profile describes the user too.
        guard case let .user(user) = info.peer else {
            return []
        }
        let context = info.context
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        guard let row = GGRegDate.shared.row(context: context, peerId: user.id, cachedData: info.cachedData, sourceMessageId: info.sourceMessageId, sourceChatPeerId: info.sourceChatPeerId, controller: info.controller, strings: presentationData.strings) else {
            return []
        }
        let copyText = row.texts.copy
        return [GGPeerInfoRow(id: "regDate.profile", label: GGStrings.RegDate.Profile.label, text: row.texts.value, rightLabel: row.texts.age, longTapAction: { [weak controller = info.controller] in
            GGRegDateProfileRow.copy(copyText, context: context, controller: controller)
        })]
    }

    private static func copy(_ text: String, context: AccountContext, controller: ViewController?) {
        UIPasteboard.general.string = text
        guard let controller else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller.present(UndoOverlayController(presentationData: presentationData, content: .copy(text: GGStrings.RegDate.Profile.copied), elevatedLayout: false, animateInAsReplacement: false, action: { _ in
            return false
        }), in: .current)
    }
}
