import Foundation
import CoreGraphics

// The mask format: one manifest = an ordered chain of effects. The JSON is the one older Ghostgram
// versions wrote (`.ggmask` files, the catalog on the server, user masks), so those keep opening.
// Decoding is tolerant: an unknown effect type is dropped, an unknown value of an enum field becomes
// nil instead of failing the whole manifest, and a newer `version` still decodes what it knows.

public enum GGMaskEffectType: String, CaseIterable {
    case blur
    case pixelate
    case sticker2d
    case colorFilter
    case backgroundReplace
    case glitchRGB
    case faceDistort
    case emojiHead
    case filter
}

public enum GGMaskAnchor: String, CaseIterable {
    case face
    case eyes
    case leftEye
    case rightEye
    case nose
    case mouth
    case forehead
    case chin
    case fullFrame
}

public enum GGMaskColorPreset: String, CaseIterable {
    case sepia
    case noir
    case chrome
    case fade
    case warm
    case cold
    case vhs
}

public enum GGMaskDistortKind: String, CaseIterable {
    case bulge
    case pinch
    case twirl
}

public enum GGMaskBlendMode: String, CaseIterable {
    case normal
    case multiply
    case screen
    case overlay
    case softLight
    case hardLight
    case darken
    case lighten
    case difference
    case exclusion
    case hue
    case saturation
    case color
    case luminosity
    case add

    var filterName: String {
        switch self {
        case .normal:
            return "CISourceOverCompositing"
        case .multiply:
            return "CIMultiplyBlendMode"
        case .screen:
            return "CIScreenBlendMode"
        case .overlay:
            return "CIOverlayBlendMode"
        case .softLight:
            return "CISoftLightBlendMode"
        case .hardLight:
            return "CIHardLightBlendMode"
        case .darken:
            return "CIDarkenBlendMode"
        case .lighten:
            return "CILightenBlendMode"
        case .difference:
            return "CIDifferenceBlendMode"
        case .exclusion:
            return "CIExclusionBlendMode"
        case .hue:
            return "CIHueBlendMode"
        case .saturation:
            return "CISaturationBlendMode"
        case .color:
            return "CIColorBlendMode"
        case .luminosity:
            return "CILuminosityBlendMode"
        case .add:
            return "CIAdditionCompositing"
        }
    }
}

/// A tagged parameter value: `{"k":"number","v":0.5}`. Unknown or malformed values decode to
/// `.unknown` and read as «missing» (the filter's default is used).
public enum GGMaskParamValue: Equatable {
    case number(Double)
    case bool(Bool)
    case color(String)
    case point(CGPoint)
    case text(String)
    case numbers([Double])
    case unknown

    var number: Double? {
        switch self {
        case let .number(value):
            return value
        case let .bool(value):
            return value ? 1.0 : 0.0
        case let .numbers(values):
            return values.first
        default:
            return nil
        }
    }

    var bool: Bool? {
        switch self {
        case let .bool(value):
            return value
        case let .number(value):
            return value >= 0.5
        default:
            return nil
        }
    }

    var text: String? {
        switch self {
        case let .text(value):
            return value
        case let .color(value):
            return value
        default:
            return nil
        }
    }

    var point: CGPoint? {
        if case let .point(value) = self {
            return value
        }
        return nil
    }

    var numbers: [Double]? {
        switch self {
        case let .numbers(values):
            return values
        case let .number(value):
            return [value]
        default:
            return nil
        }
    }
}

extension GGMaskParamValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case k
        case v
    }

    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self), let kind = try? container.decode(String.self, forKey: .k) else {
            self = .unknown
            return
        }
        switch kind {
        case "number":
            self = (try? container.decode(Double.self, forKey: .v)).map { .number($0) } ?? .unknown
        case "bool":
            self = (try? container.decode(Bool.self, forKey: .v)).map { .bool($0) } ?? .unknown
        case "color":
            self = (try? container.decode(String.self, forKey: .v)).map { .color($0) } ?? .unknown
        case "text":
            self = (try? container.decode(String.self, forKey: .v)).map { .text($0) } ?? .unknown
        case "point":
            if let values = try? container.decode([Double].self, forKey: .v), values.count == 2 {
                self = .point(CGPoint(x: values[0], y: values[1]))
            } else {
                self = .unknown
            }
        case "numbers":
            self = (try? container.decode([Double].self, forKey: .v)).map { .numbers($0) } ?? .unknown
        default:
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .number(value):
            try container.encode("number", forKey: .k)
            try container.encode(value, forKey: .v)
        case let .bool(value):
            try container.encode("bool", forKey: .k)
            try container.encode(value, forKey: .v)
        case let .color(value):
            try container.encode("color", forKey: .k)
            try container.encode(value, forKey: .v)
        case let .text(value):
            try container.encode("text", forKey: .k)
            try container.encode(value, forKey: .v)
        case let .point(value):
            try container.encode("point", forKey: .k)
            try container.encode([Double(value.x), Double(value.y)], forKey: .v)
        case let .numbers(values):
            try container.encode("numbers", forKey: .k)
            try container.encode(values, forKey: .v)
        case .unknown:
            try container.encode("unknown", forKey: .k)
        }
    }
}

/// One link of the effect chain.
public struct GGMaskEffect: Equatable {
    public var type: GGMaskEffectType
    public var asset: String?
    public var anchor: GGMaskAnchor?
    public var scale: Double?
    public var offset: [Double]?
    public var preset: GGMaskColorPreset?
    public var backgroundMode: String?
    public var backgroundAsset: String?
    public var backgroundColor: String?
    public var intensity: Double?
    public var emoji: String?
    public var distortKind: GGMaskDistortKind?
    public var filterId: String?
    public var params: [String: GGMaskParamValue]?
    public var opacity: Double?
    public var enabled: Bool?

    public init(type: GGMaskEffectType, asset: String? = nil, anchor: GGMaskAnchor? = nil, scale: Double? = nil, offset: [Double]? = nil, preset: GGMaskColorPreset? = nil, backgroundMode: String? = nil, backgroundAsset: String? = nil, backgroundColor: String? = nil, intensity: Double? = nil, emoji: String? = nil, distortKind: GGMaskDistortKind? = nil, filterId: String? = nil, params: [String: GGMaskParamValue]? = nil, opacity: Double? = nil, enabled: Bool? = nil) {
        self.type = type
        self.asset = asset
        self.anchor = anchor
        self.scale = scale
        self.offset = offset
        self.preset = preset
        self.backgroundMode = backgroundMode
        self.backgroundAsset = backgroundAsset
        self.backgroundColor = backgroundColor
        self.intensity = intensity
        self.emoji = emoji
        self.distortKind = distortKind
        self.filterId = filterId
        self.params = params
        self.opacity = opacity
        self.enabled = enabled
    }

    /// A studio layer: a catalog filter with its parameters.
    public static func filter(_ id: String, params: [String: GGMaskParamValue] = [:]) -> GGMaskEffect {
        return GGMaskEffect(type: .filter, filterId: id, params: params)
    }

    public var isEnabled: Bool {
        return self.enabled ?? true
    }

    /// Names of the asset files this effect reads (for packaging and garbage collection).
    var referencedAssets: [String] {
        var result: [String] = []
        if let asset = self.asset, !asset.isEmpty {
            result.append(asset)
        }
        if let asset = self.backgroundAsset, !asset.isEmpty {
            result.append(asset)
        }
        return result
    }

    /// The anchor the effect is placed at: the effect's own, else its `anchor` parameter.
    var effectiveAnchor: GGMaskAnchor? {
        if let anchor = self.anchor {
            return anchor
        }
        if let text = self.params?["anchor"]?.text {
            return GGMaskAnchor(rawValue: text)
        }
        return nil
    }
}

extension GGMaskEffect: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case asset
        case anchor
        case scale
        case offset
        case preset
        case backgroundMode
        case backgroundAsset
        case backgroundColor
        case intensity
        case emoji
        case distortKind
        case filterId
        case params
        case opacity
        case enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeName = try container.decode(String.self, forKey: .type)
        guard let type = GGMaskEffectType(rawValue: typeName) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unsupported effect type")
        }
        self.type = type
        self.asset = try? container.decodeIfPresent(String.self, forKey: .asset)
        self.anchor = (try? container.decodeIfPresent(String.self, forKey: .anchor)).flatMap(GGMaskAnchor.init(rawValue:))
        self.scale = try? container.decodeIfPresent(Double.self, forKey: .scale)
        self.offset = try? container.decodeIfPresent([Double].self, forKey: .offset)
        self.preset = (try? container.decodeIfPresent(String.self, forKey: .preset)).flatMap(GGMaskColorPreset.init(rawValue:))
        self.backgroundMode = try? container.decodeIfPresent(String.self, forKey: .backgroundMode)
        self.backgroundAsset = try? container.decodeIfPresent(String.self, forKey: .backgroundAsset)
        self.backgroundColor = try? container.decodeIfPresent(String.self, forKey: .backgroundColor)
        self.intensity = try? container.decodeIfPresent(Double.self, forKey: .intensity)
        self.emoji = try? container.decodeIfPresent(String.self, forKey: .emoji)
        self.distortKind = (try? container.decodeIfPresent(String.self, forKey: .distortKind)).flatMap(GGMaskDistortKind.init(rawValue:))
        self.filterId = try? container.decodeIfPresent(String.self, forKey: .filterId)
        self.params = try? container.decodeIfPresent([String: GGMaskParamValue].self, forKey: .params)
        self.opacity = try? container.decodeIfPresent(Double.self, forKey: .opacity)
        self.enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.type.rawValue, forKey: .type)
        try container.encodeIfPresent(self.asset, forKey: .asset)
        try container.encodeIfPresent(self.anchor?.rawValue, forKey: .anchor)
        try container.encodeIfPresent(self.scale, forKey: .scale)
        try container.encodeIfPresent(self.offset, forKey: .offset)
        try container.encodeIfPresent(self.preset?.rawValue, forKey: .preset)
        try container.encodeIfPresent(self.backgroundMode, forKey: .backgroundMode)
        try container.encodeIfPresent(self.backgroundAsset, forKey: .backgroundAsset)
        try container.encodeIfPresent(self.backgroundColor, forKey: .backgroundColor)
        try container.encodeIfPresent(self.intensity, forKey: .intensity)
        try container.encodeIfPresent(self.emoji, forKey: .emoji)
        try container.encodeIfPresent(self.distortKind?.rawValue, forKey: .distortKind)
        try container.encodeIfPresent(self.filterId, forKey: .filterId)
        try container.encodeIfPresent(self.params, forKey: .params)
        try container.encodeIfPresent(self.opacity, forKey: .opacity)
        try container.encodeIfPresent(self.enabled, forKey: .enabled)
    }
}

/// A whole mask.
public struct GGMaskManifest: Equatable {
    public var id: String
    /// Localized names: `{"ru": "...", "en": "..."}`.
    public var name: [String: String]
    public var version: Int
    public var effects: [GGMaskEffect]

    public init(id: String, name: [String: String], version: Int = 1, effects: [GGMaskEffect]) {
        self.id = id
        self.name = name
        self.version = version
        self.effects = effects
    }

    public func displayName(languageCode: String) -> String {
        if let value = self.name[languageCode], !value.isEmpty {
            return value
        }
        if let value = self.name["en"], !value.isEmpty {
            return value
        }
        if let value = self.name.values.first(where: { !$0.isEmpty }) {
            return value
        }
        return self.id
    }

    var activeEffects: [GGMaskEffect] {
        return self.effects.filter { $0.isEnabled }
    }

    var referencedAssets: Set<String> {
        var result = Set<String>()
        for effect in self.effects {
            for name in effect.referencedAssets {
                result.insert(name)
            }
        }
        return result
    }

    /// Union of what the enabled effects need from Vision.
    var visionNeeds: GGVisionNeeds {
        var needs = GGVisionNeeds()
        for effect in self.effects where effect.isEnabled {
            needs.formUnion(GGFilterCatalog.visionNeeds(of: effect))
        }
        return needs
    }
}

extension GGMaskManifest: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case effects
    }

    /// Wraps an effect that may fail to decode (unknown type): the manifest keeps the rest.
    private struct LossyEffect: Decodable {
        let effect: GGMaskEffect?

        init(from decoder: Decoder) throws {
            self.effect = try? GGMaskEffect(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = (try? container.decode([String: String].self, forKey: .name)) ?? [:]
        self.version = (try? container.decode(Int.self, forKey: .version)) ?? 1
        let effects = (try? container.decode([LossyEffect].self, forKey: .effects)) ?? []
        self.effects = effects.compactMap { item -> GGMaskEffect? in
            guard let effect = item.effect else {
                return nil
            }
            if effect.type == .filter {
                guard let filterId = effect.filterId, GGFilterCatalog.descriptor(filterId) != nil else {
                    return nil
                }
            }
            return effect
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.version, forKey: .version)
        try container.encode(self.effects, forKey: .effects)
    }
}

/// What a mask needs from Vision for its face-bound effects.
public struct GGVisionNeeds: OptionSet, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let face = GGVisionNeeds(rawValue: 1 << 0)
    /// Includes `face`.
    public static let landmarks = GGVisionNeeds(rawValue: (1 << 0) | (1 << 1))
    public static let segmentation = GGVisionNeeds(rawValue: 1 << 2)
}

/// What the user picked: none, a built-in mask, a mask from the catalog, an own mask.
/// Stored as a short string: "", "builtin:<id>", "catalog:<id>", "user:<id>".
public enum GGMaskSelection: Equatable, Hashable {
    case none
    case builtIn(String)
    case catalog(String)
    case user(String)

    public init(storage: String) {
        if storage.hasPrefix("builtin:") {
            let id = String(storage.dropFirst("builtin:".count))
            self = GGBuiltInMasks.manifest(id: id) != nil ? .builtIn(id) : .none
        } else if storage.hasPrefix("catalog:") {
            let id = String(storage.dropFirst("catalog:".count))
            self = id.isEmpty ? .none : .catalog(id)
        } else if storage.hasPrefix("user:") {
            let id = String(storage.dropFirst("user:".count))
            self = id.isEmpty ? .none : .user(id)
        } else {
            self = .none
        }
    }

    public var storage: String {
        switch self {
        case .none:
            return ""
        case let .builtIn(id):
            return "builtin:" + id
        case let .catalog(id):
            return "catalog:" + id
        case let .user(id):
            return "user:" + id
        }
    }

    /// Old Ghostgram stored `{"kind":"native|remote|custom","id":…}` JSON.
    public static func fromLegacy(_ value: String) -> GGMaskSelection? {
        guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let kind = object["kind"] as? String, let id = object["id"] as? String, !id.isEmpty else {
            return nil
        }
        switch kind {
        case "native":
            return GGBuiltInMasks.manifest(id: id) != nil ? .builtIn(id) : nil
        case "remote":
            return .catalog(id)
        case "custom":
            return .user(id)
        default:
            return nil
        }
    }

    /// The same choice from an id alone (the anonymous-mode mask id of the old app).
    public static func fromLegacyMaskId(_ id: String) -> GGMaskSelection {
        if GGBuiltInMasks.manifest(id: id) != nil {
            return .builtIn(id)
        }
        if id.hasPrefix("user.") {
            return .user(id)
        }
        if id.isEmpty {
            return .none
        }
        return .catalog(id)
    }
}

/// Parses `#RRGGBB` / `RRGGBBAA` (the `#` is optional).
func ggParseHexColor(_ text: String) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
    var value = text.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("#") {
        value.removeFirst()
    }
    guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else {
        return nil
    }
    if value.count == 6 {
        return (CGFloat((number >> 16) & 0xff) / 255.0, CGFloat((number >> 8) & 0xff) / 255.0, CGFloat(number & 0xff) / 255.0, 1.0)
    } else {
        return (CGFloat((number >> 24) & 0xff) / 255.0, CGFloat((number >> 16) & 0xff) / 255.0, CGFloat((number >> 8) & 0xff) / 255.0, CGFloat(number & 0xff) / 255.0)
    }
}
