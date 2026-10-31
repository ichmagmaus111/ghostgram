import Foundation
import UIKit
import SwiftSignalKit
import GGCore
import GGCameraPipeline

/// The masks part of the round-video camera screen: the frame processor, the live preview of the
/// processed frames inside the circle, a button and the panel of masks. The panel is built only on
/// the first tap of the button; until then nothing reads the disk or the network.
final class GGRoundVideoMasksExtension: GGRoundVideoCameraExtension {
    private let accountId: GGAccountID
    private let processor: GGMaskFrameProcessor
    private let overlay = GGProcessedFrameView()
    private let controls = GGPassThroughView()
    private let button = UIButton(type: .system)
    private var panel: GGMaskChipsPanel?
    private var isPanelVisible = false
    private var lastLayout: GGRoundVideoCameraLayout?
    private var isInvalidated = false

    init(accountId: GGAccountID) {
        self.accountId = accountId
        self.processor = GGMaskFrameProcessor(maskProvider: {
            return GGMaskEngine.shared.mask(for: GGMaskEngine.selection(for: accountId))
        })
        let overlay = self.overlay
        self.processor.previewSink = { buffer, info in
            overlay.enqueue(buffer, orientation: info.orientation)
        }
        // Prepare the current mask before the first frame.
        let _ = GGMaskEngine.shared.mask(for: GGMaskEngine.selection(for: accountId))

        self.button.backgroundColor = UIColor(white: 0.0, alpha: 0.4)
        self.button.layer.cornerRadius = 18.0
        self.button.tintColor = .white
        self.button.setImage(UIImage(systemName: "theatermasks", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17.0, weight: .medium)), for: .normal)
        self.button.accessibilityLabel = GGStrings.CameraMasks.Masks.title
        self.button.addTarget(self, action: #selector(self.buttonPressed), for: .touchUpInside)
        self.controls.addSubview(self.button)
    }

    var frameProcessor: GGCameraFrameProcessor? {
        return self.processor
    }

    var previewOverlayView: UIView? {
        return self.overlay
    }

    var controlsView: UIView? {
        return self.controls
    }

    var occupiedFrame: CGRect? {
        if self.isPanelVisible, let panel = self.panel {
            return panel.frame
        }
        return self.button.frame
    }

    @objc private func buttonPressed() {
        if self.panel == nil {
            let panel = GGMaskChipsPanel(accountId: self.accountId)
            panel.alpha = 0.0
            self.controls.addSubview(panel)
            self.panel = panel
        }
        self.isPanelVisible = !self.isPanelVisible
        if let layout = self.lastLayout {
            self.update(layout: layout, animated: true)
        }
    }

    func update(layout: GGRoundVideoCameraLayout, animated: Bool) {
        self.lastLayout = layout
        self.controls.frame = CGRect(origin: .zero, size: layout.containerSize)
        if let superview = self.overlay.superview {
            self.overlay.frame = superview.bounds
        }
        let buttonSize: CGFloat = 36.0
        self.button.frame = CGRect(x: layout.containerSize.width - buttonSize - 14.0, y: layout.previewFrame.maxY - buttonSize, width: buttonSize, height: buttonSize)
        let showsControls = !layout.isShowingResult
        if !showsControls {
            self.isPanelVisible = false
        }
        let panelAlpha: CGFloat = self.isPanelVisible ? 1.0 : 0.0
        if let panel = self.panel {
            panel.frame = CGRect(x: 16.0, y: layout.previewFrame.maxY + 12.0, width: layout.containerSize.width - 32.0, height: GGMaskChipsPanel.height)
            panel.isUserInteractionEnabled = self.isPanelVisible
            if self.isPanelVisible {
                panel.activate()
            }
        }
        let apply = {
            self.button.alpha = showsControls ? 1.0 : 0.0
            self.panel?.alpha = panelAlpha
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: apply)
        } else {
            apply()
        }
        self.button.isUserInteractionEnabled = showsControls
    }

    func invalidate() {
        if self.isInvalidated {
            return
        }
        self.isInvalidated = true
        self.panel?.invalidate()
    }
}

/// A view whose empty areas let touches through to the screen below.
final class GGPassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        return result === self ? nil : result
    }
}

/// The horizontal strip of masks in the camera: «none», built-in masks, own masks, catalog masks.
final class GGMaskChipsPanel: UIView {
    static let height: CGFloat = 84.0

    private struct Chip {
        let selection: GGMaskSelection
        let view: UIButton
    }

    private let accountId: GGAccountID
    private let scrollView = UIScrollView()
    private var chips: [Chip] = []
    private var isActive = false
    private let disposables = DisposableSet()
    private var userEntries: [GGMaskStoreEntry] = []
    private var catalogEntries: [GGMaskCatalogEntry] = []
    private var thumbnails: [String: UIImage] = [:]

    init(accountId: GGAccountID) {
        self.accountId = accountId
        super.init(frame: .zero)
        self.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
        self.layer.cornerRadius = 18.0
        self.clipsToBounds = true
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.alwaysBounceHorizontal = true
        self.addSubview(self.scrollView)
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    /// First open: load own masks and the catalog (only now, not when the camera opens).
    func activate() {
        if self.isActive {
            return
        }
        self.isActive = true
        self.disposables.add((GGMaskStore.shared.entries |> deliverOnMainQueue).start(next: { [weak self] entries in
            self?.userEntries = entries
            self?.rebuild()
        }))
        self.disposables.add((GGMaskCatalog.shared.entries |> deliverOnMainQueue).start(next: { [weak self] entries in
            self?.catalogEntries = entries
            self?.rebuild()
        }))
        self.disposables.add((GGMaskEngine.shared.changes.get() |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.updateSelection()
        }))
        GGMaskCatalog.shared.refreshIfNeeded()
        self.rebuild()
    }

    func invalidate() {
        self.disposables.dispose()
    }

    private func rebuild() {
        for chip in self.chips {
            chip.view.removeFromSuperview()
        }
        self.chips = []
        var items: [(GGMaskSelection, String?, UIImage?)] = [(.none, "✕", nil)]
        for id in GGBuiltInMasks.ids {
            items.append((.builtIn(id), GGBuiltInMasks.glyph(id: id), nil))
        }
        let languageCode = GGLocalization.shared.languageCode
        for entry in self.userEntries {
            let initial = String(entry.manifest.displayName(languageCode: languageCode).prefix(1)).uppercased()
            items.append((.user(entry.id), initial, GGMaskStore.shared.thumbnail(id: entry.id)))
        }
        for entry in self.catalogEntries {
            items.append((.catalog(entry.id), nil, self.thumbnails[entry.id]))
            if self.thumbnails[entry.id] == nil {
                self.loadThumbnail(entry)
            }
        }
        for (selection, glyph, image) in items {
            let button = UIButton(type: .custom)
            button.backgroundColor = UIColor(white: 1.0, alpha: 0.15)
            button.clipsToBounds = true
            if let image {
                button.setImage(image, for: .normal)
                button.imageView?.contentMode = .scaleAspectFill
            } else if let glyph {
                button.setTitle(glyph, for: .normal)
                button.titleLabel?.font = UIFont.systemFont(ofSize: 28.0)
            }
            button.addTarget(self, action: #selector(self.chipPressed(_:)), for: .touchUpInside)
            self.scrollView.addSubview(button)
            self.chips.append(Chip(selection: selection, view: button))
        }
        self.setNeedsLayout()
        self.updateSelection()
    }

    private func loadThumbnail(_ entry: GGMaskCatalogEntry) {
        self.disposables.add((GGMaskCatalog.shared.thumbnail(entry: entry) |> deliverOnMainQueue).start(next: { [weak self] image in
            guard let self, let image else {
                return
            }
            self.thumbnails[entry.id] = image
            if let chip = self.chips.first(where: { $0.selection == .catalog(entry.id) }) {
                chip.view.setImage(image, for: .normal)
                chip.view.imageView?.contentMode = .scaleAspectFill
            }
        }))
    }

    private func updateSelection() {
        let current = GGMaskEngine.selection(for: self.accountId)
        for chip in self.chips {
            let isSelected = chip.selection == current
            chip.view.layer.borderWidth = isSelected ? 2.0 : 0.0
            chip.view.layer.borderColor = UIColor.systemBlue.cgColor
        }
    }

    @objc private func chipPressed(_ sender: UIButton) {
        guard let chip = self.chips.first(where: { $0.view === sender }) else {
            return
        }
        GGMaskEngine.shared.select(chip.selection, account: self.accountId)
        self.updateSelection()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.scrollView.frame = self.bounds
        let side = self.bounds.height - 16.0
        var x: CGFloat = 12.0
        for chip in self.chips {
            chip.view.frame = CGRect(x: x, y: 8.0, width: side, height: side)
            chip.view.layer.cornerRadius = side / 2.0
            x += side + 8.0
        }
        self.scrollView.contentSize = CGSize(width: x + 4.0, height: self.bounds.height)
    }
}
