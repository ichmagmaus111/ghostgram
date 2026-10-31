import Foundation
import UIKit
import PhotosUI
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import GGCore

/// Badge Studio. The canvas is made of live views (labels and image views inside a 3× scaled
/// pill); a gesture only changes the selected view's transform — nothing is rendered or decoded
/// while a finger moves. The document is updated when the gesture ends, and the flattened PNG is
/// rendered once, on save.
final class GGBadgeStudioController: ViewController {
    private let context: AccountContext
    private var presentationData: PresentationData
    private let isNew: Bool
    private var document: GGBadgeDocument
    private let completion: (GGBadgeDocument) -> Void
    private var didSave = false
    private var studioView: GGBadgeStudioView?
    /// The badge's pictures, decoded off the main thread before the studio opened.
    private let initialAssets: [String: UIImage]

    init(context: AccountContext, document: GGBadgeDocument?, assets: [String: UIImage], completion: @escaping (GGBadgeDocument) -> Void) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.isNew = document == nil
        self.document = document ?? GGBadgeDocument.new(name: GGStrings.Interface.Badge.defaultName, text: "Ghostgram")
        self.initialAssets = assets
        self.completion = completion
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        self.title = GGStrings.Interface.Badge.studioTitle
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Save, style: .done, target: self, action: #selector(self.savePressed))
    }

    required init(coder aDecoder: NSCoder) {
        preconditionFailure()
    }

    deinit {
        // A new badge that was never saved leaves no files behind.
        if self.isNew && !self.didSave, let directory = GGBadgeStore.shared.badgeDirectory(self.document.id) {
            ggInterfaceQueue.async {
                try? FileManager.default.removeItem(atPath: directory)
            }
        }
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        let studioView = GGBadgeStudioView(document: self.document, assets: self.initialAssets, theme: self.presentationData.theme)
        studioView.documentChanged = { [weak self] document in
            self?.document = document
        }
        studioView.requestText = { [weak self] current, completion in
            guard let self else {
                return
            }
            ggPresentTextPrompt(from: self, title: GGStrings.Interface.Badge.textPrompt, text: current, placeholder: "Ghostgram", cancel: self.presentationData.strings.Common_Cancel, done: self.presentationData.strings.Common_Done, completion: { text in
                completion(String(text.prefix(40)))
            })
        }
        studioView.requestPicture = { [weak self] completion in
            self?.pickPicture(completion: completion)
        }
        studioView.requestColor = { [weak self] color, completion in
            self?.pickColor(color, completion: completion)
        }
        self.displayNode.view.addSubview(studioView)
        self.studioView = studioView
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.studioView?.frame = CGRect(x: 0.0, y: top, width: layout.size.width, height: layout.size.height - top)
        self.studioView?.bottomInset = layout.intrinsicInsets.bottom
    }

    /// The photo is decoded (at most 900 px) and stored as the badge's PNG off the main thread;
    /// `completion` gets it with its file name on the main thread.
    private func pickPicture(completion: @escaping (UIImage, String) -> Void) {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        let badgeId = self.document.id
        let delegate = GGPhotoThumbnailPickerDelegate(maxPixelSize: GGBadgeImages.maxPixelSize, completion: { image in
            ggInterfaceQueue.async {
                guard let name = GGBadgeStore.shared.storeAsset(image, badgeId: badgeId) else {
                    return
                }
                Queue.mainQueue().async {
                    completion(image, name)
                }
            }
        })
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &ggBadgePhotoDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        ggPresentNative(picker, from: self)
    }

    private func pickColor(_ color: UIColor, completion: @escaping (UIColor) -> Void) {
        let picker = UIColorPickerViewController()
        picker.selectedColor = color
        picker.supportsAlpha = false
        let delegate = GGBadgeColorPickerDelegate(completion: completion)
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &ggBadgeColorDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        ggPresentNative(picker, from: self)
    }

    @objc private func savePressed() {
        guard let studioView = self.studioView else {
            return
        }
        let document = studioView.document
        if document.background == .none && document.layers.allSatisfy({ $0.isHidden }) {
            self.present(ggToast(context: self.context, text: GGStrings.Interface.Badge.emptyBadge), in: .window(.root))
            return
        }
        if self.isNew && !self.didSave {
            ggPresentTextPrompt(from: self, title: GGStrings.Interface.Badge.namePrompt, text: document.name, placeholder: GGStrings.Interface.Badge.defaultName, cancel: self.presentationData.strings.Common_Cancel, done: self.presentationData.strings.Common_Save, completion: { [weak self] name in
                var named = document
                let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                named.name = trimmed.isEmpty ? GGStrings.Interface.Badge.defaultName : trimmed
                self?.commit(named)
            })
        } else {
            self.commit(document)
        }
    }

    private func commit(_ document: GGBadgeDocument) {
        guard let studioView = self.studioView, let render = GGBadgeRenderer.render(document, assets: { studioView.asset($0) }) else {
            return
        }
        self.document = document
        self.didSave = true
        let completion = self.completion
        let _ = (GGBadgeStore.shared.save(document, render: render)
        |> deliverOnMainQueue).start(completed: { [weak self] in
            completion(document)
            if let navigationController = self?.navigationController as? NavigationController {
                let _ = navigationController.popViewController(animated: true)
            }
        })
    }
}

private var ggBadgePhotoDelegateKey: UInt8 = 0
private var ggBadgeColorDelegateKey: UInt8 = 0

/// The color is applied when the picker closes, and only if a color was picked in it: opening and
/// closing it changes nothing (an empty tint used to become white).
private final class GGBadgeColorPickerDelegate: NSObject, UIColorPickerViewControllerDelegate {
    private let completion: (UIColor) -> Void
    private var didPick = false

    init(completion: @escaping (UIColor) -> Void) {
        self.completion = completion
        super.init()
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        self.didPick = true
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        if self.didPick {
            self.completion(viewController.selectedColor)
        }
    }
}

/// Canvas + controls. Plain UIKit; theme colors from the PresentationTheme it was made with.
private final class GGBadgeStudioView: UIView, UIGestureRecognizerDelegate {
    private static let canvasScale: CGFloat = 3.0

    private(set) var document: GGBadgeDocument
    private let theme: PresentationTheme
    var documentChanged: ((GGBadgeDocument) -> Void)?
    var requestText: ((String, @escaping (String) -> Void) -> Void)?
    /// The completion gets the decoded picture and its file, already stored under the badge.
    var requestPicture: ((@escaping (UIImage, String) -> Void) -> Void)?
    var requestColor: ((UIColor, @escaping (UIColor) -> Void) -> Void)?
    var bottomInset: CGFloat = 0.0 {
        didSet {
            self.setNeedsLayout()
        }
    }

    private var selectedLayerId: String?
    private var assets: [String: UIImage] = [:]
    private var tinted: [String: UIImage] = [:]

    private let stageView = UIView()
    private let islandView = UIView()
    private let canvasView = UIView()
    private let backgroundLayer = CAGradientLayer()
    private var layerViews: [String: UIView] = [:]
    private let scrollView = UIScrollView()
    private let controlsStack = UIStackView()

    // Gesture state. Pan, pinch and rotation run together: each changes only its own part of the
    // selected layer, from the value that part had when THAT gesture began (`gestureStarts`), on the
    // live copy `gestureLayer`; the document gets the copy when the last of them ends. One shared
    // start used to make the preview jump between «only scale» and «only rotation», and the first
    // gesture to end saved its own part and dropped the others.
    private var gestureLayer: GGBadgeDocument.Layer?
    private var gestureStarts: [ObjectIdentifier: GGBadgeDocument.Layer] = [:]

    init(document: GGBadgeDocument, assets: [String: UIImage], theme: PresentationTheme) {
        self.document = document
        self.theme = theme
        // Pictures of the badge come decoded (off the main thread, before the studio opened);
        // gestures never touch the disk.
        self.assets = assets
        self.selectedLayerId = document.layers.last?.id
        // A layer in a font the user added draws in it from the first frame.
        GGBadgeFont.prepareUserFonts()
        super.init(frame: .zero)

        self.stageView.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        self.stageView.layer.cornerRadius = 16.0
        self.stageView.clipsToBounds = true
        self.addSubview(self.stageView)

        self.islandView.backgroundColor = .black
        self.stageView.addSubview(self.islandView)

        self.canvasView.bounds = CGRect(origin: CGPoint(), size: GGBadgeDocument.canvasSize)
        self.canvasView.transform = CGAffineTransform(scaleX: GGBadgeStudioView.canvasScale, y: GGBadgeStudioView.canvasScale)
        self.canvasView.clipsToBounds = true
        self.canvasView.layer.addSublayer(self.backgroundLayer)
        self.stageView.addSubview(self.canvasView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(self.handlePinch(_:)))
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(self.handleRotation(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.handleTap(_:)))
        for recognizer in [pan, pinch, rotation] as [UIGestureRecognizer] {
            recognizer.delegate = self
            self.stageView.addGestureRecognizer(recognizer)
        }
        // Dragging a layer to the right is not «back»: the navigation's swipe-back gesture would take it.
        self.stageView.disablesInteractiveTransitionGestureRecognizer = true
        self.stageView.addGestureRecognizer(tap)

        self.scrollView.alwaysBounceVertical = true
        self.scrollView.keyboardDismissMode = .onDrag
        self.addSubview(self.scrollView)
        self.controlsStack.axis = .vertical
        self.controlsStack.spacing = 12.0
        self.scrollView.addSubview(self.controlsStack)

        self.rebuildCanvas()
        self.rebuildControls()
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    func asset(_ name: String) -> UIImage? {
        return self.assets[name]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 16.0
        let width = self.bounds.width - inset * 2.0
        let stageHeight: CGFloat = 150.0
        self.stageView.frame = CGRect(x: inset, y: 12.0, width: width, height: stageHeight)
        let canvasSize = CGSize(width: GGBadgeDocument.canvasSize.width * GGBadgeStudioView.canvasScale, height: GGBadgeDocument.canvasSize.height * GGBadgeStudioView.canvasScale)
        let islandSize = CGSize(width: canvasSize.width + 24.0, height: canvasSize.height + 30.0)
        self.islandView.frame = CGRect(x: (width - islandSize.width) * 0.5, y: (stageHeight - islandSize.height) * 0.5, width: islandSize.width, height: islandSize.height)
        self.islandView.layer.cornerRadius = islandSize.height * 0.5
        self.canvasView.center = CGPoint(x: width * 0.5, y: stageHeight * 0.5)

        let controlsTop = self.stageView.frame.maxY + 12.0
        self.scrollView.frame = CGRect(x: 0.0, y: controlsTop, width: self.bounds.width, height: self.bounds.height - controlsTop)
        let size = self.controlsStack.systemLayoutSizeFitting(CGSize(width: width, height: 0.0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        self.controlsStack.frame = CGRect(x: inset, y: 0.0, width: width, height: size.height)
        self.scrollView.contentSize = CGSize(width: self.bounds.width, height: size.height + 24.0 + self.bottomInset)
    }

    private func commit(_ document: GGBadgeDocument, controls: Bool = true) {
        self.document = document
        self.documentChanged?(document)
        self.rebuildCanvas()
        if controls {
            self.rebuildControls()
        }
    }

    private var selectedIndex: Int? {
        guard let id = self.selectedLayerId else {
            return nil
        }
        return self.document.layers.firstIndex(where: { $0.id == id })
    }

    private func updateSelected(_ f: (inout GGBadgeDocument.Layer) -> Void, controls: Bool = true) {
        guard let index = self.selectedIndex else {
            return
        }
        var document = self.document
        f(&document.layers[index])
        self.commit(document, controls: controls)
    }

    // MARK: Canvas

    private func rebuildCanvas() {
        let document = self.document
        self.canvasView.layer.cornerRadius = CGFloat(document.cornerRadius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.backgroundLayer.frame = self.canvasView.bounds
        switch document.background {
        case .none:
            self.backgroundLayer.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor]
        case .solid:
            let color = (GGColorHex.color(document.solidColor) ?? .black).cgColor
            self.backgroundLayer.colors = [color, color]
        case .gradient:
            self.backgroundLayer.colors = [(GGColorHex.color(document.gradientFrom) ?? .purple).cgColor, (GGColorHex.color(document.gradientTo) ?? .black).cgColor]
            // The renderer's gradient in the layer's unit space: the studio shows what is saved.
            let points = GGBadgeRenderer.gradientUnitPoints(angle: document.gradientAngle, size: GGBadgeDocument.canvasSize)
            self.backgroundLayer.startPoint = points.start
            self.backgroundLayer.endPoint = points.end
        }
        CATransaction.commit()

        var remaining = self.layerViews
        for layer in document.layers {
            let view: UIView
            if let current = remaining.removeValue(forKey: layer.id) {
                view = current
            } else {
                view = layer.kind == .text ? UILabel() : UIImageView()
                self.canvasView.addSubview(view)
                self.layerViews[layer.id] = view
            }
            self.canvasView.bringSubviewToFront(view)
            self.configure(view, layer: layer)
        }
        for (id, view) in remaining {
            view.removeFromSuperview()
            self.layerViews.removeValue(forKey: id)
        }
    }

    private func configure(_ view: UIView, layer: GGBadgeDocument.Layer) {
        view.transform = .identity
        view.isHidden = layer.isHidden
        view.alpha = CGFloat(layer.opacity)
        let center = CGPoint(x: GGBadgeDocument.canvasSize.width * 0.5, y: GGBadgeDocument.canvasSize.height * 0.5)
        if let label = view as? UILabel {
            label.attributedText = GGBadgeRenderer.attributedText(layer)
            label.sizeToFit()
        } else if let imageView = view as? UIImageView {
            let image = layer.fileName.flatMap { self.assets[$0] }
            if let image, let tint = GGColorHex.color(layer.tint) {
                let key = "\(layer.fileName ?? "")|\(layer.tint)"
                if self.tinted[key] == nil {
                    self.tinted[key] = generateTintedImage(image: image, color: tint)
                }
                imageView.image = self.tinted[key] ?? image
            } else {
                imageView.image = image
            }
            let rect = GGBadgeRenderer.imageRect(image?.size ?? CGSize(width: 1.0, height: 1.0), layer: layer, canvas: GGBadgeDocument.canvasSize)
            imageView.bounds = CGRect(origin: CGPoint(), size: rect.size)
            imageView.layer.cornerRadius = CGFloat(layer.imageCornerRadius)
            imageView.clipsToBounds = layer.imageCornerRadius > 0.0
        }
        view.center = CGPoint(x: center.x + CGFloat(layer.offsetX), y: center.y + CGFloat(layer.offsetY))
        view.transform = GGBadgeStudioView.transform(layer)
        let isSelected = layer.id == self.selectedLayerId
        view.layer.borderWidth = isSelected ? 1.0 / GGBadgeStudioView.canvasScale : 0.0
        view.layer.borderColor = self.theme.list.itemAccentColor.cgColor
    }

    private static func transform(_ layer: GGBadgeDocument.Layer) -> CGAffineTransform {
        return CGAffineTransform(rotationAngle: CGFloat(layer.rotation) * .pi / 180.0).scaledBy(x: CGFloat(layer.scale), y: CGFloat(layer.scale))
    }

    // MARK: Gestures (transform only; the document changes when the gesture ends)

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    /// `apply` sets the gesture's own part of the live layer from the layer as it was when this
    /// gesture began (`start`).
    private func liveUpdate(_ recognizer: UIGestureRecognizer, _ apply: (_ layer: inout GGBadgeDocument.Layer, _ start: GGBadgeDocument.Layer) -> Void) {
        let key = ObjectIdentifier(recognizer)
        switch recognizer.state {
        case .began:
            guard let index = self.selectedIndex else {
                return
            }
            let selected = self.document.layers[index]
            if self.gestureLayer?.id != selected.id {
                self.gestureLayer = selected
                self.gestureStarts.removeAll()
            }
            self.gestureStarts[key] = self.gestureLayer
        case .changed, .ended, .cancelled:
            break
        default:
            return
        }
        guard var layer = self.gestureLayer, let start = self.gestureStarts[key] else {
            return
        }
        apply(&layer, start)
        self.gestureLayer = layer
        if recognizer.state == .ended || recognizer.state == .cancelled {
            self.gestureStarts.removeValue(forKey: key)
            if self.gestureStarts.isEmpty {
                // The last gesture ended: the document gets the place, size and angle of all of them.
                self.gestureLayer = nil
                var document = self.document
                if let index = document.layers.firstIndex(where: { $0.id == layer.id }) {
                    document.layers[index].offsetX = layer.offsetX
                    document.layers[index].offsetY = layer.offsetY
                    document.layers[index].scale = layer.scale
                    document.layers[index].rotation = layer.rotation
                    self.commit(document, controls: false)
                }
                return
            }
        }
        guard let view = self.layerViews[layer.id] else {
            return
        }
        let center = CGPoint(x: GGBadgeDocument.canvasSize.width * 0.5, y: GGBadgeDocument.canvasSize.height * 0.5)
        view.center = CGPoint(x: center.x + CGFloat(layer.offsetX), y: center.y + CGFloat(layer.offsetY))
        view.transform = GGBadgeStudioView.transform(layer)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self.stageView)
        self.liveUpdate(recognizer, { layer, start in
            let limitX = Double(GGBadgeDocument.canvasSize.width)
            let limitY = Double(GGBadgeDocument.canvasSize.height)
            layer.offsetX = max(-limitX, min(limitX, start.offsetX + Double(translation.x / GGBadgeStudioView.canvasScale)))
            layer.offsetY = max(-limitY, min(limitY, start.offsetY + Double(translation.y / GGBadgeStudioView.canvasScale)))
        })
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        let scale = recognizer.scale
        self.liveUpdate(recognizer, { layer, start in
            layer.scale = max(0.2, min(6.0, start.scale * Double(scale)))
        })
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        let rotation = recognizer.rotation
        self.liveUpdate(recognizer, { layer, start in
            layer.rotation = start.rotation + Double(rotation * 180.0 / .pi)
        })
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self.canvasView)
        for layer in self.document.layers.reversed() where !layer.isHidden {
            if let view = self.layerViews[layer.id], view.frame.insetBy(dx: -4.0, dy: -4.0).contains(point) {
                self.selectedLayerId = layer.id
                self.rebuildCanvas()
                self.rebuildControls()
                return
            }
        }
    }

    // MARK: Controls

    private func rebuildControls() {
        for view in self.controlsStack.arrangedSubviews {
            self.controlsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let document = self.document

        // Layers
        self.controlsStack.addArrangedSubview(self.sectionTitle(GGStrings.Interface.Badge.layersHeader))
        let layersRow = UIStackView()
        layersRow.axis = .horizontal
        layersRow.spacing = 8.0
        layersRow.distribution = .fillEqually
        // One limit for text and picture layers, the one a `.ggbadge` is read with
        // (GGBadgeDocument.maxLayers): a badge shared and imported back stays whole.
        let canAddLayer = document.layers.count < GGBadgeDocument.maxLayers
        let addText = self.button(GGStrings.Interface.Badge.addText, action: { [weak self] in
            guard let self, self.document.layers.count < GGBadgeDocument.maxLayers else {
                return
            }
            self.requestText?("", { [weak self] text in
                guard let self, !text.isEmpty, self.document.layers.count < GGBadgeDocument.maxLayers else {
                    return
                }
                var document = self.document
                let layer = GGBadgeDocument.Layer.makeText(text)
                document.layers.append(layer)
                self.selectedLayerId = layer.id
                self.commit(document)
            })
        })
        let addPicture = self.button(GGStrings.Interface.Badge.addPicture, action: { [weak self] in
            guard let self, self.document.layers.count < GGBadgeDocument.maxLayers else {
                return
            }
            self.requestPicture?({ [weak self] image, name in
                guard let self, self.document.layers.count < GGBadgeDocument.maxLayers else {
                    return
                }
                self.assets[name] = image
                var document = self.document
                let layer = GGBadgeDocument.Layer.makeImage(name, fitMode: .fit)
                document.layers.append(layer)
                self.selectedLayerId = layer.id
                self.commit(document)
            })
        })
        for button in [addText, addPicture] {
            (button as? UIButton)?.isEnabled = canAddLayer
            button.alpha = canAddLayer ? 1.0 : 0.5
            layersRow.addArrangedSubview(button)
        }
        self.controlsStack.addArrangedSubview(layersRow)
        if !document.layers.isEmpty {
            let titles = document.layers.enumerated().map { index, layer -> String in
                let name = layer.kind == .text ? (layer.text.isEmpty ? GGStrings.Interface.Badge.textLayer : layer.text) : GGStrings.Interface.Badge.pictureLayer
                return "\(index + 1). " + String(name.prefix(10))
            }
            let control = UISegmentedControl(items: titles)
            self.applyAppFont(control)
            control.selectedSegmentIndex = self.selectedIndex ?? UISegmentedControl.noSegment
            control.addAction(UIAction(handler: { [weak self, weak control] _ in
                guard let self, let control, control.selectedSegmentIndex >= 0, control.selectedSegmentIndex < self.document.layers.count else {
                    return
                }
                self.selectedLayerId = self.document.layers[control.selectedSegmentIndex].id
                self.rebuildCanvas()
                self.rebuildControls()
            }), for: .valueChanged)
            self.controlsStack.addArrangedSubview(control)
        }

        // Selected layer
        if let index = self.selectedIndex {
            let layer = document.layers[index]
            if layer.kind == .text {
                self.controlsStack.addArrangedSubview(self.button(GGStrings.Interface.Badge.editText, action: { [weak self] in
                    self?.requestText?(layer.text, { [weak self] text in
                        self?.updateSelected({ $0.text = text })
                    })
                }))
                self.controlsStack.addArrangedSubview(self.colorRow(GGStrings.Interface.Badge.textColor, hex: layer.color, set: { [weak self] hex in
                    self?.updateSelected({ $0.color = hex })
                }))
                let roundedRow = self.switchRow(GGStrings.Interface.Badge.roundedFont, value: layer.isRounded, set: { [weak self] value in
                    self?.updateSelected({ $0.isRounded = value }, controls: false)
                })
                roundedRow.isHidden = !GGBadgeFont.allowsRounded(layer.fontName)
                self.controlsStack.addArrangedSubview(self.fontStrip(selected: layer.fontName, set: { [weak self, weak roundedRow] name in
                    roundedRow?.isHidden = !GGBadgeFont.allowsRounded(name)
                    self?.setNeedsLayout()
                    self?.updateSelected({ $0.fontName = name }, controls: false)
                }))
                self.controlsStack.addArrangedSubview(self.slider(GGStrings.Interface.Badge.fontSize, value: layer.fontSize, range: 6.0 ... 20.0, set: { [weak self] value in
                    self?.updateSelected({ $0.fontSize = value }, controls: false)
                }))
                let weights = ["regular", "medium", "semibold", "bold", "heavy"]
                let weightControl = UISegmentedControl(items: [GGStrings.Interface.Badge.weightRegular, GGStrings.Interface.Badge.weightMedium, GGStrings.Interface.Badge.weightSemibold, GGStrings.Interface.Badge.weightBold, GGStrings.Interface.Badge.weightHeavy])
                self.applyAppFont(weightControl)
                weightControl.selectedSegmentIndex = weights.firstIndex(of: layer.weight) ?? 3
                weightControl.addAction(UIAction(handler: { [weak self, weak weightControl] _ in
                    guard let index = weightControl?.selectedSegmentIndex, index >= 0, index < weights.count else {
                        return
                    }
                    self?.updateSelected({ $0.weight = weights[index] }, controls: false)
                }), for: .valueChanged)
                self.controlsStack.addArrangedSubview(weightControl)
                self.controlsStack.addArrangedSubview(roundedRow)
                self.controlsStack.addArrangedSubview(self.slider(GGStrings.Interface.Badge.outline, value: layer.strokeWidth, range: 0.0 ... 3.0, set: { [weak self] value in
                    self?.updateSelected({ $0.strokeWidth = value }, controls: false)
                }))
                self.controlsStack.addArrangedSubview(self.slider(GGStrings.Interface.Badge.tracking, value: layer.tracking, range: -2.0 ... 6.0, set: { [weak self] value in
                    self?.updateSelected({ $0.tracking = value }, controls: false)
                }))
            } else {
                let modes: [GGBadgeDocument.FitMode] = [.fit, .fill, .manual]
                let fitControl = UISegmentedControl(items: [GGStrings.Interface.Badge.fit, GGStrings.Interface.Badge.fill, GGStrings.Interface.Badge.manual])
                self.applyAppFont(fitControl)
                fitControl.selectedSegmentIndex = modes.firstIndex(of: layer.fitMode) ?? 0
                fitControl.addAction(UIAction(handler: { [weak self, weak fitControl] _ in
                    guard let index = fitControl?.selectedSegmentIndex, index >= 0, index < modes.count else {
                        return
                    }
                    self?.updateSelected({ $0.fitMode = modes[index] }, controls: false)
                }), for: .valueChanged)
                self.controlsStack.addArrangedSubview(fitControl)
                self.controlsStack.addArrangedSubview(self.slider(GGStrings.Interface.Badge.padding, value: layer.padding, range: 0.0 ... 8.0, set: { [weak self] value in
                    self?.updateSelected({ $0.padding = value }, controls: false)
                }))
                self.controlsStack.addArrangedSubview(self.slider(GGStrings.Interface.Badge.pictureCorners, value: layer.imageCornerRadius, range: 0.0 ... 11.0, set: { [weak self] value in
                    self?.updateSelected({ $0.imageCornerRadius = value }, controls: false)
                }))
                self.controlsStack.addArrangedSubview(self.colorRow(GGStrings.Interface.Badge.tint, hex: layer.tint, set: { [weak self] hex in
                    self?.updateSelected({ $0.tint = hex })
                }, clear: layer.tint.isEmpty ? nil : { [weak self] in
                    self?.updateSelected({ $0.tint = "" })
                }))
            }
            self.controlsStack.addArrangedSubview(self.slider(GGStrings.Interface.Badge.opacity, value: layer.opacity, range: 0.1 ... 1.0, set: { [weak self] value in
                self?.updateSelected({ $0.opacity = value }, controls: false)
            }))
            let layerActions = UIStackView()
            layerActions.axis = .horizontal
            layerActions.spacing = 8.0
            layerActions.distribution = .fillEqually
            layerActions.addArrangedSubview(self.button(GGStrings.Interface.Badge.resetPosition, action: { [weak self] in
                self?.updateSelected({ layer in
                    layer.offsetX = 0.0
                    layer.offsetY = 0.0
                    layer.scale = 1.0
                    layer.rotation = 0.0
                })
            }))
            layerActions.addArrangedSubview(self.button(layer.isHidden ? GGStrings.Interface.Common.show : GGStrings.Interface.Common.hide, action: { [weak self] in
                self?.updateSelected({ $0.isHidden = !$0.isHidden })
            }))
            layerActions.addArrangedSubview(self.button(GGStrings.Interface.Badge.deleteLayer, isDestructive: true, action: { [weak self] in
                guard let self, let index = self.selectedIndex else {
                    return
                }
                var document = self.document
                document.layers.remove(at: index)
                self.selectedLayerId = document.layers.last?.id
                self.commit(document)
            }))
            self.controlsStack.addArrangedSubview(layerActions)
        }

        // Background
        self.controlsStack.addArrangedSubview(self.sectionTitle(GGStrings.Interface.Badge.backgroundHeader))
        let kinds: [GGBadgeDocument.BackgroundKind] = [.none, .solid, .gradient]
        let backgroundControl = UISegmentedControl(items: [GGStrings.Interface.Badge.backgroundNone, GGStrings.Interface.Badge.backgroundSolid, GGStrings.Interface.Badge.backgroundGradient])
        self.applyAppFont(backgroundControl)
        backgroundControl.selectedSegmentIndex = kinds.firstIndex(of: document.background) ?? 0
        backgroundControl.addAction(UIAction(handler: { [weak self, weak backgroundControl] _ in
            guard let self, let index = backgroundControl?.selectedSegmentIndex, index >= 0, index < kinds.count else {
                return
            }
            var document = self.document
            document.background = kinds[index]
            self.commit(document)
        }), for: .valueChanged)
        self.controlsStack.addArrangedSubview(backgroundControl)
        switch document.background {
        case .none:
            break
        case .solid:
            self.controlsStack.addArrangedSubview(self.colorRow(GGStrings.Interface.Badge.backgroundColor, hex: document.solidColor, set: { [weak self] hex in
                guard let self else {
                    return
                }
                var document = self.document
                document.solidColor = hex
                self.commit(document)
            }))
        case .gradient:
            self.controlsStack.addArrangedSubview(self.colorRow(GGStrings.Interface.Badge.gradientFrom, hex: document.gradientFrom, set: { [weak self] hex in
                guard let self else {
                    return
                }
                var document = self.document
                document.gradientFrom = hex
                self.commit(document)
            }))
            self.controlsStack.addArrangedSubview(self.colorRow(GGStrings.Interface.Badge.gradientTo, hex: document.gradientTo, set: { [weak self] hex in
                guard let self else {
                    return
                }
                var document = self.document
                document.gradientTo = hex
                self.commit(document)
            }))
            self.controlsStack.addArrangedSubview(self.slider(GGStrings.Interface.Badge.gradientAngle, value: document.gradientAngle, range: 0.0 ... 360.0, set: { [weak self] value in
                guard let self else {
                    return
                }
                var document = self.document
                document.gradientAngle = value
                self.commit(document, controls: false)
            }))
        }
        self.controlsStack.addArrangedSubview(self.slider(GGStrings.Interface.Badge.corners, value: document.cornerRadius, range: 0.0 ... 11.0, set: { [weak self] value in
            guard let self else {
                return
            }
            var document = self.document
            document.cornerRadius = value
            self.commit(document, controls: false)
        }))

        self.setNeedsLayout()
    }

    /// The studio's own interface follows the app font (`Font`, «Шрифт»); the font chips and the badge
    /// keep their own fonts.
    private func applyAppFont(_ control: UISegmentedControl) {
        control.setTitleTextAttributes([.font: Font.regular(13.0)], for: .normal)
        control.setTitleTextAttributes([.font: Font.semibold(13.0)], for: .selected)
    }

    private func sectionTitle(_ text: String) -> UIView {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = Font.regular(13.0)
        label.textColor = self.theme.list.sectionHeaderTextColor
        return label
    }

    private func button(_ title: String, isDestructive: Bool = false, action: @escaping () -> Void) -> UIView {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = Font.medium(15.0)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.setTitleColor(isDestructive ? self.theme.list.itemDestructiveColor : self.theme.list.itemAccentColor, for: .normal)
        button.backgroundColor = self.theme.list.itemBlocksBackgroundColor
        button.layer.cornerRadius = 10.0
        button.heightAnchor.constraint(equalToConstant: 40.0).isActive = true
        button.addAction(UIAction(handler: { _ in
            action()
        }), for: .touchUpInside)
        return button
    }

    private func row(_ title: String, accessory: UIView) -> UIView {
        let container = UIStackView()
        container.axis = .horizontal
        container.alignment = .center
        container.spacing = 8.0
        let label = UILabel()
        label.text = title
        label.font = Font.regular(15.0)
        label.textColor = self.theme.list.itemPrimaryTextColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(label)
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        container.addArrangedSubview(accessory)
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 36.0).isActive = true
        return container
    }

    private func switchRow(_ title: String, value: Bool, set: @escaping (Bool) -> Void) -> UIView {
        let control = UISwitch()
        control.isOn = value
        control.onTintColor = self.theme.list.itemSwitchColors.contentColor
        control.addAction(UIAction(handler: { [weak control] _ in
            set(control?.isOn ?? false)
        }), for: .valueChanged)
        return self.row(title, accessory: control)
    }

    /// The fonts of a text layer as a strip of chips, each name drawn in its own font. A tap marks the
    /// chip in place (no rebuild: the strip keeps where it was scrolled to).
    private func fontStrip(selected: String?, set: @escaping (String?) -> Void) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4.0
        let label = UILabel()
        label.text = GGStrings.Interface.Badge.font
        label.font = Font.regular(13.0)
        label.textColor = self.theme.list.itemSecondaryTextColor
        stack.addArrangedSubview(label)

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        // A swipe to the right scrolls the strip back. Without this the navigation's swipe-back gesture
        // took every rightward swipe from the middle of the screen: the strip went forward and never back.
        scrollView.disablesInteractiveTransitionGestureRecognizer = true
        scrollView.heightAnchor.constraint(equalToConstant: 36.0).isActive = true
        let chips = UIStackView()
        chips.axis = .horizontal
        chips.spacing = 8.0
        chips.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(chips)
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            chips.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            chips.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            chips.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let accentColor = self.theme.list.itemAccentColor
        let names = GGBadgeFont.available
        // Through the strip, not a list of the buttons: the buttons' actions call this.
        let mark: (String?) -> Void = { [weak chips] selected in
            guard let chips else {
                return
            }
            for (index, view) in chips.arrangedSubviews.enumerated() where index < names.count {
                view.layer.borderWidth = names[index] == selected ? 2.0 : 0.0
            }
        }
        var selectedButton: UIButton?
        for name in names {
            let title = GGBadgeFont.title(name)
            let font = GGBadgeFont.font(name: name, size: 15.0, weight: .regular, isRounded: false)
            let button = UIButton(type: .custom)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = font
            button.setTitleColor(self.theme.list.itemPrimaryTextColor, for: .normal)
            button.backgroundColor = self.theme.list.itemBlocksBackgroundColor
            button.layer.cornerRadius = 10.0
            button.layer.borderColor = accentColor.cgColor
            button.widthAnchor.constraint(equalToConstant: ceil((title as NSString).size(withAttributes: [.font: font]).width) + 24.0).isActive = true
            button.addAction(UIAction(handler: { _ in
                mark(name)
                set(name)
            }), for: .touchUpInside)
            chips.addArrangedSubview(button)
            if name == selected {
                selectedButton = button
            }
        }
        mark(selected)
        stack.addArrangedSubview(scrollView)

        // The chosen font in sight once the strip is laid out.
        if let selectedButton {
            DispatchQueue.main.async { [weak self, weak scrollView, weak selectedButton] in
                guard let self, let scrollView, let selectedButton else {
                    return
                }
                self.layoutIfNeeded()
                scrollView.layoutIfNeeded()
                scrollView.scrollRectToVisible(selectedButton.frame.insetBy(dx: -16.0, dy: 0.0), animated: false)
            }
        }
        return stack
    }

    /// The document is updated on release (`.touchUpInside`/`.touchUpOutside`), not per tick.
    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4.0
        let label = UILabel()
        label.text = title
        label.font = Font.regular(13.0)
        label.textColor = self.theme.list.itemSecondaryTextColor
        stack.addArrangedSubview(label)
        let slider = UISlider()
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.value = Float(value)
        slider.minimumTrackTintColor = self.theme.list.itemAccentColor
        slider.addAction(UIAction(handler: { [weak slider] _ in
            guard let slider else {
                return
            }
            set(Double(slider.value))
        }), for: [.touchUpInside, .touchUpOutside])
        stack.addArrangedSubview(slider)
        return stack
    }

    private func colorRow(_ title: String, hex: String, set: @escaping (String) -> Void, clear: (() -> Void)? = nil) -> UIView {
        let swatch = UIButton(type: .custom)
        swatch.backgroundColor = GGColorHex.color(hex) ?? .clear
        swatch.layer.cornerRadius = 14.0
        swatch.layer.borderWidth = 1.0
        swatch.layer.borderColor = self.theme.list.itemPlainSeparatorColor.cgColor
        swatch.widthAnchor.constraint(equalToConstant: 28.0).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 28.0).isActive = true
        swatch.addAction(UIAction(handler: { [weak self] _ in
            self?.requestColor?(GGColorHex.color(hex) ?? .white, { color in
                set(GGColorHex.hex(color))
            })
        }), for: .touchUpInside)
        guard let clear else {
            return self.row(title, accessory: swatch)
        }
        let accessory = UIStackView()
        accessory.axis = .horizontal
        accessory.spacing = 8.0
        let clearButton = UIButton(type: .system)
        clearButton.setTitle(GGStrings.Interface.Badge.noTint, for: .normal)
        clearButton.titleLabel?.font = Font.regular(15.0)
        clearButton.addAction(UIAction(handler: { _ in
            clear()
        }), for: .touchUpInside)
        accessory.addArrangedSubview(clearButton)
        accessory.addArrangedSubview(swatch)
        return self.row(title, accessory: accessory)
    }
}
