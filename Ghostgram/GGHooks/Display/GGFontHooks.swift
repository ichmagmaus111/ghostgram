// Compiled into Display (filegroup //Ghostgram/GGHooks:DisplayHookSources).
// Custom fonts (W2-4): the point lives in Display because `Font` does. The calls in
// `Display/Source/Font.swift` are W2-4's own edits (that file is not frozen); this file only
// gives them a point that GGAppearance can register into.

import Foundation
import UIKit
import GGCore

public struct GGFontRequest {
    public enum Kind {
        /// `Font.with(size:design:weight:width:traits:)`
        case composed
        case regular
        case medium
        case semibold
        case bold
        case heavy
        case light
        case italic
        case semiboldItalic
        case mediumItalic
        case monospace
    }

    public let kind: Kind
    public let size: CGFloat
    public let design: Font.Design
    public let weight: Font.Weight
    public let traits: Font.Traits

    public init(kind: Kind, size: CGFloat, design: Font.Design = .regular, weight: Font.Weight = .regular, traits: Font.Traits = []) {
        self.kind = kind
        self.size = size
        self.design = design
        self.weight = weight
        self.traits = traits
    }
}

public enum GGFontHooks {
    /// Policy: a replacement font, first non-nil wins. Read on every text layout: the handler
    /// answers from its own cache, without disk or UserDefaults.
    public static let font = GGHookPoint<(GGFontRequest) -> UIFont?>("display.font")

    /// For `Font.swift`: `if let font = GGFontHooks.substitute(…) { return font }`.
    public static func substitute(_ request: @autoclosure () -> GGFontRequest) -> UIFont? {
        if GGFontHooks.font.isEmpty {
            return nil
        }
        let value = request()
        for handler in GGFontHooks.font.handlers {
            if let font = handler(value) {
                return font
            }
        }
        return nil
    }
}
