import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import AppBundle
import UndoUI
import PeerInfoUI
import TextFormat
import ChatScheduleTimeController
import GGCore
import GGHooks
import GGFeaturesShared

/// SG-G1, «Своё меню сообщения»: Telegram's own items the user turned off are taken out of the
/// menu, and Ghostgram adds «Сохранить в Избранное», «Переслать без автора» and «Ограничить».
/// There is no «Ghostgram» submenu (owner, 2026-10-29). Everything goes through
/// `GGMessageMenuHooks` (one place at the end of the menu builder) instead of ten `if`s inside the
/// 3000-line upstream function. With the master off the menu is exactly Telegram's.
enum GGMessageMenuCustomization {
    static func register() {
        GGMessageMenuHooks.items.register({ context in
            return GGMessageMenuCustomization.extraItems(context)
        }, order: 300)
        GGMessageMenuHooks.filter.register({ items, context in
            return GGMessageMenuCustomization.filter(items, context: context)
        }, order: 300)
    }

    // MARK: Filter

    private static func hiddenTexts(_ context: GGMessageMenuContext) -> Set<String> {
        let strings = context.presentationData.strings
        var result = Set<String>()
        if !GGMessagesSettings.menuShowReply.value {
            result.insert(strings.Conversation_ContextMenuReply)
        }
        if !GGMessagesSettings.menuShowPin.value {
            result.insert(strings.Conversation_Pin)
            result.insert(strings.Conversation_Unpin)
        }
        if !GGMessagesSettings.menuShowReport.value {
            result.insert(strings.Conversation_ContextMenuReport)
        }
        if !GGMessagesSettings.menuShowSaveMedia.value {
            result.insert(strings.Gallery_SaveImage)
            result.insert(strings.Gallery_SaveVideo)
        }
        if !GGMessagesSettings.menuShowReplies.value {
            result.insert(strings.Conversation_ContextViewThread)
            for message in context.messages {
                for attribute in message.attributes {
                    if let attribute = attribute as? ReplyThreadMessageAttribute, attribute.count > 0 {
                        result.insert(strings.Conversation_ContextViewReplies(attribute.count))
                    }
                }
            }
        }
        return result
    }

    /// Takes the turned-off items out; a separator left at the start, at the end or next to another
    /// one by that goes too.
    static func filter(_ items: [ContextMenuItem], context: GGMessageMenuContext) -> [ContextMenuItem] {
        guard GGMessagesSettings.customMessageMenu.value else {
            return items
        }
        let hidden = GGMessageMenuCustomization.hiddenTexts(context)
        if hidden.isEmpty {
            return items
        }
        var kept: [ContextMenuItem] = []
        var removedAny = false
        for item in items {
            if case let .action(action) = item, hidden.contains(action.text) {
                removedAny = true
                continue
            }
            if case .separator = item {
                if kept.isEmpty {
                    continue
                }
                if case .separator? = kept.last {
                    continue
                }
            }
            kept.append(item)
        }
        if !removedAny {
            return items
        }
        while case .separator? = kept.last {
            kept.removeLast()
        }
        return kept
    }

    // MARK: Extra items

    static func extraItems(_ context: GGMessageMenuContext) -> [GGMessageMenuEntry] {
        guard GGMessagesSettings.customMessageMenu.value, !context.messages.isEmpty else {
            return []
        }
        let accountContext = context.context
        let messages = context.messages.sorted(by: { $0.id < $1.id })
        let isSecret = messages[0].id.peerId.namespace == Namespaces.Peer.SecretChat
        let hasLocalOnly = messages.contains(where: { $0.id.namespace != Namespaces.Message.Cloud })
        // What the server would refuse to forward is not offered: protected content (unless the
        // bypass sends it as a copy — then the chat and the messages report no protection), service
        // messages and view-once media.
        let isProtected = context.isCopyProtectionEnabled || messages.contains(where: { $0.isCopyProtected() })
        let hasUnforwardable = messages.contains(where: { message in
            return message.containsSecretMedia || message.media.contains(where: { $0 is TelegramMediaAction })
        })
        let canForward = !isSecret && !hasLocalOnly && !isProtected && !hasUnforwardable
        var result: [GGMessageMenuEntry] = []

        if GGMessagesSettings.menuSaveToCloud.value && canForward && messages[0].id.peerId != accountContext.account.peerId {
            result.append(GGMessageMenuEntry(position: .bottom, item: .action(ContextMenuActionItem(text: GGStrings.MessageMenu.Menu.saveToCloud, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Fave"), color: theme.contextMenu.primaryColor)
            }, action: { _, f in
                f(.default)
                GGMessageMenuCustomization.send(messages, to: accountContext.account.peerId, threadId: nil, hideNames: false, context: accountContext, toast: GGStrings.MessageMenu.savedToCloud)
            }))))
        }
        if GGMessagesSettings.menuForwardWithoutAuthor.value && canForward {
            result.append(GGMessageMenuEntry(position: .bottom, item: .action(ContextMenuActionItem(text: GGStrings.MessageMenu.Menu.forwardWithoutAuthor, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Forward"), color: theme.contextMenu.primaryColor)
            }, action: { _, f in
                f(.default)
                GGMessageMenuCustomization.pickPeerAndForward(messages, context: accountContext)
            }))))
        }
        if GGMessagesSettings.menuShowRestrict.value, let restrict = GGMessageMenuCustomization.restrictItem(messages: messages, context: accountContext, chatLocation: context.chatLocation) {
            result.append(GGMessageMenuEntry(position: .bottom, item: restrict))
        }
        return result
    }

    /// Forward (or a copy when the source is protected and the bypass is on) without opening the
    /// target; `threadId` — the forum topic chosen in the picker.
    static func send(_ messages: [Message], to peerId: PeerId, threadId: Int64?, hideNames: Bool, context: AccountContext, toast: String) {
        GGForwardSend.send(account: context.account, messages: messages, to: [GGForwardSend.Target(peerId: peerId, threadId: threadId)], hideNames: hideNames, hideCaptions: false, completion: { result in
            GGMessageMenuCustomization.showResult(result, context: context, toast: toast)
        })
    }

    private static func pickPeerAndForward(_ messages: [Message], context: AccountContext) {
        guard let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController else {
            return
        }
        // As Telegram's own «Переслать»: «Выбрать» for several chats, a comment, the forward options
        // (names start hidden) and the send menu.
        let controller = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.onlyWriteable, .excludeDisabled, .doNotSearchMessages], hasFilters: true, multipleSelection: true, forwardedMessageIds: messages.map { $0.id }, selectForumThreads: true, ggHidesSenderNames: true))
        controller.peerSelected = { [weak controller] peer, threadId in
            controller?.dismiss()
            GGMessageMenuCustomization.send(messages, to: peer.id, threadId: threadId, hideNames: true, context: context, toast: GGStrings.MessageMenu.forwarded)
        }
        controller.multiplePeersSelected = { [weak controller] peers, _, text, mode, forwardOptions, _ in
            guard let controller, !peers.isEmpty else {
                return
            }
            let send: (Bool, Int32?, Int32?) -> Void = { silent, scheduleTime, repeatPeriod in
                controller.dismiss()
                GGForwardSend.send(account: context.account, messages: messages, comment: GGMessageMenuCustomization.commentMessages(text), to: peers.map { GGForwardSend.Target(peerId: $0.id, threadId: nil) }, hideNames: forwardOptions?.hideNames ?? true, hideCaptions: forwardOptions?.hideCaptions ?? false, silent: silent, scheduleTime: scheduleTime, repeatPeriod: repeatPeriod, completion: { result in
                    GGMessageMenuCustomization.showResult(result, context: context, toast: GGStrings.MessageMenu.forwarded)
                })
            }
            switch mode {
            case .generic:
                send(false, nil, nil)
            case .silent:
                send(true, nil, nil)
            case .whenOnline:
                send(false, scheduleWhenOnlineTimestamp, nil)
            case .schedule:
                let scheduleMode: ChatScheduleTimeScreen.Mode
                if peers.count == 1, peers[0].id == context.account.peerId {
                    scheduleMode = .reminders
                } else {
                    scheduleMode = .scheduledMessages(peerId: peers[0].id, sendWhenOnlineAvailable: false)
                }
                controller.present(ChatScheduleTimeScreen(context: context, mode: scheduleMode, currentTime: nil, isDark: false, completion: { result in
                    send(result.silentPosting, result.time, result.repeatPeriod)
                }), in: .window(.root))
            }
        }
        navigationController.pushViewController(controller)
    }

    /// The comment typed in the picker, as Telegram's forward sends it: split by the length limit,
    /// with its entities.
    private static func commentMessages(_ text: NSAttributedString) -> [EnqueueMessage] {
        var result: [EnqueueMessage] = []
        for part in breakChatInputText(trimChatInputText(convertMarkdownToAttributes(text))) where part.length != 0 {
            var attributes: [MessageAttribute] = []
            let entities = generateTextEntities(part.string, enabledTypes: .all, currentEntities: generateChatInputTextEntities(part))
            if !entities.isEmpty {
                attributes.append(TextEntitiesMessageAttribute(entities: entities))
            }
            result.append(.message(text: part.string, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
        }
        return result
    }

    private static func showResult(_ result: GGForwardCopy.Result, context: AccountContext, toast: String) {
        let text: String
        if !result.messages.isEmpty {
            text = toast
        } else {
            // Nothing could be copied: say why instead of a «sent» that did not happen.
            text = result.failedCount > 0 ? GGStrings.Restrictions.Copy.failed(count: result.failedCount) : GGStrings.Restrictions.Copy.unsupported(count: result.skippedCount)
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        context.sharedContext.mainWindow?.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in
            return false
        }), on: .root)
    }

    /// «Ограничить»: admins who may ban get the member restriction screen for the author.
    private static func restrictItem(messages: [Message], context: AccountContext, chatLocation: ChatLocation) -> ContextMenuItem? {
        guard messages.count == 1, let message = messages.first, let author = message.author as? TelegramUser, author.id != context.account.peerId else {
            return nil
        }
        guard let channel = message.peers[message.id.peerId] as? TelegramChannel, case .group = channel.info, channel.hasPermission(.banMembers) else {
            return nil
        }
        let channelId = channel.id
        return .action(ContextMenuActionItem(text: GGStrings.MessageMenu.Menu.restrict, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Restrict"), color: theme.contextMenu.primaryColor)
        }, action: { _, f in
            f(.default)
            guard let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController else {
                return
            }
            let controller = channelBannedMemberController(context: context, peerId: channelId, memberId: author.id, initialParticipant: nil, updated: { _ in }, upgradedToSupergroup: { _, f in f() })
            navigationController.pushViewController(controller)
        }))
    }
}
