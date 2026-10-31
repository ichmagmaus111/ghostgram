import Foundation
import TelegramCore
import GGCore

/// The part of GGMessages that the extensions (notification service, share) also link: settings with
/// `.extensions`, NSE handlers, attribute declarations. Owner: W2-3.
public enum GGMessagesShared {
    /// Called from `GGFeaturesShared.registerForApp()` and `.registerForExtension()`; check
    /// `GGCore.environment?.process` for what only one of them needs.
    public static func register() {
        GGMessagesSettings.declare()
        // The verbatim marker can reach Postbox on paths that skip the outgoing transformer: every
        // process that opens an account must be able to decode it.
        GGMessageAttributeHooks.declareEncodables.register({
            ggDeclareMessagesEncodables()
        })
        // SG-H1 (pinned / mention pushes): the decision is `GGNotificationFilter.decision`.
        GGNotificationServiceHooks.content.register({ content, context in
            guard let mode = GGNotificationFilter.decision(isPinnedMessage: context.isPinnedMessage, isMentionOrReply: context.isMentionOrReply, accountId: context.accountId, peerId: context.peerId) else {
                return
            }
            switch mode {
            case .disabled:
                content.isHidden = true
            case .silent:
                content.isSilent = true
            case .standard:
                break
            }
        })
    }
}
