import Foundation
import UIKit
import Vision
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import AppBundle
import UndoUI
import GGCore
import GGHooks
import GGFeaturesShared

/// «Перевод текста на фото»: an item in the photo viewer's «…» menu. The text is recognized on the
/// device (Vision), translated line by line in one request with the chosen service, and shown over
/// the photo in its own full-screen view (tap to close). Nothing is added to the gallery's own
/// panels, so the gallery files stay untouched.
enum GGPhotoTranslation {
    static func register() {
        GGGalleryHooks.menuItems.register({ context in
            return GGPhotoTranslation.menuItems(context)
        })
    }

    private static func menuItems(_ context: GGGalleryMenuContext) -> [ContextMenuItem] {
        guard GGMessagesSettings.photoTranslation.value, case .image = context.kind, let message = context.message else {
            return []
        }
        // The photo is shown again in an unprotected view: never for media the viewer itself keeps
        // from being saved (copy protection without the bypass, paid media) or for view-once media.
        if message.id.peerId.namespace == Namespaces.Peer.SecretChat || context.isCopyProtected || message.containsSecretMedia {
            return []
        }
        guard let image = message.media.first(where: { $0 is TelegramMediaImage }) as? TelegramMediaImage, let largest = largestImageRepresentation(image.representations) else {
            return []
        }
        let accountContext = context.context
        return [.action(ContextMenuActionItem(text: GGStrings.Translation.Menu.photo, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Translate"), color: theme.contextMenu.primaryColor)
        }, action: { _, f in
            f(.default)
            GGPhotoTranslation.start(context: accountContext, resource: largest.resource)
        }))]
    }

    private struct Line {
        let text: String
        /// Normalized Vision box (origin at the bottom left).
        let box: CGRect
    }

    private static func start(context: AccountContext, resource: MediaResource) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        var toLang = presentationData.strings.baseLanguageCode
        if toLang.hasSuffix("-raw") {
            toLang = String(toLang.dropLast(4))
        }
        let _ = (context.account.postbox.mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: false))
        |> filter { $0.complete }
        |> take(1)
        |> deliverOn(Queue.concurrentDefaultQueue())
        |> map { data -> (UIImage, [Line])? in
            guard let image = UIImage(contentsOfFile: data.path), let cgImage = image.cgImage else {
                return nil
            }
            return (image, GGPhotoTranslation.recognize(cgImage))
        }
        |> deliverOnMainQueue).start(next: { result in
            guard let result else {
                GGPhotoTranslation.toast(context: context, text: GGStrings.Translation.Photo.failed)
                return
            }
            let (image, lines) = result
            if lines.isEmpty {
                GGPhotoTranslation.toast(context: context, text: GGStrings.Translation.Photo.noText)
                return
            }
            let joined = lines.map { $0.text }.joined(separator: "\n")
            if let language = GGSystemTranslate.detectLanguage(joined), language == toLang {
                GGPhotoTranslation.toast(context: context, text: GGStrings.Translation.Photo.sameLanguage)
                return
            }
            let _ = (context.engine.messages.translate(texts: lines.map { ($0.text, []) }, toLang: toLang)
            |> deliverOnMainQueue).start(next: { translated in
                let blocks = zip(lines, translated).map { line, value in
                    return GGPhotoTranslationView.Block(text: value.0.isEmpty ? line.text : value.0, box: line.box)
                }
                GGPhotoTranslation.present(context: context, image: image, blocks: blocks)
            }, error: { _ in
                GGPhotoTranslation.toast(context: context, text: GGStrings.Translation.Photo.failed)
            })
        })
    }

    private static func recognize(_ image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = true
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        var lines: [Line] = []
        for observation in request.results ?? [] {
            if let candidate = observation.topCandidates(1).first, !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(Line(text: candidate.string, box: observation.boundingBox))
            }
        }
        return lines
    }

    private static func toast(context: AccountContext, text: String) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        context.sharedContext.mainWindow?.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in
            return false
        }), on: .root)
    }

    private static func present(context: AccountContext, image: UIImage, blocks: [GGPhotoTranslationView.Block]) {
        guard var presenter = context.sharedContext.mainWindow?.viewController?.view.window?.rootViewController else {
            return
        }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        let controller = GGPhotoTranslationViewController(image: image, blocks: blocks)
        controller.modalPresentationStyle = .overFullScreen
        controller.modalTransitionStyle = .crossDissolve
        presenter.present(controller, animated: true)
    }
}

/// The photo with translated blocks over the recognized lines.
private final class GGPhotoTranslationViewController: UIViewController {
    private let image: UIImage
    private let blocks: [GGPhotoTranslationView.Block]

    init(image: UIImage, blocks: [GGPhotoTranslationView.Block]) {
        self.image = image
        self.blocks = blocks
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    override func loadView() {
        let view = GGPhotoTranslationView(image: self.image, blocks: self.blocks)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.close)))
        self.view = view
    }

    @objc private func close() {
        self.dismiss(animated: true)
    }
}

final class GGPhotoTranslationView: UIView {
    struct Block {
        let text: String
        let box: CGRect
    }

    private let imageView = UIImageView()
    private let blocks: [Block]
    private var labels: [UILabel] = []

    init(image: UIImage, blocks: [Block]) {
        self.blocks = blocks
        super.init(frame: .zero)
        self.backgroundColor = .black
        self.imageView.image = image
        self.imageView.contentMode = .scaleAspectFit
        self.addSubview(self.imageView)
        for block in blocks {
            let label = UILabel()
            label.text = block.text
            label.textColor = .black
            label.backgroundColor = UIColor(white: 1.0, alpha: 0.88)
            label.numberOfLines = 0
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.3
            label.textAlignment = .natural
            label.layer.cornerRadius = 3.0
            label.clipsToBounds = true
            self.labels.append(label)
            self.addSubview(label)
        }
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.imageView.frame = self.bounds
        guard let image = self.imageView.image, image.size.width > 0.0, image.size.height > 0.0 else {
            return
        }
        let scale = min(self.bounds.width / image.size.width, self.bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (self.bounds.width - fitted.width) / 2.0, y: (self.bounds.height - fitted.height) / 2.0)
        for (block, label) in zip(self.blocks, self.labels) {
            let frame = CGRect(
                x: origin.x + block.box.minX * fitted.width,
                y: origin.y + (1.0 - block.box.maxY) * fitted.height,
                width: block.box.width * fitted.width,
                height: block.box.height * fitted.height
            )
            label.frame = frame.insetBy(dx: -2.0, dy: -1.0)
            label.font = UIFont.systemFont(ofSize: max(8.0, frame.height * 0.8))
        }
    }
}
