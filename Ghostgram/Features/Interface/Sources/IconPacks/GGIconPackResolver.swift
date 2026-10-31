import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import AppBundle
import GGCore

/// The explicit icon layer of «Наборы иконок»: builds ONE immutable table «asset name → image»
/// from the enabled packs (first pack wins), off the main thread, and publishes it with one atomic
/// store (`GGAppBundleSetImageOverrides`). `UIImage(bundleImageName:)` answers from that table
/// with a single atomic load — no lock, no lookup in pack files, nothing at all while no pack is
/// enabled. Each pack image is fitted once into the stock asset's canvas, so layouts do not move.
/// Images that Telegram caches in `static let`s keep the old glyph until the next launch (the
/// screen says so; nothing restarts the app).
final class GGIconPackResolver {
    static let shared = GGIconPackResolver()

    private let disposable = MetaDisposable()
    private var appliedCount: Int = 0

    private init() {
    }

    func register() {
        // Re-apply on every change of the enabled list or of the packs' files.
        // With no pack enabled nothing is read from disk at all.
        self.disposable.set((InterfaceSettings.iconPacks.signal
        |> mapToSignal { enabledIds -> Signal<[String: UIImage], NoError> in
            if enabledIds.isEmpty {
                return .single([:])
            }
            return GGIconPackStorage.shared.packs
            |> deliverOn(ggInterfaceQueue)
            |> map { packs -> [String: UIImage] in
                return GGIconPackResolver.buildTable(enabledIds: enabledIds, packs: packs)
            }
        }
        |> deliverOnMainQueue).start(next: { [weak self] table in
            guard let self else {
                return
            }
            let previous = self.appliedCount
            self.appliedCount = table.count
            if table.isEmpty && previous == 0 {
                return
            }
            GGAppBundleSetImageOverrides(table.isEmpty ? nil : table)
            // Screens rebuild their glyphs from a new theme instance (see InterfaceTheme).
            let _ = InterfaceTheme.iconRevision.modify { $0 + 1 }
            GGThemeHooks.invalidate()
        }))
    }

    /// Forces a rebuild (after a migration).
    func apply() {
        GGIconPackStorage.shared.reload()
    }

    static func buildTable(enabledIds: [String], packs: [GGIconPack]) -> [String: UIImage] {
        if enabledIds.isEmpty {
            return [:]
        }
        let packsById = Dictionary(packs.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        let ordered = enabledIds.compactMap { packsById[$0] }
        if ordered.isEmpty {
            return [:]
        }
        var table: [String: UIImage] = [:]
        for (asset, androidNames) in GGIconPackMapTable.androidNamesByAsset {
            for pack in ordered {
                var url: URL?
                for name in androidNames where !GGIconPackMapTable.blacklist.contains(name) {
                    if let candidate = pack.fileURL(androidName: name) {
                        url = candidate
                        break
                    }
                }
                guard let url, let image = GGIconPackResolver.decode(url, forStockAsset: asset) else {
                    continue
                }
                table[asset] = GGIconPackResolver.fitted(image, toStockAsset: asset)
                break
            }
        }
        return table
    }

    /// A pack's picture decoded only as large as the stock asset's canvas in pixels (never the whole
    /// file: a huge PNG used to be decoded in full on every launch). Off the main thread.
    static func decode(_ url: URL, forStockAsset asset: String) -> UIImage? {
        var maxPixelSize = 256
        if let stock = UIImage(named: asset, in: getAppBundle(), compatibleWith: nil) {
            maxPixelSize = max(1, Int(ceil(max(stock.size.width, stock.size.height) * stock.scale)))
        }
        return GGImageDecoding.thumbnail(url: url, maxPixelSize: maxPixelSize, maxSourcePixels: GGImageDecoding.maxIconSourcePixels)
    }

    /// The pack image drawn into the stock asset's canvas (same point size and scale), centered
    /// and fitted, as a template so call sites that tint keep tinting.
    static func fitted(_ image: UIImage, toStockAsset asset: String) -> UIImage {
        guard let stock = UIImage(named: asset, in: getAppBundle(), compatibleWith: nil) else {
            return image.withRenderingMode(.alwaysTemplate)
        }
        let size = stock.size
        if size.width <= 0.0 || size.height <= 0.0 {
            return image
        }
        let fitted = generateImage(size, scale: stock.scale, rotatedContext: { contextSize, context in
            context.clear(CGRect(origin: CGPoint(), size: contextSize))
            let scale = min(contextSize.width / max(1.0, image.size.width), contextSize.height / max(1.0, image.size.height))
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(origin: CGPoint(x: (contextSize.width - drawSize.width) * 0.5, y: (contextSize.height - drawSize.height) * 0.5), size: drawSize))
            UIGraphicsPopContext()
        }) ?? image
        return stock.renderingMode == .alwaysTemplate ? fitted.withRenderingMode(.alwaysTemplate) : fitted
    }

    /// Four sample icons of a pack for the 2×2 preview (or Telegram's own when the pack has none).
    static let previewAssets = ["Chat List/Tabs/IconChats", "Chat List/Tabs/IconSettings", "Chat/Context Menu/Copy", "Chat/Context Menu/Delete"]

    static func previewImages(pack: GGIconPack?) -> [UIImage] {
        var result: [UIImage] = []
        for asset in GGIconPackResolver.previewAssets {
            var image: UIImage?
            if let pack, let names = GGIconPackMapTable.androidNamesByAsset[asset] {
                for name in names {
                    if let url = pack.fileURL(androidName: name), let decoded = GGIconPackResolver.decode(url, forStockAsset: asset) {
                        image = GGIconPackResolver.fitted(decoded, toStockAsset: asset)
                        break
                    }
                }
            }
            if image == nil {
                image = UIImage(named: asset, in: getAppBundle(), compatibleWith: nil)
            }
            if let image {
                result.append(image)
            }
        }
        return result
    }
}
