import Foundation

// Choices that replaced pairs and groups of switches on 2026-10-27 (owner: «сжать меню»), with the
// rules that carry the old values over. Foundation only: host-tested.

/// «Скрывать реакции»: nowhere / in chats / in channels / everywhere.
public enum GGHiddenReactions: String, CaseIterable {
    case off
    case chats
    case channels
    case all

    public var inChats: Bool {
        return self == .chats || self == .all
    }

    public var inChannels: Bool {
        return self == .channels || self == .all
    }

    public init(inChats: Bool, inChannels: Bool) {
        switch (inChats, inChannels) {
        case (true, true):
            self = .all
        case (true, false):
            self = .chats
        case (false, true):
            self = .channels
        case (false, false):
            self = .off
        }
    }

    /// Two switches (nil = never stored = off) → the choice; nil when nothing has to be written.
    public static func merged(inChats: Bool?, inChannels: Bool?) -> GGHiddenReactions? {
        let value = GGHiddenReactions(inChats: inChats ?? false, inChannels: inChannels ?? false)
        return value == .off ? nil : value
    }
}

/// «Без форматирования»: nowhere / in incoming / in own messages / everywhere.
public enum GGHiddenFormatting: String, CaseIterable {
    case off
    case incoming
    case outgoing
    case all

    public var inIncoming: Bool {
        return self == .incoming || self == .all
    }

    public var inOutgoing: Bool {
        return self == .outgoing || self == .all
    }

    public init(inIncoming: Bool, inOutgoing: Bool) {
        switch (inIncoming, inOutgoing) {
        case (true, true):
            self = .all
        case (true, false):
            self = .incoming
        case (false, true):
            self = .outgoing
        case (false, false):
            self = .off
        }
    }

    public static func merged(inIncoming: Bool?, inOutgoing: Bool?) -> GGHiddenFormatting? {
        let value = GGHiddenFormatting(inIncoming: inIncoming ?? false, inOutgoing: inOutgoing ?? false)
        return value == .off ? nil : value
    }
}

/// «Затемнение краёв»: one kind of band at the top and bottom of chats.
public enum GGEdgeStyle: String, CaseIterable {
    case off
    /// Blur under the header and above the input panel, in chats only.
    case blur
    /// A colored band fading towards the middle, in chats and (unless hidden) the chat list.
    case gradient

    /// The band height in pt and its bounds.
    public static let sizeRange: ClosedRange<Double> = 8.0 ... 160.0
    public static let defaultSize: Double = 80.0
    public static let defaultIntensity: Double = 100.0
}

/// What the nine screen-edge settings of builds ≤ 185 become: style, color, height, strength and
/// «not in the chat list». nil fields are not written (the new default stays).
public struct GGEdgeMerge: Equatable {
    public var style: GGEdgeStyle
    public var color: String?
    public var size: Double?
    public var intensity: Double?
    public var hideInChatList: Bool?

    public init(style: GGEdgeStyle, color: String? = nil, size: Double? = nil, intensity: Double? = nil, hideInChatList: Bool? = nil) {
        self.style = style
        self.color = color
        self.size = size
        self.intensity = intensity
        self.hideInChatList = hideInChatList
    }

    /// The old values as stored (nil = never written = the old default: blur 80 pt, gradient
    /// 40 pt, strength 100 %, automatic color).
    public struct Old: Equatable {
        public var blur: Bool?
        public var blurColor: String?
        public var blurSize: Double?
        public var blurIntensity: Double?
        public var gradient: Bool?
        public var gradientColor: String?
        public var gradientSize: Double?
        public var gradientIntensity: Double?
        public var gradientHideInChatList: Bool?

        public init(blur: Bool? = nil, blurColor: String? = nil, blurSize: Double? = nil, blurIntensity: Double? = nil, gradient: Bool? = nil, gradientColor: String? = nil, gradientSize: Double? = nil, gradientIntensity: Double? = nil, gradientHideInChatList: Bool? = nil) {
            self.blur = blur
            self.blurColor = blurColor
            self.blurSize = blurSize
            self.blurIntensity = blurIntensity
            self.gradient = gradient
            self.gradientColor = gradientColor
            self.gradientSize = gradientSize
            self.gradientIntensity = gradientIntensity
            self.gradientHideInChatList = gradientHideInChatList
        }
    }

    static let oldBlurSize: Double = 80.0
    static let oldGradientSize: Double = 40.0

    /// The blur wins when both were on. The chosen kind keeps exactly what it showed (its stored
    /// values, else its old defaults — the gradient was 40 pt, the new default is 80). With both
    /// off nothing turns on; the values the user tuned are kept, the blur's first.
    public static func merged(_ old: Old) -> GGEdgeMerge? {
        var result: GGEdgeMerge
        if old.blur == true {
            result = GGEdgeMerge(style: .blur, color: old.blurColor, size: old.blurSize ?? GGEdgeMerge.oldBlurSize, intensity: old.blurIntensity)
        } else if old.gradient == true {
            result = GGEdgeMerge(style: .gradient, color: old.gradientColor, size: old.gradientSize ?? GGEdgeMerge.oldGradientSize, intensity: old.gradientIntensity)
        } else {
            result = GGEdgeMerge(style: .off, color: old.blurColor ?? old.gradientColor, size: old.blurSize ?? old.gradientSize, intensity: old.blurIntensity ?? old.gradientIntensity)
        }
        result.hideInChatList = old.gradientHideInChatList
        if let size = result.size {
            result.size = min(GGEdgeStyle.sizeRange.upperBound, max(GGEdgeStyle.sizeRange.lowerBound, size))
        }
        if let intensity = result.intensity {
            result.intensity = min(100.0, max(0.0, intensity))
        }
        if result.color?.isEmpty == true {
            result.color = nil
        }
        // Nothing stored at all: nothing to write.
        if result == GGEdgeMerge(style: .off) {
            return nil
        }
        return result
    }
}
