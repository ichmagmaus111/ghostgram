// The fonts the user added in «Оформление» › «Шрифт» (W2-4, `GGCustomFonts`), for the features that
// draw text in a font of the user's choice — the island badge studio (W2-5). GGAppearance answers.

import Foundation
import GGCore

/// A font file the user added: the family it declares and where the file is.
public struct GGUserFont: Equatable {
    public let familyName: String
    public let fileURL: URL

    public init(familyName: String, fileURL: URL) {
        self.familyName = familyName
        self.fileURL = fileURL
    }
}

public enum GGUserFontsHooks {
    /// Provider: the fonts the user added, in the order added. The files are not registered with
    /// CoreText (only the chosen app font is, at launch): a feature registers what it draws with.
    /// Main thread; answer from memory.
    public static let fonts = GGHookPoint<() -> [GGUserFont]>("fonts.userFonts")

    public static func userFonts() -> [GGUserFont] {
        var result: [GGUserFont] = []
        for handler in GGUserFontsHooks.fonts.handlers {
            result.append(contentsOf: handler())
        }
        return result
    }
}
