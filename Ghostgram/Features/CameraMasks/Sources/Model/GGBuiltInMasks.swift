import Foundation
import GGCore

/// The masks that ship with the app. They are ordinary manifests rendered by the same engine as
/// catalog and own masks (one code path), and they never touch the disk or the network.
enum GGBuiltInMasks {
    static let ids: [String] = [
        "autoBlur", "pixelate", "heavyFaceBlur", "backgroundBlur",
        "colorNoir", "sepiaVintage", "chrome", "fade", "warmTone", "coldTone",
        "emojiFire", "emojiSkull", "emojiGhost", "emojiAlien", "emojiClown", "emojiRobot", "emojiCool"
    ]

    static func manifest(id: String) -> GGMaskManifest? {
        let effects: [GGMaskEffect]
        switch id {
        case "autoBlur":
            effects = [GGMaskEffect.filter("blur.gaussianFace", params: ["radius": .number(28.0)])]
        case "heavyFaceBlur":
            effects = [GGMaskEffect.filter("blur.gaussianFace", params: ["radius": .number(45.0)])]
        case "pixelate":
            effects = [GGMaskEffect.filter("blur.pixelFace", params: ["scale": .number(24.0)])]
        case "backgroundBlur":
            effects = [GGMaskEffect.filter("blur.background", params: ["radius": .number(18.0)])]
        case "colorNoir":
            effects = [GGMaskEffect(type: .colorFilter, preset: .noir)]
        case "sepiaVintage":
            effects = [GGMaskEffect(type: .colorFilter, preset: .sepia)]
        case "chrome":
            effects = [GGMaskEffect(type: .colorFilter, preset: .chrome)]
        case "fade":
            effects = [GGMaskEffect(type: .colorFilter, preset: .fade)]
        case "warmTone":
            effects = [GGMaskEffect(type: .colorFilter, preset: .warm)]
        case "coldTone":
            effects = [GGMaskEffect(type: .colorFilter, preset: .cold)]
        default:
            guard let emoji = GGBuiltInMasks.emoji(id: id) else {
                return nil
            }
            effects = [GGMaskEffect(type: .emojiHead, emoji: emoji)]
        }
        return GGMaskManifest(id: id, name: [:], effects: effects)
    }

    /// Glyph of the mask's chip.
    static func glyph(id: String) -> String {
        if let emoji = GGBuiltInMasks.emoji(id: id) {
            return emoji
        }
        switch id {
        case "autoBlur", "heavyFaceBlur":
            return "🌫"
        case "pixelate":
            return "🟪"
        case "backgroundBlur":
            return "🧍"
        case "colorNoir":
            return "⚫️"
        case "sepiaVintage":
            return "🟤"
        case "chrome":
            return "💿"
        case "fade":
            return "🌁"
        case "warmTone":
            return "🌅"
        case "coldTone":
            return "🧊"
        default:
            return "🎭"
        }
    }

    private static func emoji(id: String) -> String? {
        switch id {
        case "emojiFire":
            return "🔥"
        case "emojiSkull":
            return "💀"
        case "emojiGhost":
            return "👻"
        case "emojiAlien":
            return "👽"
        case "emojiClown":
            return "🤡"
        case "emojiRobot":
            return "🤖"
        case "emojiCool":
            return "😎"
        default:
            return nil
        }
    }

    static func title(id: String) -> String {
        switch id {
        case "autoBlur":
            return GGStrings.CameraMasks.BuiltIn.autoBlur
        case "heavyFaceBlur":
            return GGStrings.CameraMasks.BuiltIn.heavyFaceBlur
        case "pixelate":
            return GGStrings.CameraMasks.BuiltIn.pixelate
        case "backgroundBlur":
            return GGStrings.CameraMasks.BuiltIn.backgroundBlur
        case "colorNoir":
            return GGStrings.CameraMasks.BuiltIn.colorNoir
        case "sepiaVintage":
            return GGStrings.CameraMasks.BuiltIn.sepiaVintage
        case "chrome":
            return GGStrings.CameraMasks.BuiltIn.chrome
        case "fade":
            return GGStrings.CameraMasks.BuiltIn.fade
        case "warmTone":
            return GGStrings.CameraMasks.BuiltIn.warmTone
        case "coldTone":
            return GGStrings.CameraMasks.BuiltIn.coldTone
        case "emojiFire":
            return GGStrings.CameraMasks.BuiltIn.emojiFire
        case "emojiSkull":
            return GGStrings.CameraMasks.BuiltIn.emojiSkull
        case "emojiGhost":
            return GGStrings.CameraMasks.BuiltIn.emojiGhost
        case "emojiAlien":
            return GGStrings.CameraMasks.BuiltIn.emojiAlien
        case "emojiClown":
            return GGStrings.CameraMasks.BuiltIn.emojiClown
        case "emojiRobot":
            return GGStrings.CameraMasks.BuiltIn.emojiRobot
        case "emojiCool":
            return GGStrings.CameraMasks.BuiltIn.emojiCool
        default:
            return id
        }
    }
}
