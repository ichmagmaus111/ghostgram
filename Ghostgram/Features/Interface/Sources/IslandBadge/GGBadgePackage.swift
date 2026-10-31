import Foundation
import UIKit
import GGCore

/// `.ggbadge` as the old Ghostgram writes it — and as this client writes it too, so a badge goes
/// both ways between the two: one JSON object
///
///     {"format": "ggbadge", "version": 1, "document": {…}, "assets": {"<file>": "<base64>"}}
///
/// The document is the old Badge Studio model: `background` as Swift writes its enum
/// (`{"transparent": {}}`, `{"solid": {"_0": {"hex": "#RRGGBB"}}}`,
/// `{"gradient": {"from": …, "to": …, "angle": 0}}`), layers with `content` as
/// `{"text": {"_0": {…}}}` / `{"image": {"_0": {…}}}`, `offset` as `[x, y]` from the canvas centre.
/// Read as tolerantly as the old client reads it: the flat hand-written layer form
/// (`{"type": "text", "string": "…"}`), bare `"#RRGGBB"` colors, only `layers` required, and a
/// document of this client's own model too. The zip archives earlier builds of this client wrote
/// are read by the gallery.
enum GGBadgePackage {
    static let fileExtension = "ggbadge"

    /// Names a `format` field may carry; another name is not a badge (a `.ggmask` is rejected).
    private static let acceptedFormats: Set<String> = ["ggbadge", "badge", "gg-badge", "ghostgram-badge"]
    /// The studio's own limit: a badge made here is read back whole.
    private static let maxLayers = GGBadgeDocument.maxLayers
    private static let maxAssetBytes = 4 * 1024 * 1024

    // MARK: Reading

    /// The badge of a JSON package with its pictures (file names as the document uses them), or nil
    /// when the data is not one.
    static func decode(_ data: Data) -> (document: GGBadgeDocument, assets: [(String, UIImage)])? {
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else {
            return nil
        }
        if let format = root["format"] as? String, !GGBadgePackage.acceptedFormats.contains(format.lowercased()) {
            return nil
        }
        let documentObject: [String: Any]
        if let value = root["document"] as? [String: Any] {
            documentObject = value
        } else if root["layers"] != nil {
            documentObject = root
        } else {
            return nil
        }
        guard let layerObjects = documentObject["layers"] as? [Any] else {
            return nil
        }

        var document: GGBadgeDocument
        if let own = GGBadgePackage.ownDocument(documentObject) {
            document = own
        } else {
            document = GGBadgeDocument.new(name: GGStrings.Interface.Badge.defaultName, text: "")
            document.layers = []
            if let cornerRadius = GGBadgePackage.number(documentObject["cornerRadius"]) {
                document.cornerRadius = min(Double(GGBadgeDocument.canvasSize.height * 0.5), max(0.0, cornerRadius))
            }
            GGBadgePackage.readBackground(documentObject["background"], into: &document)
            for layerObject in layerObjects.prefix(GGBadgePackage.maxLayers) {
                if let layer = GGBadgePackage.layer(layerObject) {
                    document.layers.append(layer)
                }
            }
        }
        if let name = documentObject["name"] as? String {
            let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            if !trimmed.isEmpty {
                document.name = trimmed
            }
        }
        document.layers = Array(document.layers.prefix(GGBadgePackage.maxLayers))

        var assets: [(String, UIImage)] = []
        let encodedAssets = root["assets"] as? [String: Any] ?? [:]
        for layer in document.layers where layer.kind == .image {
            guard let name = layer.fileName, GGBadgePackage.isSafeFileName(name), !assets.contains(where: { $0.0 == name }) else {
                continue
            }
            // Decoded only as large as a badge keeps its pictures, never whole (GGBadgeImages.decode).
            guard let base64 = encodedAssets[name] as? String, let assetData = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), assetData.count <= GGBadgePackage.maxAssetBytes, let image = GGBadgeImages.decode(assetData) else {
                continue
            }
            assets.append((name, image))
        }
        if document.layers.isEmpty {
            return nil
        }
        return (document, assets)
    }

    /// A document of this client's own model (string `background`, layers with `kind`).
    private static func ownDocument(_ object: [String: Any]) -> GGBadgeDocument? {
        guard object["background"] is String, let layers = object["layers"] as? [[String: Any]], layers.allSatisfy({ $0["kind"] is String }) else {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return try? JSONDecoder().decode(GGBadgeDocument.self, from: data)
    }

    private static func readBackground(_ value: Any?, into document: inout GGBadgeDocument) {
        guard let background = value as? [String: Any] else {
            return
        }
        if let solid = background["solid"] {
            if let hex = GGBadgePackage.color(solid) {
                document.background = .solid
                document.solidColor = hex
            }
        } else if let gradient = background["gradient"] as? [String: Any] {
            let from = GGBadgePackage.color(gradient["from"] ?? gradient["_0"])
            let to = GGBadgePackage.color(gradient["to"] ?? gradient["_1"])
            if let from, let to {
                document.background = .gradient
                document.gradientFrom = from
                document.gradientTo = to
                document.gradientAngle = GGBadgePackage.number(gradient["angle"] ?? gradient["_2"]) ?? 0.0
            }
        }
    }

    private static func layer(_ value: Any) -> GGBadgeDocument.Layer? {
        guard let object = value as? [String: Any] else {
            return nil
        }
        var kind: GGBadgeDocument.Layer.Kind?
        var content: [String: Any] = object
        if let contentObject = object["content"] as? [String: Any] {
            if let text = contentObject["text"] as? [String: Any] {
                kind = .text
                content = text["_0"] as? [String: Any] ?? text
            } else if let image = contentObject["image"] as? [String: Any] {
                kind = .image
                content = image["_0"] as? [String: Any] ?? image
            }
        }
        if kind == nil {
            switch ((object["type"] as? String) ?? "").lowercased() {
            case "text", "label", "caption":
                kind = .text
            case "image", "photo", "picture":
                kind = .image
            default:
                if object["fileName"] is String {
                    kind = .image
                } else if object["string"] is String {
                    kind = .text
                }
            }
        }

        var layer: GGBadgeDocument.Layer
        switch kind {
        case .text:
            guard let string = content["string"] as? String else {
                return nil
            }
            layer = .makeText(String(string.prefix(64)))
            if let fontSize = GGBadgePackage.number(content["fontSize"]) {
                layer.fontSize = min(60.0, max(1.0, fontSize))
            }
            if let weight = content["weight"] as? String, ["regular", "medium", "semibold", "bold", "heavy"].contains(weight) {
                layer.weight = weight
            }
            if let color = GGBadgePackage.color(content["color"]) {
                layer.color = color
            }
            if let tracking = GGBadgePackage.number(content["tracking"]) {
                layer.tracking = tracking
            }
            // The old client strokes by the width in percent of the font size; this one by a tenth of it.
            if let strokeWidth = GGBadgePackage.number(content["strokeWidth"]) {
                layer.strokeWidth = max(0.0, strokeWidth / 10.0)
            }
            if let strokeColor = GGBadgePackage.color(content["strokeColor"]) {
                layer.strokeColor = strokeColor
            }
            if let isRounded = content["isRounded"] as? Bool {
                layer.isRounded = isRounded
            }
            // Ghostgram Remake's own key (the old client has no font choice and ignores it).
            if let fontName = content["fontName"] as? String, !fontName.isEmpty, fontName.count <= 64 {
                layer.fontName = fontName
            }
        case .image:
            guard let fileName = content["fileName"] as? String, GGBadgePackage.isSafeFileName(fileName) else {
                return nil
            }
            let fitMode = (content["fitMode"] as? String).flatMap(GGBadgeDocument.FitMode.init(rawValue:)) ?? .fit
            layer = .makeImage(fileName, fitMode: fitMode)
            if let padding = GGBadgePackage.number(content["padding"]) {
                layer.padding = max(0.0, padding)
            }
            if let cornerRadius = GGBadgePackage.number(content["cornerRadius"]) {
                layer.imageCornerRadius = max(0.0, cornerRadius)
            }
            layer.tint = GGBadgePackage.color(content["tint"]) ?? ""
        case nil:
            return nil
        }

        if let id = object["id"] as? String, !id.isEmpty {
            layer.id = String(id.prefix(64))
        }
        if let offset = object["offset"] as? [Any], offset.count == 2 {
            layer.offsetX = GGBadgePackage.number(offset[0]) ?? 0.0
            layer.offsetY = GGBadgePackage.number(offset[1]) ?? 0.0
        } else if let offset = object["offset"] as? [String: Any] {
            layer.offsetX = GGBadgePackage.number(offset["x"]) ?? 0.0
            layer.offsetY = GGBadgePackage.number(offset["y"]) ?? 0.0
        }
        if let scale = GGBadgePackage.number(object["scale"]) {
            layer.scale = min(20.0, max(0.01, scale))
        }
        if let rotation = GGBadgePackage.number(object["rotation"]) {
            layer.rotation = rotation
        }
        if let opacity = GGBadgePackage.number(object["opacity"]) {
            layer.opacity = min(1.0, max(0.0, opacity))
        }
        if let isHidden = object["isHidden"] as? Bool {
            layer.isHidden = isHidden
        }
        return layer
    }

    /// `"#RRGGBB"`, `"#RRGGBBAA"` (alpha dropped), `{"hex": …}` or Swift's `{"_0": …}` → "RRGGBB".
    private static func color(_ value: Any?) -> String? {
        if let object = value as? [String: Any] {
            return GGBadgePackage.color(object["hex"] ?? object["_0"])
        }
        guard var hex = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        if hex.count == 8 {
            hex = String(hex.prefix(6))
        }
        return GGColorHex.normalized(hex)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        return !name.isEmpty && name.count <= 128 && !name.contains("/") && !name.contains("\\") && !name.contains("..")
    }

    // MARK: Writing

    /// The package of a badge, readable by the old client: `assets` are the pictures' files.
    static func encode(_ document: GGBadgeDocument, assets: [String: Data]) -> Data? {
        func colorObject(_ hex: String, fallback: String) -> [String: Any] {
            return ["hex": "#" + (GGColorHex.normalized(hex) ?? fallback)]
        }
        var layers: [[String: Any]] = []
        for layer in document.layers {
            var object: [String: Any] = [
                "id": layer.id,
                "offset": [layer.offsetX, layer.offsetY],
                "scale": layer.scale,
                "rotation": layer.rotation,
                "opacity": layer.opacity,
                "isHidden": layer.isHidden
            ]
            switch layer.kind {
            case .text:
                var text: [String: Any] = [
                    "string": layer.text,
                    "fontSize": layer.fontSize,
                    "weight": layer.weight,
                    "color": colorObject(layer.color, fallback: "FFFFFF"),
                    "tracking": layer.tracking,
                    "strokeWidth": layer.strokeWidth * 10.0,
                    "strokeColor": colorObject(layer.strokeColor, fallback: "000000"),
                    "isRounded": layer.isRounded
                ]
                if let fontName = layer.fontName {
                    text["fontName"] = fontName
                }
                object["content"] = ["text": ["_0": text]]
            case .image:
                guard let fileName = layer.fileName, assets[fileName] != nil else {
                    continue
                }
                var image: [String: Any] = [
                    "fileName": fileName,
                    "fitMode": layer.fitMode.rawValue,
                    "padding": layer.padding,
                    "cornerRadius": layer.imageCornerRadius
                ]
                if let tint = GGColorHex.normalized(layer.tint) {
                    image["tint"] = ["hex": "#" + tint]
                }
                object["content"] = ["image": ["_0": image]]
            }
            layers.append(object)
        }

        let background: [String: Any]
        switch document.background {
        case .none:
            background = ["transparent": [String: Any]()]
        case .solid:
            background = ["solid": ["_0": colorObject(document.solidColor, fallback: "000000")]]
        case .gradient:
            background = ["gradient": [
                "from": colorObject(document.gradientFrom, fallback: "8B5CF6"),
                "to": colorObject(document.gradientTo, fallback: "3B0F86"),
                "angle": document.gradientAngle
            ]]
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let documentObject: [String: Any] = [
            "id": document.id,
            "name": document.name,
            "background": background,
            "cornerRadius": document.cornerRadius,
            "layers": layers,
            "createdAt": now,
            "updatedAt": now
        ]
        var encodedAssets: [String: String] = [:]
        for (name, data) in assets {
            encodedAssets[name] = data.base64EncodedString()
        }
        let root: [String: Any] = [
            "format": GGBadgePackage.fileExtension,
            "version": 1,
            "document": documentObject,
            "assets": encodedAssets
        ]
        guard JSONSerialization.isValidJSONObject(root) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
