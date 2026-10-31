import Foundation
import UIKit
import CoreText
import Display
import SwiftSignalKit
import AppBundle
import GGCore
import GGHooks

/// A badge made in the studio: a 93×22 pt pill (drawn behind the cutout / Dynamic Island,
/// visible on screenshots and recordings) built of text and picture layers over a background.
struct GGBadgeDocument: Codable, Equatable {
    static let canvasSize = CGSize(width: 93.0, height: 22.0)
    static let formatVersion = 1
    /// Text and picture layers together: the studio adds no more, and a `.ggbadge` is read up to it,
    /// so a badge goes out and comes back the same.
    static let maxLayers = 16

    enum BackgroundKind: String, Codable {
        case none
        case solid
        case gradient
    }

    enum FitMode: String, Codable {
        case fit
        case fill
        case manual
    }

    struct Layer: Codable, Equatable {
        enum Kind: String, Codable {
            case text
            case image
        }

        var id: String
        var kind: Kind
        var isHidden: Bool
        var scale: Double
        var offsetX: Double
        var offsetY: Double
        /// Degrees.
        var rotation: Double
        var opacity: Double

        // Text
        var text: String
        var fontSize: Double
        /// "regular", "medium", "semibold", "bold", "heavy".
        var weight: String
        var isRounded: Bool
        var color: String
        var strokeWidth: Double
        var strokeColor: String
        var tracking: Double
        /// `GGBadgeFont`; nil = the system font (badges made before the font choice too).
        var fontName: String?

        // Image (file inside the badge's `assets/`)
        var fileName: String?
        var fitMode: FitMode
        var padding: Double
        var imageCornerRadius: Double
        /// "" = the picture's own colors.
        var tint: String

        static func makeText(_ value: String) -> Layer {
            return Layer(id: UUID().uuidString, kind: .text, isHidden: false, scale: 1.0, offsetX: 0.0, offsetY: 0.0, rotation: 0.0, opacity: 1.0, text: value, fontSize: 12.0, weight: "bold", isRounded: true, color: "FFFFFF", strokeWidth: 0.0, strokeColor: "000000", tracking: 0.0, fileName: nil, fitMode: .fit, padding: 2.0, imageCornerRadius: 0.0, tint: "")
        }

        static func makeImage(_ fileName: String, fitMode: FitMode) -> Layer {
            return Layer(id: UUID().uuidString, kind: .image, isHidden: false, scale: 1.0, offsetX: 0.0, offsetY: 0.0, rotation: 0.0, opacity: 1.0, text: "", fontSize: 12.0, weight: "bold", isRounded: true, color: "FFFFFF", strokeWidth: 0.0, strokeColor: "000000", tracking: 0.0, fileName: fileName, fitMode: fitMode, padding: 2.0, imageCornerRadius: 0.0, tint: "")
        }
    }

    var version: Int
    var id: String
    var name: String
    var background: BackgroundKind
    var solidColor: String
    var gradientFrom: String
    var gradientTo: String
    /// Degrees.
    var gradientAngle: Double
    var cornerRadius: Double
    var layers: [Layer]

    static func new(name: String, text: String) -> GGBadgeDocument {
        return GGBadgeDocument(version: GGBadgeDocument.formatVersion, id: "custom." + UUID().uuidString.lowercased(), name: name, background: .none, solidColor: "000000", gradientFrom: "8B5CF6", gradientTo: "3B0F86", gradientAngle: 0.0, cornerRadius: 11.0, layers: [.makeText(text)])
    }
}

/// Badges on disk: `<appGroup>/ghostgram/interface/badges/<id>/{badge.json, render.png, assets/}`.
/// `render.png` is the flattened badge, written once on save — the window and the selection grid
/// only ever load that file (once, cached).
final class GGBadgeStore {
    static let shared = GGBadgeStore()

    private let documentsPromise = Promise<[GGBadgeDocument]>()
    private var didLoad = false
    private let renders = Atomic<[String: UIImage]>(value: [:])

    private init() {
    }

    var directory: String? {
        return ggInterfaceDirectory("badges")
    }

    func badgeDirectory(_ id: String) -> String? {
        guard let directory = self.directory, GGBadgeStore.isValidId(id) else {
            return nil
        }
        return (directory as NSString).appendingPathComponent(id)
    }

    static func isValidId(_ id: String) -> Bool {
        return id.hasPrefix("custom.") && id.count <= 80 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    /// Saved badges, newest first.
    var documents: Signal<[GGBadgeDocument], NoError> {
        if !self.didLoad {
            self.didLoad = true
            self.reload()
        }
        return self.documentsPromise.get()
    }

    func reload() {
        let directory = self.directory
        self.documentsPromise.set(Signal<[GGBadgeDocument], NoError> { subscriber in
            var result: [(GGBadgeDocument, Date)] = []
            if let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory) {
                for name in names where GGBadgeStore.isValidId(name) {
                    let path = (directory as NSString).appendingPathComponent(name)
                    let jsonPath = (path as NSString).appendingPathComponent("badge.json")
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)), let document = try? JSONDecoder().decode(GGBadgeDocument.self, from: data), document.id == name else {
                        continue
                    }
                    let date = ((try? FileManager.default.attributesOfItem(atPath: jsonPath))?[.modificationDate] as? Date) ?? Date.distantPast
                    result.append((document, date))
                }
            }
            subscriber.putNext(result.sorted(by: { $0.1 > $1.1 }).map { $0.0 })
            subscriber.putCompletion()
            return EmptyDisposable
        } |> runOn(ggInterfaceQueue))
    }

    /// The flattened badge of a selection: the bundled Ghostgram badge or a saved one.
    func image(selection: String) -> UIImage? {
        if !GGBadgeStore.isValidId(selection) {
            return UIImage(bundleImageName: "GGInterface/IslandBadgeGhostgram")
        }
        if let cached = self.renders.with({ $0[selection] }) {
            return cached
        }
        guard let directory = self.badgeDirectory(selection) else {
            return nil
        }
        let path = (directory as NSString).appendingPathComponent("render.png")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let image = UIImage(data: data, scale: 3.0) else {
            return UIImage(bundleImageName: "GGInterface/IslandBadgeGhostgram")
        }
        let _ = self.renders.modify { current in
            var updated = current
            updated[selection] = image
            return updated
        }
        return image
    }

    /// Writes the document, its assets stay where the studio put them, and the flattened render.
    func save(_ document: GGBadgeDocument, render: UIImage) -> Signal<Never, NoError> {
        let directory = self.badgeDirectory(document.id)
        let renders = self.renders
        return Signal { subscriber in
            if let directory {
                try? FileManager.default.createDirectory(atPath: (directory as NSString).appendingPathComponent("assets"), withIntermediateDirectories: true, attributes: nil)
                if let data = try? JSONEncoder().encode(document) {
                    try? data.write(to: URL(fileURLWithPath: (directory as NSString).appendingPathComponent("badge.json")), options: .atomic)
                }
                if let png = render.pngData() {
                    try? png.write(to: URL(fileURLWithPath: (directory as NSString).appendingPathComponent("render.png")), options: .atomic)
                }
                // Assets no layer references any more are dropped.
                let used = Set(document.layers.compactMap { $0.fileName })
                let assets = (directory as NSString).appendingPathComponent("assets")
                for name in (try? FileManager.default.contentsOfDirectory(atPath: assets)) ?? [] where !used.contains(name) {
                    try? FileManager.default.removeItem(atPath: (assets as NSString).appendingPathComponent(name))
                }
                let _ = renders.modify { current in
                    var updated = current
                    updated[document.id] = render
                    return updated
                }
            }
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(ggInterfaceQueue)
        |> afterCompleted { [weak self] in
            self?.reload()
        }
    }

    func delete(_ id: String) -> Signal<Never, NoError> {
        let directory = self.badgeDirectory(id)
        let renders = self.renders
        return Signal { subscriber in
            if let directory {
                try? FileManager.default.removeItem(atPath: directory)
            }
            let _ = renders.modify { current in
                var updated = current
                updated.removeValue(forKey: id)
                return updated
            }
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(ggInterfaceQueue)
        |> afterCompleted { [weak self] in
            self?.reload()
        }
    }

    /// Copies a picture into a badge's assets (PNG); returns the file name.
    func storeAsset(_ image: UIImage, badgeId: String) -> String? {
        guard let directory = self.badgeDirectory(badgeId), let data = image.pngData() else {
            return nil
        }
        let assets = (directory as NSString).appendingPathComponent("assets")
        try? FileManager.default.createDirectory(atPath: assets, withIntermediateDirectories: true, attributes: nil)
        let name = UUID().uuidString.lowercased() + ".png"
        do {
            try data.write(to: URL(fileURLWithPath: (assets as NSString).appendingPathComponent(name)), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// A picture of a badge, decoded (at most 900 px). Off the main thread.
    func assetImage(_ fileName: String, badgeId: String) -> UIImage? {
        guard let directory = self.badgeDirectory(badgeId), !fileName.contains("/"), !fileName.contains("..") else {
            return nil
        }
        let path = ((directory as NSString).appendingPathComponent("assets") as NSString).appendingPathComponent(fileName)
        return GGBadgeImages.decode(url: URL(fileURLWithPath: path))
    }

    /// Badges of the old client keep working (`<appGroup>/ggbadges/custom.<uuid>/`: `badge.json`,
    /// `assets/`, `render.png`; upstream's App Group clean-up may already have removed that
    /// directory — then there is nothing to bring over). A badge stays editable: its document and
    /// pictures are read like an old `.ggbadge` (`GGBadgePackage`); only a badge without a readable
    /// document becomes a one-picture badge of its `render.png`. Each badge is assembled aside and
    /// moved in whole; the old directory goes only when every badge is here, otherwise the next
    /// launch tries again (badges already here are skipped).
    func migrateLegacyBadgesIfNeeded() {
        ggInterfaceQueue.async {
            guard let appGroupPath = GGCore.environment?.appGroupPath else {
                return
            }
            // One failed directory listing per launch when there is nothing to bring over.
            let legacy = (appGroupPath as NSString).appendingPathComponent("ggbadges")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: legacy), let directory = self.directory else {
                return
            }
            var isComplete = true
            for name in names where GGBadgeStore.isValidId(name) {
                let destination = (directory as NSString).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: destination) {
                    continue
                }
                let source = (legacy as NSString).appendingPathComponent(name)
                if !GGBadgeStore.migrateLegacyBadge(id: name, from: source, to: destination) {
                    isComplete = false
                }
            }
            if isComplete {
                try? FileManager.default.removeItem(atPath: legacy)
            }
            Queue.mainQueue().async {
                self.reload()
                GGIslandBadge.shared.reloadImage()
            }
        }
    }

    /// One old badge directory → `destination` (written aside, then moved). False: something of it
    /// could not be read or written — keep the old copy. A directory with neither a document nor a
    /// picture is not a badge and counts as done. The old `render.png` is kept as the badge's
    /// picture (the studio redraws it on the next save); nothing is rendered here, off the main queue.
    private static func migrateLegacyBadge(id: String, from source: String, to destination: String) -> Bool {
        let fileManager = FileManager.default
        let documentPath = (source as NSString).appendingPathComponent("badge.json")
        let renderData = try? Data(contentsOf: URL(fileURLWithPath: (source as NSString).appendingPathComponent("render.png")))
        var document: GGBadgeDocument?
        var assets: [(String, UIImage)] = []
        if let documentData = try? Data(contentsOf: URL(fileURLWithPath: documentPath)), let documentObject = (try? JSONSerialization.jsonObject(with: documentData)) as? [String: Any] {
            // The old document with its pictures, as one package for the reader of `.ggbadge`.
            var encodedAssets: [String: String] = [:]
            let assetsPath = (source as NSString).appendingPathComponent("assets")
            for fileName in (try? fileManager.contentsOfDirectory(atPath: assetsPath)) ?? [] where !fileName.hasPrefix(".") {
                if let assetData = try? Data(contentsOf: URL(fileURLWithPath: (assetsPath as NSString).appendingPathComponent(fileName))) {
                    encodedAssets[fileName] = assetData.base64EncodedString()
                }
            }
            let package: [String: Any] = ["document": documentObject, "assets": encodedAssets]
            if let packageData = try? JSONSerialization.data(withJSONObject: package), let decoded = GGBadgePackage.decode(packageData) {
                // A layer whose picture is gone is dropped.
                let available = Set(decoded.assets.map { $0.0 })
                var candidate = decoded.document
                candidate.layers = candidate.layers.filter { layer in
                    return layer.kind != .image || layer.fileName.flatMap({ available.contains($0) }) == true
                }
                if !candidate.layers.isEmpty {
                    document = candidate
                    assets = decoded.assets
                }
            }
        }
        if document == nil, let renderData, let image = UIImage(data: renderData) {
            var single = GGBadgeDocument.new(name: GGStrings.Interface.Badge.defaultName, text: "")
            single.layers = [.makeImage("legacy.png", fitMode: .fill)]
            document = single
            assets = [("legacy.png", image)]
        }
        guard var document else {
            return renderData == nil && !fileManager.fileExists(atPath: documentPath)
        }
        document.id = id
        // Assembled aside under a name the store never lists (it starts with a dot).
        let staging = ((destination as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".migrating-" + id)
        try? fileManager.removeItem(atPath: staging)
        do {
            let assetsPath = (staging as NSString).appendingPathComponent("assets")
            try fileManager.createDirectory(atPath: assetsPath, withIntermediateDirectories: true, attributes: nil)
            for (name, image) in assets {
                guard let data = image.pngData() else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: URL(fileURLWithPath: (assetsPath as NSString).appendingPathComponent(name)), options: .atomic)
            }
            if let renderData {
                try renderData.write(to: URL(fileURLWithPath: (staging as NSString).appendingPathComponent("render.png")), options: .atomic)
            }
            try JSONEncoder().encode(document).write(to: URL(fileURLWithPath: (staging as NSString).appendingPathComponent("badge.json")), options: .atomic)
            try fileManager.moveItem(atPath: staging, toPath: destination)
            return true
        } catch {
            try? fileManager.removeItem(atPath: staging)
            return false
        }
    }
}

/// Draws a document into the 93×22 pt pill. Called once per save (and per thumbnail), never
/// per gesture frame — the studio's live canvas is made of layers.
enum GGBadgeRenderer {
    static func render(_ document: GGBadgeDocument, assets: (String) -> UIImage?) -> UIImage? {
        // A text layer may be in a font the user added (an imported badge is drawn here first).
        if document.layers.contains(where: { $0.kind == .text && $0.fontName != nil }) {
            GGBadgeFont.prepareUserFonts()
        }
        let size = GGBadgeDocument.canvasSize
        return generateImage(size, scale: 3.0, rotatedContext: { contextSize, context in
            let rect = CGRect(origin: CGPoint(), size: contextSize)
            context.clear(rect)
            context.saveGState()
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: CGFloat(document.cornerRadius)).cgPath)
            context.clip()
            switch document.background {
            case .none:
                break
            case .solid:
                context.setFillColor((GGColorHex.color(document.solidColor) ?? .black).cgColor)
                context.fill(rect)
            case .gradient:
                let from = GGColorHex.color(document.gradientFrom) ?? .purple
                let to = GGColorHex.color(document.gradientTo) ?? .black
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [from.cgColor, to.cgColor] as CFArray, locations: [0.0, 1.0]) {
                    let points = GGBadgeRenderer.gradientPoints(angle: document.gradientAngle, in: rect)
                    context.drawLinearGradient(gradient, start: points.start, end: points.end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            }
            UIGraphicsPushContext(context)
            for layer in document.layers where !layer.isHidden {
                context.saveGState()
                context.setAlpha(CGFloat(layer.opacity))
                context.translateBy(x: rect.midX + CGFloat(layer.offsetX), y: rect.midY + CGFloat(layer.offsetY))
                context.rotate(by: CGFloat(layer.rotation) * .pi / 180.0)
                context.scaleBy(x: CGFloat(layer.scale), y: CGFloat(layer.scale))
                switch layer.kind {
                case .text:
                    let string = GGBadgeRenderer.attributedText(layer)
                    let textSize = string.size()
                    string.draw(at: CGPoint(x: -textSize.width * 0.5, y: -textSize.height * 0.5))
                case .image:
                    if let fileName = layer.fileName, let image = assets(fileName) {
                        let drawRect = GGBadgeRenderer.imageRect(image.size, layer: layer, canvas: size)
                        context.saveGState()
                        if layer.imageCornerRadius > 0.0 {
                            context.addPath(UIBezierPath(roundedRect: drawRect, cornerRadius: CGFloat(layer.imageCornerRadius)).cgPath)
                            context.clip()
                        }
                        if let tint = GGColorHex.color(layer.tint) {
                            (generateTintedImage(image: image, color: tint) ?? image).draw(in: drawRect)
                        } else {
                            image.draw(in: drawRect)
                        }
                        context.restoreGState()
                    }
                }
                context.restoreGState()
            }
            UIGraphicsPopContext()
            context.restoreGState()
        })
    }

    /// Where the background gradient starts and ends, in points of `rect`: the line through the centre
    /// at `angle` degrees, half the longer side either way — the old client's geometry, so a `.ggbadge`
    /// looks as it did there. The studio's live canvas takes the same points (in its unit space), so
    /// what the studio shows is what is saved.
    static func gradientPoints(angle: Double, in rect: CGRect) -> (start: CGPoint, end: CGPoint) {
        let radians = CGFloat(angle) * .pi / 180.0
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = max(rect.width, rect.height) * 0.5
        let start = CGPoint(x: center.x - cos(radians) * radius, y: center.y - sin(radians) * radius)
        let end = CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
        return (start, end)
    }

    /// The same gradient for a `CAGradientLayer` of `size` (the studio's live canvas). Its points are
    /// in unit space, stretched to the layer per axis, and its lines of equal color are square to the
    /// start→end line IN UNIT SPACE: dividing the points by the sides only fits 0°, 90°, 180° and
    /// 270° (on 93×22 a 45° gradient came out at ~13°). The end point is chosen so that, stretched, the
    /// lines are square to the renderer's direction and the colors sit where the renderer puts them
    /// (checked against `drawLinearGradient` at 0°…333°: equal up to CAGradientLayer's own rounding).
    static func gradientUnitPoints(angle: Double, size: CGSize) -> (start: CGPoint, end: CGPoint) {
        let points = GGBadgeRenderer.gradientPoints(angle: angle, in: CGRect(origin: CGPoint(), size: size))
        let vector = CGPoint(x: points.end.x - points.start.x, y: points.end.y - points.start.y)
        let start = CGPoint(x: points.start.x / size.width, y: points.start.y / size.height)
        let denominator = size.width * size.width * vector.x * vector.x + size.height * size.height * vector.y * vector.y
        if denominator <= 0.0 {
            return (start, start)
        }
        let k = (vector.x * vector.x + vector.y * vector.y) / denominator
        return (start, CGPoint(x: start.x + k * size.width * vector.x, y: start.y + k * size.height * vector.y))
    }

    static func font(_ layer: GGBadgeDocument.Layer) -> UIFont {
        let weight: UIFont.Weight
        switch layer.weight {
        case "regular":
            weight = .regular
        case "medium":
            weight = .medium
        case "semibold":
            weight = .semibold
        case "heavy":
            weight = .heavy
        default:
            weight = .bold
        }
        return GGBadgeFont.font(name: layer.fontName, size: CGFloat(layer.fontSize), weight: weight, isRounded: layer.isRounded)
    }

    static func attributedText(_ layer: GGBadgeDocument.Layer) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: GGBadgeRenderer.font(layer),
            .foregroundColor: GGColorHex.color(layer.color) ?? UIColor.white,
            .kern: CGFloat(layer.tracking)
        ]
        if layer.strokeWidth > 0.0 {
            attributes[.strokeColor] = GGColorHex.color(layer.strokeColor) ?? UIColor.black
            // Negative: stroke and fill.
            attributes[.strokeWidth] = -CGFloat(layer.strokeWidth) * 10.0
        }
        return NSAttributedString(string: layer.text, attributes: attributes)
    }

    /// Where a picture layer is drawn in layer space (centered on the layer's origin).
    static func imageRect(_ imageSize: CGSize, layer: GGBadgeDocument.Layer, canvas: CGSize) -> CGRect {
        let padding = CGFloat(layer.padding)
        let available = CGSize(width: max(1.0, canvas.width - padding * 2.0), height: max(1.0, canvas.height - padding * 2.0))
        var drawSize: CGSize
        switch layer.fitMode {
        case .fit:
            let scale = min(available.width / max(1.0, imageSize.width), available.height / max(1.0, imageSize.height))
            drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        case .fill:
            let scale = max(canvas.width / max(1.0, imageSize.width), canvas.height / max(1.0, imageSize.height))
            drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        case .manual:
            let scale = canvas.height / max(1.0, imageSize.height)
            drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        }
        return CGRect(x: -drawSize.width * 0.5, y: -drawSize.height * 0.5, width: drawSize.width, height: drawSize.height)
    }
}

/// The font of a text layer (owner, 2026-10-28: «в редактор бейджей добавить выбор шрифтов»): the
/// system font with its weight and «Скруглённый шрифт», the system's serif and monospaced designs,
/// a family that ships with iOS — the same families as the app font, plus a few handwritten ones
/// that suit a 22 pt pill — or a font the user added in «Шрифт» (owner, the same day), after them.
/// A badge is flattened into `render.png` on save, so the font only has to exist while the badge is
/// edited; a name this iPhone does not have (a removed font, a badge from another phone) falls back
/// to the system font.
enum GGBadgeFont {
    static let serif = "design:serif"
    static let monospaced = "design:monospaced"

    /// The picker's order; nil = the system font.
    private static let choices: [String?] = [
        nil, GGBadgeFont.serif, GGBadgeFont.monospaced,
        "Avenir Next", "Helvetica Neue", "Futura", "Gill Sans", "Optima", "Trebuchet MS",
        "Georgia", "Didot", "Baskerville", "Bodoni 72", "Rockwell",
        "American Typewriter", "Courier New", "Menlo",
        "Chalkboard SE", "Marker Felt", "Noteworthy", "Snell Roundhand", "Bradley Hand", "Papyrus"
    ]

    /// The choices this iPhone has: the built-in ones, then the user's own fonts.
    static var available: [String?] {
        var result = GGBadgeFont.choices.filter { name in
            guard let name, !GGBadgeFont.isDesign(name) else {
                return true
            }
            return !UIFont.fontNames(forFamilyName: name).isEmpty
        }
        for family in GGBadgeFont.prepareUserFonts() where !result.contains(family) {
            result.append(family)
        }
        return result
    }

    /// Files registered for this process by the studio (main thread).
    private static var registeredUserFonts = Set<URL>()

    /// Registers the fonts the user added (GGUserFontsHooks) for this process — only the chosen app font
    /// is registered at launch — and returns the families that can be drawn with. Called before the
    /// studio draws, so a layer in a user's font shows in it; a file registers once per launch.
    @discardableResult
    static func prepareUserFonts() -> [String] {
        var families: [String] = []
        for font in GGUserFontsHooks.userFonts() {
            if !GGBadgeFont.registeredUserFonts.contains(font.fileURL) {
                GGBadgeFont.registeredUserFonts.insert(font.fileURL)
                var error: Unmanaged<CFError>?
                if !CTFontManagerRegisterFontsForURL(font.fileURL as CFURL, .process, &error) {
                    // Already registered (the app font) is fine; a gone file leaves the family missing.
                    error?.release()
                }
            }
            if !families.contains(font.familyName), !UIFont.fontNames(forFamilyName: font.familyName).isEmpty {
                families.append(font.familyName)
            }
        }
        return families
    }

    private static func isDesign(_ name: String) -> Bool {
        return name == GGBadgeFont.serif || name == GGBadgeFont.monospaced
    }

    /// The picker's caption: a family's own name (a proper name, the same in every language).
    static func title(_ name: String?) -> String {
        guard let name else {
            return GGStrings.Interface.Badge.fontSystem
        }
        switch name {
        case GGBadgeFont.serif:
            return GGStrings.Interface.Badge.fontSerif
        case GGBadgeFont.monospaced:
            return GGStrings.Interface.Badge.fontMonospaced
        default:
            return name
        }
    }

    /// «Скруглённый шрифт» is a design of the system font only.
    static func allowsRounded(_ name: String?) -> Bool {
        return name == nil
    }

    static func font(name: String?, size: CGFloat, weight: UIFont.Weight, isRounded: Bool) -> UIFont {
        let system = UIFont.systemFont(ofSize: size, weight: weight)
        guard let name else {
            if isRounded, let descriptor = system.fontDescriptor.withDesign(.rounded) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return system
        }
        switch name {
        case GGBadgeFont.serif:
            if let descriptor = system.fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return system
        case GGBadgeFont.monospaced:
            return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        default:
            guard let faceName = GGBadgeFont.faceName(family: name, weight: weight), let font = UIFont(name: faceName, size: size) else {
                return system
            }
            return font
        }
    }

    /// Family + weight → the upright, normal-width face nearest in weight (italic or another width only
    /// when the family has nothing closer). Found once per pair: the studio asks on every edit.
    private static let faces = Atomic<[String: String]>(value: [:])

    private static func faceName(family: String, weight: UIFont.Weight) -> String? {
        let key = family + "|\(weight.rawValue)"
        if let cached = GGBadgeFont.faces.with({ $0[key] }) {
            return cached
        }
        var best: (name: String, score: CGFloat)?
        for name in UIFont.fontNames(forFamilyName: family) {
            guard let font = UIFont(name: name, size: 12.0) else {
                continue
            }
            let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
            let faceWeight = (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0.0
            let width = (traits?[.width] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0.0
            var score = abs(faceWeight - weight.rawValue)
            if font.fontDescriptor.symbolicTraits.contains(.traitItalic) {
                score += 2.0
            }
            if abs(width) > 0.01 {
                score += 1.0
            }
            if best.map({ score < $0.score }) ?? true {
                best = (name, score)
            }
        }
        // A family with no faces is not remembered: a user's font may be registered later.
        guard let name = best?.name else {
            return nil
        }
        let _ = GGBadgeFont.faces.modify { current in
            var updated = current
            updated[key] = name
            return updated
        }
        return name
    }
}
