import Foundation
import GGCore

/// Every appearance setting of Ghostgram, declared once (FOUNDATION_SPEC §3.1). Kept in its own small
/// module (GGCore only) so the upstream modules that draw them — down to the bubble background, which
/// sits below TelegramCore — read the same registry the menu writes.
///
/// Cells and layout never read these one by one on their hot paths: they read the immutable
/// `GGAppearanceSnapshot.current`, rebuilt once per change.
public enum GGAppearanceSettings {
    // MARK: Font (applied at launch: upstream keeps fonts in file-scope constants)

    /// `GGFontFamily.rawValue`; "system" = Telegram's font. Or "custom:<file>" — a font the user
    /// added (owner 2026-10-27, `customFonts`). Any other value reads as "system".
    public static let fontFamily = GGSetting<String>("appearance.font.family", default: "system", flags: [.requiresRestart])
    /// Fonts the user added from Files, in the order added: "<file name>\t<family name>". The files
    /// live in the app's container (Application Support/ghostgram/appearance/userFonts).
    /// Not exported: the files stay on this device.
    public static let customFonts = GGSetting<[String]>("appearance.font.custom", default: [], flags: [.noExport])

    // MARK: Bubbles

    public static let bubbleEditor = GGSetting<Bool>("appearance.bubbles.editor", default: false)
    public static let bubbleIncomingRadius = GGSetting<Double>("appearance.bubbles.incomingRadius", default: 16.0)
    public static let bubbleOutgoingRadius = GGSetting<Double>("appearance.bubbles.outgoingRadius", default: 16.0)
    /// Horizontal text inset inside a bubble, pt.
    public static let bubblePadding = GGSetting<Double>("appearance.bubbles.padding", default: 11.0)
    /// Share of the upstream maximum bubble width, %.
    public static let bubbleWidth = GGSetting<Double>("appearance.bubbles.width", default: 100.0)
    public static let bubbleBackgroundOpacity = GGSetting<Double>("appearance.bubbles.backgroundOpacity", default: 100.0)
    public static let bubbleOutlineOpacity = GGSetting<Double>("appearance.bubbles.outlineOpacity", default: 0.0)
    public static let bubbleHideTails = GGSetting<Bool>("appearance.bubbles.hideTails", default: false)

    // MARK: Checkmarks ("" = the theme's color)

    public static let readCheckColor = GGSetting<String>("appearance.checkmarks.readColor", default: "")
    public static let unreadCheckColor = GGSetting<String>("appearance.checkmarks.unreadColor", default: "")
    public static let unreadCheckSameAsRead = GGSetting<Bool>("appearance.checkmarks.unreadSameAsRead", default: false)
    public static let checkColorsInChatList = GGSetting<Bool>("appearance.checkmarks.inChatList", default: false)

    // MARK: Stickers

    /// %, 50…200 (bigger than 100 since 2026-10-27; a big sticker still fits the chat's width).
    public static let stickerSize = GGSetting<Double>("appearance.stickers.size", default: 100.0)
    public static let stickerHideTime = GGSetting<Bool>("appearance.stickers.hideTime", default: false)

    // MARK: Messages

    public static let wideChannelPosts = GGSetting<Bool>("appearance.messages.wideChannelPosts", default: false)
    public static let secondsInTime = GGSetting<Bool>("appearance.messages.secondsInTime", default: false)
    /// `GGHiddenReactions.rawValue` (one choice since 2026-10-27; replaced «…in chats» / «…in channels»).
    public static let hideReactions = GGSetting<String>("appearance.messages.hideReactions", default: GGHiddenReactions.off.rawValue)
    public static let hideEdited = GGSetting<Bool>("appearance.messages.hideEdited", default: false)
    public static let hideTime = GGSetting<Bool>("appearance.messages.hideTime", default: false)
    /// `GGHiddenFormatting.rawValue` (one choice since 2026-10-27; replaced «…incoming» / «…own»).
    public static let hideFormatting = GGSetting<String>("appearance.messages.hideFormatting", default: GGHiddenFormatting.off.rawValue)
    public static let hideChannelComments = GGSetting<Bool>("appearance.messages.hideChannelComments", default: false)
    public static let hideViewCounts = GGSetting<Bool>("appearance.messages.hideViewCounts", default: false)
    public static let colorSwatches = GGSetting<Bool>("appearance.messages.colorSwatches", default: false)
    public static let authorOnlineIndicator = GGSetting<Bool>("appearance.messages.authorOnline", default: false)
    public static let exactLastSeen = GGSetting<Bool>("appearance.messages.exactLastSeen", default: false)
    /// `GGTripleTapDelete.rawValue`.
    public static let tripleTapDelete = GGSetting<String>("appearance.messages.tripleTapDelete", default: "off")
    public static let noSelectionBlur = GGSetting<Bool>("appearance.messages.noSelectionBlur", default: false)

    // MARK: Chat top bar

    public static let hideBackButton = GGSetting<Bool>("appearance.chatTopBar.hideBackButton", default: false)
    public static let hideTitlePanel = GGSetting<Bool>("appearance.chatTopBar.hideTitle", default: false)
    public static let hideAvatar = GGSetting<Bool>("appearance.chatTopBar.hideAvatar", default: false)
    public static let hidePinnedMessages = GGSetting<Bool>("appearance.chatTopBar.hidePinned", default: false)

    // MARK: Theme

    public static let amoled = GGSetting<Bool>("appearance.theme.amoled", default: false)
    public static let amoledKeyboard = GGSetting<Bool>("appearance.theme.amoledKeyboard", default: false)
    public static let hideSeparators = GGSetting<Bool>("appearance.theme.hideSeparators", default: false)
    /// %, 0…100; 100 = the server's colors.
    public static let nameColorSaturation = GGSetting<Double>("appearance.theme.nameSaturation", default: 100.0)

    // MARK: Screen edges («Затемнение краёв»: one group since 2026-10-27 instead of blur + gradient)

    /// `GGEdgeStyle.rawValue`.
    public static let edgeStyle = GGSetting<String>("appearance.edges.style", default: GGEdgeStyle.off.rawValue)
    /// "" = automatic (the theme's background).
    public static let edgeColor = GGSetting<String>("appearance.edges.color", default: "")
    /// pt, `GGEdgeStyle.sizeRange`.
    public static let edgeSize = GGSetting<Double>("appearance.edges.size", default: GGEdgeStyle.defaultSize)
    /// %, 0…100.
    public static let edgeIntensity = GGSetting<Double>("appearance.edges.intensity", default: GGEdgeStyle.defaultIntensity)
    /// The gradient only (the blur is never drawn in the chat list).
    public static let edgeHideInChatList = GGSetting<Bool>("appearance.edges.hideInChatList", default: false)

    // MARK: Animated backgrounds (files live in the app container; settings keep only a version)

    public static let chatBackground = GGSetting<Bool>("appearance.chatBackground.enabled", default: false)
    public static let chatBackgroundOpacity = GGSetting<Double>("appearance.chatBackground.opacity", default: 30.0)
    /// Version of the converted file; 0 = none. Bumps on every new pick so players reload.
    public static let chatBackgroundVersion = GGSetting<Int>("appearance.chatBackground.version", default: 0, flags: [.noExport])
    public static let profileBackground = GGSetting<Bool>("appearance.profileBackground.enabled", default: false)
    public static let profileBackgroundOpacity = GGSetting<Double>("appearance.profileBackground.opacity", default: 50.0)
    public static let profileBackgroundVersion = GGSetting<Int>("appearance.profileBackground.version", default: 0, flags: [.noExport])

    // MARK: Snowfall (also the former «New Year» wallpaper effect)

    public static let snow = GGSetting<Bool>("appearance.snow.enabled", default: false)
    /// `GGSnowStyle.rawValue`.
    public static let snowStyle = GGSetting<String>("appearance.snow.style", default: "snow")
    /// %, 10…100.
    public static let snowIntensity = GGSetting<Double>("appearance.snow.intensity", default: 100.0)
    public static let snowHideInChats = GGSetting<Bool>("appearance.snow.hideInChats", default: false)

    // MARK: Profile

    /// On by default, as Swiftgram's `showProfileId` (W6-SGD, owner's decision 2026-10-29).
    public static let profileShowId = GGSetting<Bool>("appearance.profile.showId", default: true)
    public static let profileShowDataCenter = GGSetting<Bool>("appearance.profile.showDataCenter", default: false)
    /// On by default: Swiftgram's `showCreationDate` is on, and its «mutual contact» and «joined» rows
    /// have no switch at all (W6-SGD).
    public static let profileShowDates = GGSetting<Bool>("appearance.profile.showDates", default: true)
    public static let profileHideDescription = GGSetting<Bool>("appearance.profile.hideDescription", default: false)
    public static let profileHideShareButton = GGSetting<Bool>("appearance.profile.hideShareButton", default: false)
    public static let profileHideStarRating = GGSetting<Bool>("appearance.profile.hideStarRating", default: false)

    /// Touches every declaration so the registry knows them before export, search and migrations.
    public static func declare() {
        let _ = GGAppearanceSettings.fontFamily
        let _ = GGAppearanceSettings.customFonts
        let _ = GGAppearanceSettings.bubbleEditor
        let _ = GGAppearanceSettings.bubbleIncomingRadius
        let _ = GGAppearanceSettings.bubbleOutgoingRadius
        let _ = GGAppearanceSettings.bubblePadding
        let _ = GGAppearanceSettings.bubbleWidth
        let _ = GGAppearanceSettings.bubbleBackgroundOpacity
        let _ = GGAppearanceSettings.bubbleOutlineOpacity
        let _ = GGAppearanceSettings.bubbleHideTails
        let _ = GGAppearanceSettings.readCheckColor
        let _ = GGAppearanceSettings.unreadCheckColor
        let _ = GGAppearanceSettings.unreadCheckSameAsRead
        let _ = GGAppearanceSettings.checkColorsInChatList
        let _ = GGAppearanceSettings.stickerSize
        let _ = GGAppearanceSettings.stickerHideTime
        let _ = GGAppearanceSettings.wideChannelPosts
        let _ = GGAppearanceSettings.secondsInTime
        let _ = GGAppearanceSettings.hideReactions
        let _ = GGAppearanceSettings.hideEdited
        let _ = GGAppearanceSettings.hideTime
        let _ = GGAppearanceSettings.hideFormatting
        let _ = GGAppearanceSettings.hideChannelComments
        let _ = GGAppearanceSettings.hideViewCounts
        let _ = GGAppearanceSettings.colorSwatches
        let _ = GGAppearanceSettings.authorOnlineIndicator
        let _ = GGAppearanceSettings.exactLastSeen
        let _ = GGAppearanceSettings.tripleTapDelete
        let _ = GGAppearanceSettings.noSelectionBlur
        let _ = GGAppearanceSettings.hideBackButton
        let _ = GGAppearanceSettings.hideTitlePanel
        let _ = GGAppearanceSettings.hideAvatar
        let _ = GGAppearanceSettings.hidePinnedMessages
        let _ = GGAppearanceSettings.amoled
        let _ = GGAppearanceSettings.amoledKeyboard
        let _ = GGAppearanceSettings.hideSeparators
        let _ = GGAppearanceSettings.nameColorSaturation
        let _ = GGAppearanceSettings.edgeStyle
        let _ = GGAppearanceSettings.edgeColor
        let _ = GGAppearanceSettings.edgeSize
        let _ = GGAppearanceSettings.edgeIntensity
        let _ = GGAppearanceSettings.edgeHideInChatList
        let _ = GGAppearanceSettings.chatBackground
        let _ = GGAppearanceSettings.chatBackgroundOpacity
        let _ = GGAppearanceSettings.chatBackgroundVersion
        let _ = GGAppearanceSettings.profileBackground
        let _ = GGAppearanceSettings.profileBackgroundOpacity
        let _ = GGAppearanceSettings.profileBackgroundVersion
        let _ = GGAppearanceSettings.snow
        let _ = GGAppearanceSettings.snowStyle
        let _ = GGAppearanceSettings.snowIntensity
        let _ = GGAppearanceSettings.snowHideInChats
        let _ = GGAppearanceSettings.profileShowId
        let _ = GGAppearanceSettings.profileShowDataCenter
        let _ = GGAppearanceSettings.profileShowDates
        let _ = GGAppearanceSettings.profileHideDescription
        let _ = GGAppearanceSettings.profileHideShareButton
        let _ = GGAppearanceSettings.profileHideStarRating
    }
}

/// The fonts offered in the menu: the system font, its designs and families preinstalled in iOS 15+
/// (owner decision 2026-10-22: nothing bundled). Fonts the user adds are not cases here: they are
/// "custom:<file>" values of `appearance.font.family` (owner 2026-10-27). The raw values are stored in
/// `appearance.font.family`; the old Ghostgram's values (bundled free fonts, «imported») are not
/// among them and read as `.system`.
public enum GGFontFamily: String, CaseIterable {
    /// Telegram's font (SF Pro): no substitution at all.
    case system
    // Designs of the system font.
    case rounded
    case serif
    case monospaced
    // Families preinstalled in iOS; the menu lists them in this order (with Cyrillic first).
    case helveticaNeue
    case arial
    case avenirNext
    case gillSans
    case trebuchet
    case verdana
    case georgia
    case timesNewRoman
    case palatino
    case baskerville
    case charter
    case cochin
    case hoeflerText
    case iowanOldStyle
    case rockwell
    case americanTypewriter
    case markerFelt
    case noteworthy
    case chalkboard
    case menlo
    case courierNew
    case futura
    case optima
    case didot
    case bodoni

    /// The stored value as a family; anything unknown (a removed font) is the system font.
    public static func resolved(_ rawValue: String) -> GGFontFamily {
        return GGFontFamily(rawValue: rawValue) ?? .system
    }
}

public enum GGTripleTapDelete: String {
    case off
    case local
    case everyone
}

public enum GGSnowStyle: String {
    case snow
    case lightning
}

/// "RRGGBB" / "#RRGGBB" → 0xRRGGBB; nil for "" and anything malformed.
public func ggAppearanceParseColor(_ value: String) -> UInt32? {
    var text = value.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("#") {
        text.removeFirst()
    }
    if text.count != 6 {
        return nil
    }
    return UInt32(text, radix: 16)
}

/// 0xRRGGBB → "RRGGBB".
public func ggAppearanceColorString(_ rgb: UInt32) -> String {
    return String(format: "%06X", Int(rgb & 0xffffff))
}
