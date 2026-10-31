import Foundation
import GGCore
import GGFeaturesShared

/// Old Ghostgram keys → the settings of this zone. The «Прочее» master switch is not carried over
/// as a setting (every feature has its own toggle now): a flag that only worked behind the master
/// is migrated as its effective old value (master && flag), so nothing turns on that did not work.
enum GGMessagesMigrations {
    static func register() {
        GGMigrations.registerGlobal(id: "messages.v1") { legacy in
            GGMessagesMigrations.migrateGlobal(legacy)
        }
        GGMigrations.registerAccount(id: "messages.account.v1") { legacy, account in
            GGMessagesMigrations.migrateAccount(legacy, account: account)
        }
        // «Антипоиск» and «Язык бурмалды» were removed by the owner on 2026-10-27: the old client's
        // keys and this app's two switches (build 185 and earlier) go once.
        GGMigrations.registerGlobal(id: "messages.removedStages.v1") { legacy in
            for key in ["GG.invisibleText", "GG.burmalda.enabled", "GG.burmalda.dictionary"] {
                legacy.removeLegacyKey(key)
            }
            GGRetiredSettings.remove(keys: ["sending.antiSearch", "sending.burmalda"])
        }
        // Builds ≤ 185 had «…к следующему каналу» and «…к следующей теме» as two switches; since
        // 2026-10-27 they are one. Their stored values are carried over once, then dropped.
        GGMigrations.registerGlobal(id: "chats.scrollToNext.merge.v1") { _ in
            let channel = GGRetiredSettings.value("chats.disableScrollToNextChannel", as: Bool.self)
            let topic = GGRetiredSettings.value("chats.disableScrollToNextTopic", as: Bool.self)
            if GGScrollToNextMerge.merged(channel: channel, topic: topic) == true {
                GGMessagesSettings.disableScrollToNext.set(true)
            }
            GGRetiredSettings.remove(keys: ["chats.disableScrollToNextChannel", "chats.disableScrollToNextTopic"])
        }
        // «Выбрать от автора» in the message menu removed (owner, 2026-10-29): the stored switch of
        // builds ≤ 191 and the old client's key go once.
        GGMigrations.registerGlobal(id: "messageMenu.selectFromAuthor.removed.v1") { legacy in
            GGRetiredSettings.remove(keys: ["messageMenu.selectFromAuthor"])
            legacy.removeLegacyKey("contextShowSelectFromUser")
        }
        // «Безлимитные закрепы»: the old client copied every pinned list of an account to
        // `UserDefaults` (`GG.pinnedOverflowBackup.<account peer>.<group>`, rewritten on each change).
        // The lists themselves, tail included, are in the account's Postbox, which carries over, and the
        // first server list marks the pins beyond the limit as the tail — the copy is only removed.
        GGMigrations.registerAccountPeer(id: "chats.pinnedBackupCleanup.v1") { legacy, _, peer in
            guard let legacyPeerId = GGLegacyKeys.legacyInt64(of: peer) else {
                return
            }
            legacy.removeLegacyKey("GG.pinnedOverflowBackup.\(legacyPeerId).0")
            legacy.removeLegacyKey("GG.pinnedOverflowBackup.\(legacyPeerId).1")
        }
    }

    private static func move(_ legacy: GGLegacyDefaults, _ key: String, to setting: GGSetting<Bool>, gatedBy master: Bool? = nil, invert: Bool = false) {
        guard let value = legacy.bool(key) else {
            return
        }
        var effective = invert ? !value : value
        if let master {
            effective = effective && master
        }
        if effective != setting.defaultValue {
            setting.set(effective)
        }
        legacy.removeLegacyKey(key)
    }

    static func migrateGlobal(_ legacy: GGLegacyDefaults) {
        let master = legacy.bool("MiscSettings.isEnabled") ?? false
        legacy.removeLegacyKey("MiscSettings.isEnabled")
        legacy.removeLegacyKey("MiscSettings.initialized")

        // «Обходы ограничений» (behind the old master).
        move(legacy, "MiscSettings.bypassCopyProtection", to: GGMessagesSettings.copyProtectionBypass, gatedBy: master)
        move(legacy, "MiscSettings.addForwardAuthorAttribution", to: GGMessagesSettings.forwardAttribution, gatedBy: master)
        move(legacy, "MiscSettings.disableViewOnceAutoDelete", to: GGMessagesSettings.keepSelfDestructingMedia, gatedBy: master)
        move(legacy, "MiscSettings.bypassScreenshotProtection", to: GGMessagesSettings.screenshotBypass, gatedBy: master)
        move(legacy, "MiscSettings.blockAds", to: GGMessagesSettings.blockAds, gatedBy: master)
        move(legacy, "MiscSettings.bypassBotRestrictions", to: GGMessagesSettings.contentRestrictionsBypass, gatedBy: master)
        move(legacy, "MiscSettings.antiSpoiler", to: GGMessagesSettings.revealSpoilers, gatedBy: master)

        // Outgoing text.
        move(legacy, "MiscSettings.antiCaps", to: GGMessagesSettings.antiCaps, gatedBy: master)
        move(legacy, "MiscSettings.wordReplacementEnabled", to: GGMessagesSettings.wordReplacement, gatedBy: master)
        // «Антипоиск» and «Язык бурмалды» were removed (owner, 2026-10-27): only their keys go
        // (`messages.removedStages.v1`).
        move(legacy, "GG.hyperlinkSpoof.enabled", to: GGMessagesSettings.hyperlinkSpoof)
        GGMessagesMigrations.migrateReplacementRules(legacy)

        // Replies, stickers, inline bots, the input field.
        move(legacy, "MiscSettings.autoQuoteReply", to: GGMessagesSettings.autoQuoteReply)
        move(legacy, "MiscSettings.autoQuoteReplySkipDiscussions", to: GGMessagesSettings.autoQuoteSkipComments)
        move(legacy, "MiscSettings.anonymousStickers", to: GGMessagesSettings.anonymousStickers)
        move(legacy, "hideInlineBotAttribution", to: GGMessagesSettings.sendWithoutViaBot)
        move(legacy, "keepInlineBotCaption", to: GGMessagesSettings.keepInlineBotCaption)
        move(legacy, "sendWithReturnKey", to: GGMessagesSettings.sendOnReturn)
        move(legacy, "disableSendAsButton", to: GGMessagesSettings.hideSendAsButton)

        // Translation.
        if let backend = legacy.string("translationBackend") {
            switch backend {
            case "gtranslate":
                // The notice is shown once before Google is used (GGTranslationMenu).
                GGMessagesSettings.translationService.set(GGTranslationServiceKind.google.rawValue)
            case "system":
                GGMessagesSettings.translationService.set(GGTranslationServiceKind.system.rawValue)
            default:
                break
            }
            legacy.removeLegacyKey("translationBackend")
        }
        move(legacy, "quickTranslateButton", to: GGMessagesSettings.quickTranslateButton)
        move(legacy, "translateBeforeSending", to: GGMessagesSettings.translateBeforeSending)
        if let language = legacy.string("translateBeforeSendingLanguage"), !language.isEmpty {
            GGMessagesSettings.translateBeforeSendingLanguage.set(language)
            legacy.removeLegacyKey("translateBeforeSendingLanguage")
        }
        // The old per-chat languages were keyed by raw ids without a peer namespace and by the
        // account's peer id: they can not be mapped to chats safely and are not carried over.
        legacy.removeLegacyKey("outgoingLanguageTranslation")

        // Message menu (SG-G1): «show item» flags of the old menu; any hidden one turns the custom menu on.
        let menuKeys: [(String, GGSetting<Bool>)] = [
            ("contextShowReply", GGMessagesSettings.menuShowReply),
            ("contextShowPin", GGMessagesSettings.menuShowPin),
            ("contextShowReport", GGMessagesSettings.menuShowReport),
            ("contextShowRestrict", GGMessagesSettings.menuShowRestrict),
            ("contextShowSaveMedia", GGMessagesSettings.menuShowSaveMedia),
            ("contextShowMessageReplies", GGMessagesSettings.menuShowReplies)
        ]
        var customMenu = false
        for (key, setting) in menuKeys {
            if let value = legacy.bool(key) {
                setting.set(value)
                if !value {
                    customMenu = true
                }
                legacy.removeLegacyKey(key)
            }
        }
        if let value = legacy.bool("contextShowSaveToCloud") {
            GGMessagesSettings.menuSaveToCloud.set(value)
            customMenu = customMenu || value
            legacy.removeLegacyKey("contextShowSaveToCloud")
        }
        if let value = legacy.bool("contextShowHideForwardName") {
            GGMessagesSettings.menuForwardWithoutAuthor.set(value)
            customMenu = customMenu || value
            legacy.removeLegacyKey("contextShowHideForwardName")
        }
        // «Выбрать от автора» was removed (owner, 2026-10-29): only its key goes.
        legacy.removeLegacyKey("contextShowSelectFromUser")
        if customMenu {
            GGMessagesSettings.customMessageMenu.set(true)
        }
        // SG debug item, not carried over (Swiftgram infrastructure).
        legacy.removeLegacyKey("contextShowJson")

        // Gestures.
        if let value = legacy.string("messageDoubleTapActionOutgoing") {
            if value == "edit" {
                GGMessagesSettings.doubleTapToEdit.set(true)
            }
            legacy.removeLegacyKey("messageDoubleTapActionOutgoing")
        }
        if let value = legacy.string("videoPIPSwipeDirection") {
            if value == "none" {
                GGMessagesSettings.disableVideoPipSwipe.set(true)
            }
            legacy.removeLegacyKey("videoPIPSwipeDirection")
        }

        // «Чаты».
        move(legacy, "MiscSettings.unlimitedSearchHistory", to: GGMessagesSettings.unlimitedSearchHistory, gatedBy: master)
        move(legacy, "MiscSettings.hideGreetingSticker", to: GGMessagesSettings.hideGreetingSticker, gatedBy: master)
        move(legacy, "hideChannelBottomButton", to: GGMessagesSettings.hideChannelBottomButton)
        // One switch for channels and topics since 2026-10-27: on when either old one was on.
        if GGScrollToNextMerge.merged(channel: legacy.bool("disableScrollToNextChannel"), topic: legacy.bool("disableScrollToNextTopic")) == true {
            GGMessagesSettings.disableScrollToNext.set(true)
        }
        legacy.removeLegacyKey("disableScrollToNextChannel")
        legacy.removeLegacyKey("disableScrollToNextTopic")
        move(legacy, "disableSnapDeletionEffect", to: GGMessagesSettings.disableDeleteEffect)
        move(legacy, "hideRecordingButton", to: GGMessagesSettings.hideRecordButton)
        if let keywords = legacy.stringArray("messageFilterKeywords") {
            let cleaned = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !cleaned.isEmpty {
                GGMessagesSettings.keywords.set(cleaned)
                GGMessagesSettings.keywordFilter.set(true)
            }
            legacy.removeLegacyKey("messageFilterKeywords")
        }

        // «Уведомления» (old App Group keys).
        let modes: [(String, GGSetting<String>)] = [
            ("pinnedMessageNotifications", GGMessagesSettings.pinnedNotifications),
            ("mentionsAndRepliesNotifications", GGMessagesSettings.mentionNotifications)
        ]
        for (key, setting) in modes {
            if let value = legacy.string(key) {
                switch value {
                case "silenced":
                    setting.set(GGNotificationDeliveryMode.silent.rawValue)
                case "disabled":
                    setting.set(GGNotificationDeliveryMode.disabled.rawValue)
                default:
                    break
                }
                legacy.removeLegacyKey(key)
            }
            // The old exception dictionaries were never written by anything.
            legacy.removeLegacyKey(key + "Exceptions")
        }
    }

    /// One rule set from both old systems (the visible «Правила замены» and the hidden
    /// `GG.textReplacement`), deduplicated by the replaced text.
    private static func migrateReplacementRules(_ legacy: GGLegacyDefaults) {
        var rules: [GGTextReplacementRule] = []
        var seen = Set<String>()
        func add(_ source: String?, _ replacement: String?) {
            guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty, let replacement else {
                return
            }
            let key = source.lowercased()
            if seen.insert(key).inserted {
                rules.append(GGTextReplacementRule(source: source, replacement: replacement))
            }
        }
        if let data = legacy.data("MiscSettings.wordReplacementRules"), let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for item in array {
                add(item["source"] as? String, item["replacement"] as? String)
            }
        }
        legacy.removeLegacyKey("MiscSettings.wordReplacementRules")
        if let array = legacy.object("GG.textReplacement.rules") as? [[String: Any]] {
            for item in array {
                add(item["source"] as? String, item["replacement"] as? String)
            }
        }
        if legacy.bool("GG.textReplacement.enabled") == true && !rules.isEmpty {
            GGMessagesSettings.wordReplacement.set(true)
        }
        for key in ["GG.textReplacement.rules", "GG.textReplacement.enabled", "GG.textReplacement.draftSource", "GG.textReplacement.draftReplacement"] {
            legacy.removeLegacyKey(key)
        }
        if !rules.isEmpty {
            GGOutgoingPipeline.replacementRules.set(rules)
        }
    }

    static func migrateAccount(_ legacy: GGLegacyDefaults, account: GGAccountID) {
        // With the old per-account profiles on, the shared keys are the active account's values:
        // another account never takes them (a link target or local channels of someone else).
        func value(_ key: String) -> Any? {
            return legacy.legacyAccountValue(key, for: account)
        }
        if let text = value("GG.hyperlinkSpoof.targetId") as? String, let id = Int64(text.trimmingCharacters(in: .whitespaces)), id > 0, let key = GGPeerKey(namespace: 0, id: id) {
            GGMessagesSettings.hyperlinkTarget.set(key, for: account)
        }
        if let values = value("GG.channelCreatorSpoof.enabledPeerIds") as? [Any] {
            var keys = Set<GGPeerKey>()
            for item in values {
                if let number = item as? NSNumber {
                    keys.insert(GGLegacyKeys.peerKey(fromLegacyInt64: number.int64Value))
                }
            }
            if !keys.isEmpty {
                GGMessagesSettings.localCreatorChannels.set(keys, for: account)
            }
        }
    }
}
