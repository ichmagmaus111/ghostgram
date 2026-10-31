import Foundation
import GGCore
import GGAppearanceSettings

/// One-time move of the old Ghostgram's appearance settings (three stores: `FontCustomization.*` /
/// `GG.fontCustomization.*`, `GG.checkmark.*`, and the Ghostgram keys parked in SGSimpleSettings)
/// into the registry. Only values the user actually stored are moved: an absent key
/// leaves the new default (toggles off). Old «show …» toggles that were ON by default became
/// «hide …» toggles that are OFF by default.
///
/// Dead keys are not moved: `readStatusColor*` (no consumer), the `chatListGradient*` switches
/// (the gradient never painted; its color, size and strength only fill the one edge group when the
/// blur's are absent). The glass settings (`GG.liquidGlass*`) are not moved at all: the feature was
/// removed (owner 2026-10-27), its keys only go (`appearance.glass.removed.v1`).
enum GGAppearanceMigration {
    static func register() {
        GGMigrations.registerGlobal(id: "appearance.v1") { legacy in
            GGAppearanceMigration.moveBubbles(legacy)
            GGAppearanceMigration.moveCheckmarks(legacy)
            GGAppearanceMigration.moveMessages(legacy)
            GGAppearanceMigration.moveTheme(legacy)
            GGAppearanceMigration.moveEdges(legacy)
            GGAppearanceMigration.moveBackgrounds(legacy)
            GGAppearanceMigration.moveProfile(legacy)
        }
        GGMigrations.registerGlobal(id: "appearance.font.v2") { legacy in
            GGAppearanceMigration.dropRemovedFonts(legacy)
        }
        GGMigrations.registerGlobal(id: "appearance.merge.v1") { _ in
            GGAppearanceMigration.mergeRetiredSettings()
        }
        // «Стекло» (Liquid Glass) was removed by the owner on 2026-10-27, its upstream edits went back
        // to upstream. Whatever it stored goes once: the old client's keys and this app's
        // `appearance.glass.*` (build 185 and earlier).
        GGMigrations.registerGlobal(id: "appearance.glass.removed.v1") { legacy in
            for key in GGAppearanceMigration.removedGlassLegacyKeys {
                legacy.removeLegacyKey(key)
            }
            GGRetiredSettings.remove(prefixes: ["appearance.glass."])
        }
    }

    /// The old client's glass keys: its raw `UserDefaults` switches and the Swiftgram key of the system
    /// glass (`SGSimpleSettings.systemLiquidGlassEnabled` used the same name).
    static let removedGlassLegacyKeys: [String] = [
        "GG.liquidGlass", "GG.liquidGlassIntensity", "GG.liquidGlass.tintColor", "GG.liquidGlass.cornerRadius",
        "GG.liquidGlass.disableBlur", "GG.liquidGlass.disableShadow", "GG.liquidGlass.disableHighlight",
        "GG.liquidGlass.tabBar", "GG.liquidGlass.navBar", "GG.liquidGlass.search", "GG.liquidGlass.chatInput",
        "GG.liquidGlass.chatButtons", "GG.systemLiquidGlass.enabled"
    ]

    /// Builds ≤ 185 had two switches for hidden reactions, two for hidden formatting and nine rows
    /// of screen edges; since 2026-10-27 each is one setting (`GGAppearanceChoices.swift`). Their
    /// stored values are carried over once, then dropped from the settings file.
    static let retiredKeys: [String] = [
        "appearance.messages.hideReactionsInChats", "appearance.messages.hideReactionsInChannels",
        "appearance.messages.hideIncomingFormatting", "appearance.messages.hideOutgoingFormatting",
        "appearance.edges.blur", "appearance.edges.blurColor", "appearance.edges.blurSize", "appearance.edges.blurIntensity",
        "appearance.edges.gradient", "appearance.edges.gradientColor", "appearance.edges.gradientSize",
        "appearance.edges.gradientIntensity", "appearance.edges.gradientHideInChatList"
    ]

    private static func mergeRetiredSettings() {
        if let value = GGHiddenReactions.merged(inChats: GGRetiredSettings.value("appearance.messages.hideReactionsInChats", as: Bool.self), inChannels: GGRetiredSettings.value("appearance.messages.hideReactionsInChannels", as: Bool.self)) {
            GGAppearanceSettings.hideReactions.set(value.rawValue)
        }
        if let value = GGHiddenFormatting.merged(inIncoming: GGRetiredSettings.value("appearance.messages.hideIncomingFormatting", as: Bool.self), inOutgoing: GGRetiredSettings.value("appearance.messages.hideOutgoingFormatting", as: Bool.self)) {
            GGAppearanceSettings.hideFormatting.set(value.rawValue)
        }
        var old = GGEdgeMerge.Old()
        old.blur = GGRetiredSettings.value("appearance.edges.blur", as: Bool.self)
        old.blurColor = GGRetiredSettings.value("appearance.edges.blurColor", as: String.self)
        old.blurSize = GGRetiredSettings.value("appearance.edges.blurSize", as: Double.self)
        old.blurIntensity = GGRetiredSettings.value("appearance.edges.blurIntensity", as: Double.self)
        old.gradient = GGRetiredSettings.value("appearance.edges.gradient", as: Bool.self)
        old.gradientColor = GGRetiredSettings.value("appearance.edges.gradientColor", as: String.self)
        old.gradientSize = GGRetiredSettings.value("appearance.edges.gradientSize", as: Double.self)
        old.gradientIntensity = GGRetiredSettings.value("appearance.edges.gradientIntensity", as: Double.self)
        old.gradientHideInChatList = GGRetiredSettings.value("appearance.edges.gradientHideInChatList", as: Bool.self)
        if let merge = GGEdgeMerge.merged(old) {
            GGAppearanceMigration.apply(merge)
        }
        GGRetiredSettings.remove(keys: GGAppearanceMigration.retiredKeys)
    }

    private static func apply(_ merge: GGEdgeMerge) {
        if merge.style != .off {
            GGAppearanceSettings.edgeStyle.set(merge.style.rawValue)
        }
        if let color = merge.color, let rgb = ggAppearanceParseColor(color) {
            GGAppearanceSettings.edgeColor.set(ggAppearanceColorString(rgb))
        }
        if let size = merge.size {
            GGAppearanceSettings.edgeSize.set(size)
        }
        if let intensity = merge.intensity {
            GGAppearanceSettings.edgeIntensity.set(intensity)
        }
        if let hideInChatList = merge.hideInChatList {
            GGAppearanceSettings.edgeHideInChatList.set(hideInChatList)
        }
    }

    // MARK: Helpers

    private static func bool(_ legacy: GGLegacyDefaults, _ key: String, to setting: GGSetting<Bool>, inverted: Bool = false) {
        if let value = legacy.bool(key) {
            setting.set(inverted ? !value : value)
            legacy.removeLegacyKey(key)
        }
    }

    private static func double(_ legacy: GGLegacyDefaults, _ key: String, to setting: GGSetting<Double>, range: ClosedRange<Double>) {
        if let value = legacy.double(key) {
            setting.set(min(range.upperBound, max(range.lowerBound, value)))
            legacy.removeLegacyKey(key)
        }
    }

    /// The old checkmark colors were stored as `[r, g, b, a]` doubles.
    private static func rgbaColor(_ legacy: GGLegacyDefaults, _ key: String) -> String? {
        guard let components = legacy.object(key) as? [NSNumber], components.count >= 3 else {
            return nil
        }
        let r = UInt32(max(0.0, min(1.0, components[0].doubleValue)) * 255.0)
        let g = UInt32(max(0.0, min(1.0, components[1].doubleValue)) * 255.0)
        let b = UInt32(max(0.0, min(1.0, components[2].doubleValue)) * 255.0)
        return ggAppearanceColorString((r << 16) | (g << 8) | b)
    }

    /// The old code stored absolute paths, which break when iOS moves the app container: the same
    /// file name is looked up in Documents as well.
    static func legacyFile(_ path: String) -> URL? {
        if path.isEmpty {
            return nil
        }
        if FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let candidate = documents.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Deletes a leftover directory off the main thread (migrations run on it at launch).
    static func removeInBackground(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Groups

    /// Fonts are only the ones that ship with iOS (owner decision 2026-10-22), so no font value is
    /// carried over; whatever pointed at a removed font goes:
    /// - the old Ghostgram's keys (it offered only its bundled free fonts and an imported file; the
    ///   last one is its «show fonts» list state) and `Documents/Fonts`, where its import copied every
    ///   picked file and never deleted one;
    /// - a family stored by an earlier build of this app (a removed bundled font, «imported») → the
    ///   system font (the default), and that build's directory of imported fonts.
    private static func dropRemovedFonts(_ legacy: GGLegacyDefaults) {
        for key in ["FontCustomization.isEnabled", "FontCustomization.selectedFont", "FontCustomization.isCustomSelected", "FontCustomization.importedFontPath", "FontCustomization.importedFontName", "FontCustomizationController.fontsExpanded"] {
            legacy.removeLegacyKey(key)
        }
        if GGFontFamily(rawValue: GGAppearanceSettings.fontFamily.value) == nil && !GGCustomFonts.isCustomValue(GGAppearanceSettings.fontFamily.value) {
            GGAppearanceSettings.fontFamily.reset()
        }
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            GGAppearanceMigration.removeInBackground(documents.appendingPathComponent("Fonts", isDirectory: true))
        }
        if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            GGAppearanceMigration.removeInBackground(applicationSupport.appendingPathComponent("ghostgram/appearance/fonts", isDirectory: true))
        }
    }

    private static func moveBubbles(_ legacy: GGLegacyDefaults) {
        GGAppearanceMigration.bool(legacy, "bubbleEditorEnabled", to: GGAppearanceSettings.bubbleEditor)
        GGAppearanceMigration.double(legacy, "bubbleIncomingRadius", to: GGAppearanceSettings.bubbleIncomingRadius, range: 0.0 ... 16.0)
        GGAppearanceMigration.double(legacy, "bubbleOutgoingRadius", to: GGAppearanceSettings.bubbleOutgoingRadius, range: 0.0 ... 16.0)
        GGAppearanceMigration.double(legacy, "bubblePadding", to: GGAppearanceSettings.bubblePadding, range: 0.0 ... 24.0)
        GGAppearanceMigration.double(legacy, "bubbleWidthPercent", to: GGAppearanceSettings.bubbleWidth, range: 40.0 ... 100.0)
        GGAppearanceMigration.double(legacy, "bubbleBackgroundOpacity", to: GGAppearanceSettings.bubbleBackgroundOpacity, range: 0.0 ... 100.0)
        GGAppearanceMigration.double(legacy, "bubbleOutlineOpacity", to: GGAppearanceSettings.bubbleOutlineOpacity, range: 0.0 ... 100.0)
        GGAppearanceMigration.bool(legacy, "bubbleHasTails", to: GGAppearanceSettings.bubbleHideTails, inverted: true)
    }

    private static func moveCheckmarks(_ legacy: GGLegacyDefaults) {
        if legacy.bool("GG.checkmark.useCustomReadColor") == true, let color = GGAppearanceMigration.rgbaColor(legacy, "GG.checkmark.readColor") {
            GGAppearanceSettings.readCheckColor.set(color)
        }
        if legacy.bool("GG.checkmark.useCustomUnreadColor") == true, let color = GGAppearanceMigration.rgbaColor(legacy, "GG.checkmark.unreadColor") {
            GGAppearanceSettings.unreadCheckColor.set(color)
        }
        GGAppearanceMigration.bool(legacy, "GG.checkmark.useReadColorForUnread", to: GGAppearanceSettings.unreadCheckSameAsRead)
        GGAppearanceMigration.bool(legacy, "GG.checkmark.applyInChatList", to: GGAppearanceSettings.checkColorsInChatList)
        for key in ["GG.checkmark.useCustomReadColor", "GG.checkmark.readColor", "GG.checkmark.useCustomUnreadColor", "GG.checkmark.unreadColor"] {
            legacy.removeLegacyKey(key)
        }
    }

    private static func moveMessages(_ legacy: GGLegacyDefaults) {
        GGAppearanceMigration.bool(legacy, "FontCustomization.showExactLastSeen", to: GGAppearanceSettings.exactLastSeen)
        // Hidden formatting and hidden reactions are one choice each since 2026-10-27.
        if let value = GGHiddenFormatting.merged(inIncoming: legacy.bool("FontCustomization.hideIncomingTextFormatting"), inOutgoing: legacy.bool("FontCustomization.hideOutgoingTextFormatting")) {
            GGAppearanceSettings.hideFormatting.set(value.rawValue)
        }
        legacy.removeLegacyKey("FontCustomization.hideIncomingTextFormatting")
        legacy.removeLegacyKey("FontCustomization.hideOutgoingTextFormatting")
        GGAppearanceMigration.bool(legacy, "FontCustomization.hideChannelComments", to: GGAppearanceSettings.hideChannelComments)
        GGAppearanceMigration.bool(legacy, "FontCustomization.hideChannelViewCounts", to: GGAppearanceSettings.hideViewCounts)
        GGAppearanceMigration.bool(legacy, "FontCustomization.hideMessageTimestamps", to: GGAppearanceSettings.hideTime)
        GGAppearanceMigration.bool(legacy, "FontCustomization.hideEditedStatus", to: GGAppearanceSettings.hideEdited)
        GGAppearanceMigration.bool(legacy, "FontCustomization.chatAvatarOnlineIndicator", to: GGAppearanceSettings.authorOnlineIndicator)
        if let mode = legacy.string("GG.fontCustomization.tripleTapDeleteMode") {
            switch mode {
            case "local":
                GGAppearanceSettings.tripleTapDelete.set(GGTripleTapDelete.local.rawValue)
            case "everyone":
                GGAppearanceSettings.tripleTapDelete.set(GGTripleTapDelete.everyone.rawValue)
            default:
                break
            }
            legacy.removeLegacyKey("GG.fontCustomization.tripleTapDeleteMode")
        }
        GGAppearanceMigration.bool(legacy, "FontCustomization.showChatTopBarBackButton", to: GGAppearanceSettings.hideBackButton, inverted: true)
        GGAppearanceMigration.bool(legacy, "FontCustomization.showChatTopBarTitlePanel", to: GGAppearanceSettings.hideTitlePanel, inverted: true)
        GGAppearanceMigration.bool(legacy, "FontCustomization.showChatTopBarAvatar", to: GGAppearanceSettings.hideAvatar, inverted: true)
        GGAppearanceMigration.bool(legacy, "FontCustomization.showChatTopBarPinnedMessages", to: GGAppearanceSettings.hidePinnedMessages, inverted: true)
        GGAppearanceMigration.bool(legacy, "disableBlurOnMessageSelection", to: GGAppearanceSettings.noSelectionBlur)
        GGAppearanceMigration.bool(legacy, "wideChannelPosts", to: GGAppearanceSettings.wideChannelPosts)
        GGAppearanceMigration.bool(legacy, "secondsInMessages", to: GGAppearanceSettings.secondsInTime)
        // The old Swiftgram key meant both places; it is older, so the specific keys win.
        let hideEverywhere: Bool? = legacy.bool("hideReactions") == true ? true : nil
        if let value = GGHiddenReactions.merged(inChats: legacy.bool("hideReactionsInChats") ?? hideEverywhere, inChannels: legacy.bool("hideReactionsInChannels") ?? hideEverywhere) {
            GGAppearanceSettings.hideReactions.set(value.rawValue)
        }
        for key in ["hideReactions", "hideReactionsInChats", "hideReactionsInChannels"] {
            legacy.removeLegacyKey(key)
        }
        GGAppearanceMigration.double(legacy, "stickerSize", to: GGAppearanceSettings.stickerSize, range: 50.0 ... 100.0)
        GGAppearanceMigration.bool(legacy, "stickerTimestamp", to: GGAppearanceSettings.stickerHideTime, inverted: true)
    }

    private static func moveTheme(_ legacy: GGLegacyDefaults) {
        GGAppearanceMigration.bool(legacy, "GG.fontCustomization.amoledTrueBlack", to: GGAppearanceSettings.amoled)
        GGAppearanceMigration.bool(legacy, "GG.fontCustomization.amoledKeyboard", to: GGAppearanceSettings.amoledKeyboard)
        GGAppearanceMigration.bool(legacy, "GG.fontCustomization.hideCellSeparators", to: GGAppearanceSettings.hideSeparators)
        GGAppearanceMigration.double(legacy, "accountColorsSaturation", to: GGAppearanceSettings.nameColorSaturation, range: 0.0 ... 100.0)
        GGAppearanceMigration.bool(legacy, "GG.fontCustomization.snowflakes", to: GGAppearanceSettings.snow)
        GGAppearanceMigration.double(legacy, "GG.fontCustomization.snowflakesIntensity", to: GGAppearanceSettings.snowIntensity, range: 10.0 ... 100.0)
        GGAppearanceMigration.bool(legacy, "GG.fontCustomization.snowflakesInChat", to: GGAppearanceSettings.snowHideInChats, inverted: true)
        // Swiftgram's New Year effect needed its server to switch on; its style is kept.
        if let style = legacy.string("nyStyle") {
            if style == "lightning" {
                GGAppearanceSettings.snowStyle.set(GGSnowStyle.lightning.rawValue)
            }
            legacy.removeLegacyKey("nyStyle")
        }
    }

    /// The old switches are not carried over (the blur was on by default, the gradient never
    /// painted): only the values, into the one group «Затемнение краёв» — the blur's first.
    private static func moveEdges(_ legacy: GGLegacyDefaults) {
        var old = GGEdgeMerge.Old()
        old.blurColor = GGAppearanceMigration.legacyColor(legacy, "chatBlurColor", autoKey: "chatBlurAutoColor")
        old.blurSize = legacy.double("chatBlurSize")
        old.blurIntensity = legacy.double("chatBlurIntensity")
        old.gradientColor = GGAppearanceMigration.legacyColor(legacy, "chatListGradientColor", autoKey: "chatListGradientAutoColor")
        old.gradientSize = legacy.double("chatListGradientSize")
        old.gradientIntensity = legacy.double("chatListGradientIntensity")
        old.gradientHideInChatList = legacy.bool("chatListGradientInChatList").map { !$0 }
        if let merge = GGEdgeMerge.merged(old) {
            GGAppearanceMigration.apply(merge)
        }
        for key in ["displayBlurInChats", "chatBlurAutoColor", "chatBlurColor", "chatBlurSize", "chatBlurIntensity", "chatListGradientEnabled", "chatListGradientAutoColor", "chatListGradientColor", "chatListGradientSize", "chatListGradientIntensity", "chatListGradientInChatList"] {
            legacy.removeLegacyKey(key)
        }
    }

    /// An old color is used only when its «automatic» switch was off.
    private static func legacyColor(_ legacy: GGLegacyDefaults, _ key: String, autoKey: String) -> String? {
        guard legacy.bool(autoKey) == false, let value = legacy.string(key), let rgb = ggAppearanceParseColor(value) else {
            return nil
        }
        return ggAppearanceColorString(rgb)
    }

    private static func moveBackgrounds(_ legacy: GGLegacyDefaults) {
        GGAppearanceMigration.double(legacy, "gifWallpaperOpacity", to: GGAppearanceSettings.chatBackgroundOpacity, range: 5.0 ... 100.0)
        GGAppearanceMigration.double(legacy, "profileGifOpacity", to: GGAppearanceSettings.profileBackgroundOpacity, range: 5.0 ... 100.0)
        // Old files are converted in the background; the background switches on when ready.
        if legacy.bool("gifWallpaperEnabled") == true, let path = legacy.string("gifWallpaperPath"), let url = GGAppearanceMigration.legacyFile(path) {
            GGAnimatedBackgrounds.importFile(at: url, kind: .chat, completion: { _ in })
        }
        if legacy.bool("profileGifEnabled") == true, let path = legacy.string("profileGifPath"), let url = GGAppearanceMigration.legacyFile(path) {
            GGAnimatedBackgrounds.importFile(at: url, kind: .profile, completion: { _ in })
        }
        for key in ["gifWallpaperEnabled", "gifWallpaperPath", "profileGifEnabled", "profileGifPath"] {
            legacy.removeLegacyKey(key)
        }
    }

    private static func moveProfile(_ legacy: GGLegacyDefaults) {
        GGAppearanceMigration.bool(legacy, "showProfileId", to: GGAppearanceSettings.profileShowId)
        GGAppearanceMigration.bool(legacy, "showDC", to: GGAppearanceSettings.profileShowDataCenter)
        GGAppearanceMigration.bool(legacy, "showCreationDate", to: GGAppearanceSettings.profileShowDates)
        GGAppearanceMigration.bool(legacy, "GG.fontCustomization.hideProfileDescription", to: GGAppearanceSettings.profileHideDescription)
        GGAppearanceMigration.bool(legacy, "GG.fontCustomization.showPeerInfoShareButton", to: GGAppearanceSettings.profileHideShareButton, inverted: true)
        GGAppearanceMigration.bool(legacy, "GG.fontCustomization.hideStarRatingBadge", to: GGAppearanceSettings.profileHideStarRating)
    }
}
