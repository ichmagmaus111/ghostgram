import Foundation
import UIKit
import CoreText
import Display
import LegacyComponents
import GGCore
import GGAppearanceSettings

/// Where a family's faces come from. Nothing is bundled (owner decision 2026-10-22): fonts that ship
/// with iOS, and fonts the user added from Files (owner, 2026-10-27; `GGCustomFonts`).
enum GGFontSource {
    /// A design of the system font: SF Pro Rounded, New York, SF Mono.
    case design(UIFontDescriptor.SystemDesign, properName: String)
    /// A family preinstalled in iOS — or a custom font registered for the process at launch — by its
    /// family name (a proper name, shown as is in every language).
    case installed(String)
}

/// The app font (custom_fonts). What the old code did on every font creation — settings reads from
/// disk, a `stat` of the imported file and `UIFont(name:)` behind a global UIFont swizzle — is gone,
/// and so are the font files:
/// - the family is fixed at launch (upstream keeps fonts in file-scope constants, a live switch would
///   mix fonts), so the menu shows «restart required» instead of calling `exit(0)`;
/// - at launch the chosen family's faces are read once from CoreText (weight, width, italic, Cyrillic)
///   and every (weight, italic) is resolved to a face; nothing is registered, nothing is read from disk;
/// - fonts reach the app through `Font` (GGFontHooks) and the legacy `TGFont`, from a cache keyed by
///   (size, weight, italic, monospaced digits): no work per layout beyond a dictionary lookup.
enum GGFonts {
    /// Menu order of the iOS families: with Cyrillic first, then without (checked with CoreText on the
    /// same families; the «no Cyrillic» mark itself is computed on the device).
    static func source(_ family: GGFontFamily) -> GGFontSource? {
        switch family {
        case .system:
            return nil
        case .rounded:
            return .design(.rounded, properName: "SF Pro Rounded")
        case .serif:
            return .design(.serif, properName: "New York")
        case .monospaced:
            return .design(.monospaced, properName: "SF Mono")
        case .helveticaNeue:
            return .installed("Helvetica Neue")
        case .arial:
            return .installed("Arial")
        case .avenirNext:
            return .installed("Avenir Next")
        case .gillSans:
            return .installed("Gill Sans")
        case .trebuchet:
            return .installed("Trebuchet MS")
        case .verdana:
            return .installed("Verdana")
        case .georgia:
            return .installed("Georgia")
        case .timesNewRoman:
            return .installed("Times New Roman")
        case .palatino:
            return .installed("Palatino")
        case .baskerville:
            return .installed("Baskerville")
        case .charter:
            return .installed("Charter")
        case .cochin:
            return .installed("Cochin")
        case .hoeflerText:
            return .installed("Hoefler Text")
        case .iowanOldStyle:
            return .installed("Iowan Old Style")
        case .rockwell:
            return .installed("Rockwell")
        case .americanTypewriter:
            return .installed("American Typewriter")
        case .markerFelt:
            return .installed("Marker Felt")
        case .noteworthy:
            return .installed("Noteworthy")
        case .chalkboard:
            return .installed("Chalkboard SE")
        case .menlo:
            return .installed("Menlo")
        case .courierNew:
            return .installed("Courier New")
        case .futura:
            return .installed("Futura")
        case .optima:
            return .installed("Optima")
        case .didot:
            return .installed("Didot")
        case .bodoni:
            return .installed("Bodoni 72")
        }
    }

    static var designFamilies: [GGFontFamily] {
        return GGFontFamily.allCases.filter { family in
            if case .design = GGFonts.source(family) {
                return true
            }
            return false
        }
    }

    static var installedFamilies: [GGFontFamily] {
        return GGFontFamily.allCases.filter { family in
            if case .installed = GGFonts.source(family) {
                return true
            }
            return false
        }
    }

    // MARK: Launch

    /// The family in effect for this launch (the setting may change; the font changes on restart).
    private(set) static var launchFamily: GGFontFamily = .system
    /// The custom font in effect for this launch, if one is.
    private(set) static var launchCustomFont: GGCustomFont?
    private static var launchSource: GGFontSource?
    /// Installed family: the face for each (weight, italic), index `weight.rawValue * 2 + (italic ? 1 : 0)`.
    /// Written once in `register()`, before any font is requested; read-only afterwards.
    private static var resolvedFaces: [GGResolvedFace] = []

    static func register() {
        GGCustomFonts.cleanUp()
        let value = GGAppearanceSettings.fontFamily.value
        let source: GGFontSource
        if let customFont = GGCustomFonts.font(forSettingValue: value) {
            guard let familyName = GGCustomFonts.registerForLaunch(customFont), let faces = GGFonts.resolveFaces(familyName: familyName) else {
                GGLog.warning("appearance", "custom font is unreadable, using the system font")
                GGCustomFonts.remove(customFont)
                return
            }
            GGFonts.resolvedFaces = faces
            GGFonts.launchCustomFont = customFont
            source = .installed(familyName)
        } else {
            if GGCustomFonts.isCustomValue(value) {
                // A removed custom font (or one from an imported settings file): the system font.
                GGAppearanceSettings.fontFamily.reset()
                return
            }
            let family = GGFontFamily.resolved(value)
            guard let familySource = GGFonts.source(family) else {
                // The system font: no handlers, upstream fonts untouched.
                return
            }
            switch familySource {
            case let .design(design, _):
                guard UIFont.systemFont(ofSize: 17.0).fontDescriptor.withDesign(design) != nil else {
                    GGLog.warning("appearance", "system font design is not available, using the system font")
                    return
                }
            case let .installed(name):
                guard let faces = GGFonts.resolveFaces(familyName: name) else {
                    GGLog.warning("appearance", "font family is not installed, using the system font")
                    return
                }
                GGFonts.resolvedFaces = faces
            }
            GGFonts.launchFamily = family
            source = familySource
        }
        GGFonts.launchSource = source

        GGFontHooks.font.register({ request in
            return GGFonts.font(for: request)
        }, order: 100)
        TGFontSetSubstitution({ size, weight, italic in
            // TGFont weights: 0 regular, 1 light, 2 medium, 3 semibold, 4 bold.
            let fontWeight: GGFontWeight
            switch weight {
            case 1:
                fontWeight = .light
            case 2:
                fontWeight = .medium
            case 3:
                fontWeight = .semibold
            case 4:
                fontWeight = .bold
            default:
                fontWeight = .regular
            }
            return GGFonts.font(size: size, weight: fontWeight, italic: italic, monospacedDigits: false)
        })
    }

    /// One CoreText pass over the family's faces (≤ 14), then the nearest face for every
    /// (weight, italic). Faces without Latin letters (ornaments) are skipped; condensed or expanded
    /// faces and, in a family that has Cyrillic, faces without it are taken only when nothing closer
    /// exists — so heavy text in Avenir Next stays Cyrillic instead of falling back per letter.
    private static func resolveFaces(familyName: String) -> [GGResolvedFace]? {
        var faces: [GGFontFace] = []
        for name in UIFont.fontNames(forFamilyName: familyName).sorted() {
            let font = CTFontCreateWithName(name as CFString, 17.0, nil)
            guard GGFonts.covers(font, characters: [0x0041, 0x0061]) else {
                continue
            }
            let traits = CTFontCopyTraits(font) as NSDictionary
            let weight = (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0.0
            let width = (traits[kCTFontWidthTrait as String] as? NSNumber)?.doubleValue ?? 0.0
            faces.append(GGFontFace(
                name: name,
                weight: CGFloat(weight),
                isItalic: CTFontGetSymbolicTraits(font).contains(.traitItalic),
                isStandardWidth: abs(width) < 0.01,
                hasCyrillic: GGFonts.hasCyrillic(font)
            ))
        }
        if faces.isEmpty {
            return nil
        }
        let familyHasCyrillic = faces.contains(where: { $0.hasCyrillic })
        var result: [GGResolvedFace] = []
        for weight in GGFontWeight.allCases {
            for italic in [false, true] {
                var best = faces[0]
                var bestScore = CGFloat.greatestFiniteMagnitude
                for face in faces {
                    var score = abs(face.weight - weight.value)
                    if face.isItalic != italic {
                        score += 2.0
                    }
                    if !face.isStandardWidth {
                        score += 1.0
                    }
                    if familyHasCyrillic && !face.hasCyrillic {
                        score += 0.5
                    }
                    if score < bestScore {
                        best = face
                        bestScore = score
                    }
                }
                // No italic face in the family (Marker Felt, Noteworthy…): a slanted upright one, so
                // italic in messages stays visible.
                result.append(GGResolvedFace(name: best.name, isOblique: italic && !best.isItalic))
            }
        }
        return result
    }

    static func covers(_ font: CTFont, characters: [UniChar]) -> Bool {
        var characters = characters
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
    }

    /// «Ж ж Я я».
    static func hasCyrillic(_ font: CTFont) -> Bool {
        return GGFonts.covers(font, characters: [0x0416, 0x0436, 0x042F, 0x044F])
    }

    // MARK: Fonts

    private static let cacheLock = NSLock()
    private static var cache: [Int: UIFont] = [:]

    static func font(for request: GGFontRequest) -> UIFont? {
        switch request.kind {
        case .monospace:
            return nil
        case .composed:
            switch request.design {
            case .regular, .round:
                break
            case .serif, .monospace, .camera:
                return nil
            }
            let weight: GGFontWeight
            switch request.weight {
            case .thin:
                weight = .thin
            case .light:
                weight = .light
            case .regular:
                weight = .regular
            case .medium:
                weight = .medium
            case .semibold:
                weight = .semibold
            case .bold:
                weight = .bold
            case .heavy:
                weight = .heavy
            }
            return GGFonts.font(size: request.size, weight: weight, italic: request.traits.contains(.italic), monospacedDigits: request.traits.contains(.monospacedNumbers))
        case .regular:
            return GGFonts.font(size: request.size, weight: .regular, italic: false, monospacedDigits: false)
        case .light:
            return GGFonts.font(size: request.size, weight: .light, italic: false, monospacedDigits: false)
        case .italic:
            return GGFonts.font(size: request.size, weight: .regular, italic: true, monospacedDigits: false)
        case .medium:
            return GGFonts.font(size: request.size, weight: .medium, italic: false, monospacedDigits: false)
        case .semibold:
            return GGFonts.font(size: request.size, weight: .semibold, italic: false, monospacedDigits: false)
        case .bold:
            return GGFonts.font(size: request.size, weight: .bold, italic: false, monospacedDigits: false)
        case .heavy:
            return GGFonts.font(size: request.size, weight: .heavy, italic: false, monospacedDigits: false)
        case .semiboldItalic:
            return GGFonts.font(size: request.size, weight: .semibold, italic: true, monospacedDigits: false)
        case .mediumItalic:
            return GGFonts.font(size: request.size, weight: .medium, italic: true, monospacedDigits: false)
        }
    }

    static func font(size: CGFloat, weight: GGFontWeight, italic: Bool, monospacedDigits: Bool) -> UIFont? {
        guard let source = GGFonts.launchSource else {
            return nil
        }
        let key = (Int(size * 100.0) << 5) | (weight.rawValue << 2) | (italic ? 2 : 0) | (monospacedDigits ? 1 : 0)
        GGFonts.cacheLock.lock()
        if let font = GGFonts.cache[key] {
            GGFonts.cacheLock.unlock()
            return font
        }
        GGFonts.cacheLock.unlock()

        var descriptor: UIFontDescriptor
        switch source {
        case let .design(design, _):
            descriptor = UIFont.systemFont(ofSize: size, weight: weight.uiWeight).fontDescriptor
            if let designed = descriptor.withDesign(design) {
                descriptor = designed
            }
            if italic, let slanted = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
                descriptor = slanted
            }
        case .installed:
            let index = weight.rawValue * 2 + (italic ? 1 : 0)
            guard index < GGFonts.resolvedFaces.count else {
                return nil
            }
            let face = GGFonts.resolvedFaces[index]
            guard let base = UIFont(name: face.name, size: size) else {
                return nil
            }
            descriptor = base.fontDescriptor
            if face.isOblique {
                descriptor = descriptor.addingAttributes([
                    .matrix: NSValue(cgAffineTransform: CGAffineTransform(a: 1.0, b: 0.0, c: 0.2, d: 1.0, tx: 0.0, ty: 0.0))
                ])
            }
        }
        if monospacedDigits {
            descriptor = descriptor.addingAttributes([
                .featureSettings: [[
                    UIFontDescriptor.FeatureKey.type.rawValue: kNumberSpacingType,
                    UIFontDescriptor.FeatureKey.selector.rawValue: kMonospacedNumbersSelector
                ]]
            ])
        }
        let font = UIFont(descriptor: descriptor, size: size)

        GGFonts.cacheLock.lock()
        GGFonts.cache[key] = font
        GGFonts.cacheLock.unlock()
        return font
    }

    // MARK: Menu (main thread)

    private static var sampleCache: [String: UIImage] = [:]
    private static var menuFaceCache: [GGFontFamily: GGMenuFace] = [:]

    /// The family's regular face as the menu needs it: one CoreText lookup per family, cached for the
    /// life of the process (the set of installed fonts does not change while the app runs).
    private static func menuFace(_ family: GGFontFamily) -> GGMenuFace {
        if let cached = GGFonts.menuFaceCache[family] {
            return cached
        }
        let face: GGMenuFace
        switch GGFonts.source(family) {
        case .none:
            face = GGMenuFace(isAvailable: true, hasCyrillic: true, descriptor: UIFont.systemFont(ofSize: 20.0).fontDescriptor)
        case let .design(design, _)?:
            if let descriptor = UIFont.systemFont(ofSize: 20.0).fontDescriptor.withDesign(design) {
                face = GGMenuFace(isAvailable: true, hasCyrillic: GGFonts.hasCyrillic(UIFont(descriptor: descriptor, size: 20.0) as CTFont), descriptor: descriptor)
            } else {
                face = GGMenuFace(isAvailable: false, hasCyrillic: false, descriptor: nil)
            }
        case let .installed(name)?:
            if UIFont.fontNames(forFamilyName: name).isEmpty {
                face = GGMenuFace(isAvailable: false, hasCyrillic: false, descriptor: nil)
            } else {
                let descriptor = UIFontDescriptor(fontAttributes: [.family: name])
                face = GGMenuFace(isAvailable: true, hasCyrillic: GGFonts.hasCyrillic(UIFont(descriptor: descriptor, size: 20.0) as CTFont), descriptor: descriptor)
            }
        }
        GGFonts.menuFaceCache[family] = face
        return face
    }

    /// Not every iOS version carries every family: a missing one has no row.
    static func isAvailable(_ family: GGFontFamily) -> Bool {
        return GGFonts.menuFace(family).isAvailable
    }

    static func hasCyrillic(_ family: GGFontFamily) -> Bool {
        return GGFonts.menuFace(family).hasCyrillic
    }

    /// The choice the menu shows: the stored family, or the system font when the value is unknown
    /// (a removed font) or the family is missing on this device — exactly what `register()` applies.
    /// `.system` while a custom font is chosen: check `selectedCustomFont` first.
    static var selectedFamily: GGFontFamily {
        let family = GGFontFamily.resolved(GGAppearanceSettings.fontFamily.value)
        return GGFonts.isAvailable(family) ? family : .system
    }

    static var selectedCustomFont: GGCustomFont? {
        return GGCustomFonts.font(forSettingValue: GGAppearanceSettings.fontFamily.value)
    }

    /// The chosen font differs from the one this launch applied: the menu says «restart».
    static var needsRestart: Bool {
        if let selectedCustomFont = GGFonts.selectedCustomFont {
            return selectedCustomFont != GGFonts.launchCustomFont
        }
        return GGFonts.launchCustomFont != nil || GGFonts.selectedFamily != GGFonts.launchFamily
    }

    /// The name of the chosen font (the font row's value in «Сообщения»).
    static var selectedDisplayName: String {
        if let selectedCustomFont = GGFonts.selectedCustomFont {
            return selectedCustomFont.familyName
        }
        return GGFonts.displayName(GGFonts.selectedFamily)
    }

    /// A sample of a custom font, drawn from its file. Cached per (file, color, text).
    static func sampleImage(customFont: GGCustomFont, color: UIColor) -> UIImage? {
        let sample = GGStrings.Appearance.Font.sample
        let cacheKey = "custom_\(customFont.fileName)_\(color.argb)_\(sample)"
        if let image = GGFonts.sampleCache[cacheKey] {
            return image
        }
        guard let font = GGCustomFonts.menuFont(customFont, size: 20.0) else {
            return nil
        }
        let image = GGFonts.renderSample(sample, font: font, color: color)
        GGFonts.sampleCache[cacheKey] = image
        return image
    }

    static func hasCyrillic(_ customFont: GGCustomFont) -> Bool {
        guard let font = GGCustomFonts.menuFont(customFont, size: 20.0) else {
            return false
        }
        return GGFonts.hasCyrillic(font as CTFont)
    }

    private static func renderSample(_ sample: String, font: UIFont, color: UIColor) -> UIImage {
        let text = NSAttributedString(string: sample, attributes: [.font: font, .foregroundColor: color])
        let size = CGSize(width: 64.0, height: 28.0)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let bounds = text.boundingRect(with: size, options: [.usesLineFragmentOrigin], context: nil)
            text.draw(at: CGPoint(x: 0.0, y: floor((size.height - bounds.height) / 2.0)))
        }
    }

    /// A sample of a family for the menu, drawn with the family's regular face. Cached per
    /// (family, color, text).
    static func sampleImage(family: GGFontFamily, color: UIColor) -> UIImage? {
        let sample = GGStrings.Appearance.Font.sample
        let cacheKey = "\(family.rawValue)_\(color.argb)_\(sample)"
        if let image = GGFonts.sampleCache[cacheKey] {
            return image
        }
        guard let descriptor = GGFonts.menuFace(family).descriptor else {
            return nil
        }
        let image = GGFonts.renderSample(sample, font: UIFont(descriptor: descriptor, size: 20.0), color: color)
        GGFonts.sampleCache[cacheKey] = image
        return image
    }

    static func displayName(_ family: GGFontFamily) -> String {
        switch family {
        case .system:
            return GGStrings.Appearance.Font.system
        case .rounded:
            return GGStrings.Appearance.Font.rounded
        case .serif:
            return GGStrings.Appearance.Font.serif
        case .monospaced:
            return GGStrings.Appearance.Font.monospaced
        default:
            if case let .installed(name)? = GGFonts.source(family) {
                return name
            }
            return family.rawValue
        }
    }

    /// Apple's name of the system font or of its design (shown as is in every language); nil for an
    /// installed family, whose title already is its name.
    static func properName(_ family: GGFontFamily) -> String? {
        if family == .system {
            return "SF Pro"
        }
        if case let .design(_, properName)? = GGFonts.source(family) {
            return properName
        }
        return nil
    }

    /// The row's second line: the proper name of a system design, and «no Cyrillic» where Russian
    /// text would fall back to the system font letter by letter.
    static func detail(_ family: GGFontFamily) -> String? {
        var parts: [String] = []
        if let properName = GGFonts.properName(family) {
            parts.append(properName)
        }
        if !GGFonts.hasCyrillic(family) {
            parts.append(GGStrings.Appearance.Font.noCyrillic)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum GGFontWeight: Int, CaseIterable {
    case thin = 0
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy

    var uiWeight: UIFont.Weight {
        switch self {
        case .thin:
            return .thin
        case .light:
            return .light
        case .regular:
            return .regular
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        case .bold:
            return .bold
        case .heavy:
            return .heavy
        }
    }

    /// CoreText's normalized weight (`kCTFontWeightTrait`, the same scale as `UIFont.Weight`).
    var value: CGFloat {
        return self.uiWeight.rawValue
    }
}

private struct GGFontFace {
    let name: String
    let weight: CGFloat
    let isItalic: Bool
    let isStandardWidth: Bool
    let hasCyrillic: Bool
}

private struct GGResolvedFace {
    let name: String
    /// Italic was asked for and the family has none: the face is slanted by a matrix.
    let isOblique: Bool
}

private struct GGMenuFace {
    let isAvailable: Bool
    let hasCyrillic: Bool
    let descriptor: UIFontDescriptor?
}
