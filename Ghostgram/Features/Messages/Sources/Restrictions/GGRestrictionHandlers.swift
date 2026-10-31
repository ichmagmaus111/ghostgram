import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import GGCore
import GGHooks
import GGFeaturesShared

/// «Обходы ограничений»: every predicate is answered once at its source point (copy protection,
/// platform restrictions, capture protection, screenshot notices, sponsored messages, content
/// consumption), so all screens that ask the same question get the same answer. Each handler is a
/// snapshot read; with the toggle off it answers nil and upstream decides.
enum GGRestrictionHandlers {
    static func register() {
        GGRestrictionHooks.copyProtection.register({ subject in
            return GGRestrictionHandlers.copyProtection(subject)
        })
        GGStoryHooks.forwardingDisabled.register({ _ in
            return GGMessagesSettings.copyProtectionBypass.value ? false : nil
        })

        // Forced protection (a feature that hides a chat from screenshots) registers with a lower
        // order and wins; this one only lifts what the server imposed.
        GGChatScreenHooks.captureProtection.register({ request in
            if request.upstreamValue && GGMessagesSettings.screenshotBypass.value {
                return false
            }
            return nil
        }, order: 900)
        GGRestrictionHooks.reportScreenshot.register({ _ in
            return GGMessagesSettings.screenshotBypass.value ? false : nil
        })
        // A screenshot in the viewer of kept view-once / timer media tells the sender that it was
        // opened: with «Не сжигать» the sender learns that only from «Отметить открытым».
        GGRestrictionHooks.reportMediaScreenshot.register({ message in
            if GGMessagesSettings.keepSelfDestructingMedia.value && GGRestrictionHandlers.isSelfDestructing(message) {
                return false
            }
            return nil
        })

        // View-once / timer media: not consumed at all — no "opened" flag, no countdown, nothing
        // sent to the other side (the explicit «Прочитать» of the ghost mode is a separate action).
        GGPresenceHooks.consumeContent.register({ request in
            guard GGMessagesSettings.keepSelfDestructingMedia.value else {
                return nil
            }
            return GGRestrictionHandlers.isSelfDestructing(request.message) ? false : nil
        })
        // …and shown as ordinary media, as the old client did: no blur, the regular gallery, save
        // and forward (a forward goes as a copy, GGForwardCopy — the server refuses to forward
        // self-destructing media). Asked only for self-destructing media; the fire mark beside the
        // time (GGMessageDecorations) still tells it apart.
        GGRestrictionHooks.secretMediaDisplay.register({ _ in
            return GGMessagesSettings.keepSelfDestructingMedia.value ? false : nil
        })
        // Forwards the server refuses (protected content with the bypass, kept self-destructing media)
        // go as copies on every path: the share sheet of a channel post, profile media, search, the
        // forward panel. The chat's own forward flow converts before it gets here (with its alerts).
        GGOutgoingHooks.forwardCopies.register({ account, messages in
            return GGRestrictionHandlers.forwardCopies(account: account, messages: messages)
        })

        GGChatScreenHooks.showsAdMessages.register({ _, _ in
            return GGMessagesSettings.blockAds.value ? false : nil
        })

        GGRestrictionHooks.peerRestriction.register({ _ in
            return GGMessagesSettings.contentRestrictionsBypass.value ? false : nil
        })
        GGRestrictionHooks.messageRestriction.register({ _ in
            return GGMessagesSettings.contentRestrictionsBypass.value ? false : nil
        })
    }

    /// nil when no setting can make a forward a copy; otherwise the batch with the forwards that need it
    /// replaced by copies (`GGForwardCopy`), the others as they are.
    static func forwardCopies(account: Account, messages: [EnqueueMessage]) -> Signal<[EnqueueMessage], NoError>? {
        guard GGMessagesSettings.copyProtectionBypass.value || GGMessagesSettings.keepSelfDestructingMedia.value else {
            return nil
        }
        var sourceIds: [MessageId] = []
        var options: ForwardOptionsMessageAttribute?
        for message in messages {
            if case let .forward(source, _, _, attributes, _) = message {
                sourceIds.append(source)
                if options == nil {
                    options = attributes.first(where: { $0 is ForwardOptionsMessageAttribute }) as? ForwardOptionsMessageAttribute
                }
            }
        }
        if sourceIds.isEmpty {
            return nil
        }
        let hideNames = options?.hideNames ?? false
        let hideCaptions = options?.hideCaptions ?? false
        return account.postbox.transaction { transaction -> [Message] in
            return sourceIds.compactMap { transaction.getMessage($0) }
        }
        |> mapToSignal { sources -> Signal<[EnqueueMessage], NoError> in
            guard GGForwardCopy.needsCopy(sources) else {
                return .single(messages)
            }
            return GGForwardCopy.convert(messages, sources: sources, account: account, hideNames: hideNames, hideCaptions: hideCaptions)
            |> map { result -> [EnqueueMessage] in
                return result.messages
            }
        }
    }

    static func copyProtection(_ subject: GGCopyProtectionSubject) -> Bool? {
        guard GGMessagesSettings.copyProtectionBypass.value else {
            return nil
        }
        // Admins and owners too: their settings screens read the raw flag
        // (`ChannelVisibilityController`), so the bypass never hides the real state there.
        switch subject {
        case .peer, .message, .peerData:
            return false
        }
    }

    /// View-once and short-timer media — photo, video, voice, round video — in cloud and secret
    /// chats (`containsSecretMedia`: a timer of a minute or less, or view once). Long chat-wide
    /// timers of secret chats are not «исчезающие медиа» and keep working. The raw answer: with
    /// the toggle on, `containsSecretMedia` itself says false (`secretMediaDisplay` above).
    static func isSelfDestructing(_ message: Message) -> Bool {
        return message.ggRawContainsSecretMedia
    }
}
