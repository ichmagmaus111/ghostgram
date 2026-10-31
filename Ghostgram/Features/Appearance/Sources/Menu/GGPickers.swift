import Foundation
import UIKit
import ObjectiveC
import PhotosUI
import UniformTypeIdentifiers
import Display
import GGCore
import GGSettingsUI
import GGAppearanceSettings

/// The system color picker for one color setting. The value is written once, when the picker
/// closes — not on every move of the finger (the old picker posted a settings notification per
/// frame, each rebuilding every chat cell) — and only if a color was picked in it: the picker
/// starts on the current or the theme's color, and closing it untouched must leave «Automatic» as it
/// is.
enum GGColorPicker {
    private static var key: UInt8 = 0

    static func present(context: GGMenuContext, setting: GGSetting<String>, fallback: UIColor) {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        if let rgb = ggAppearanceParseColor(setting.value) {
            picker.selectedColor = UIColor(rgb: rgb)
        } else {
            picker.selectedColor = fallback
        }
        let delegate = GGColorPickerDelegate(setting: setting)
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &GGColorPicker.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        context.presentNative(picker)
    }
}

private final class GGColorPickerDelegate: NSObject, UIColorPickerViewControllerDelegate {
    private let setting: GGSetting<String>
    private var didPick = false

    init(setting: GGSetting<String>) {
        self.setting = setting
        super.init()
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        self.didPick = true
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        if !self.didPick {
            return
        }
        var red: CGFloat = 0.0
        var green: CGFloat = 0.0
        var blue: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        guard viewController.selectedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return
        }
        let r = UInt32(max(0.0, min(1.0, red)) * 255.0)
        let g = UInt32(max(0.0, min(1.0, green)) * 255.0)
        let b = UInt32(max(0.0, min(1.0, blue)) * 255.0)
        self.setting.set(ggAppearanceColorString((r << 16) | (g << 8) | b))
    }
}

/// File and photo pickers for animated backgrounds. The delegates live as long as their picker
/// (associated object); the work after a pick runs off the main thread.
enum GGPickers {
    private static var key: UInt8 = 0

    static func pickBackground(context: GGMenuContext, kind: GGAnimatedBackgroundKind) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: GGStrings.Appearance.Background.fromPhotos, style: .default, handler: { _ in
            GGPickers.pickBackgroundFromPhotos(context: context, kind: kind)
        }))
        sheet.addAction(UIAlertAction(title: GGStrings.Appearance.Background.fromFiles, style: .default, handler: { _ in
            GGPickers.pickBackgroundFromFiles(context: context, kind: kind)
        }))
        sheet.addAction(UIAlertAction(title: context.presentationData.strings.Common_Cancel, style: .cancel, handler: nil))
        context.presentNative(sheet)
    }

    private static func startImport(_ url: URL, context: GGMenuContext, kind: GGAnimatedBackgroundKind, cleanup: (() -> Void)?) {
        context.presentToast(GGStrings.Appearance.Background.preparing)
        GGAnimatedBackgrounds.importFile(at: url, kind: kind, completion: { success in
            cleanup?()
            context.presentToast(success ? GGStrings.Appearance.Background.ready : GGStrings.Appearance.Background.failed)
        })
    }

    private static func pickBackgroundFromFiles(context: GGMenuContext, kind: GGAnimatedBackgroundKind) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.gif, .movie, .mpeg4Movie, .quickTimeMovie], asCopy: true)
        picker.allowsMultipleSelection = false
        let delegate = GGDocumentPickerDelegate(pick: { url in
            GGPickers.startImport(url, context: context, kind: kind, cleanup: {
                try? FileManager.default.removeItem(at: url)
            })
        })
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &GGPickers.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        context.presentNative(picker)
    }

    /// «Добавить шрифт…»: a font file from Files (owner 2026-10-27). The picked copy is temporary;
    /// GGCustomFonts copies it into the app's container.
    static func pickFont(context: GGMenuContext) {
        var types: [UTType] = [.font]
        for fileExtension in ["ttf", "otf", "ttc"] {
            if let type = UTType(filenameExtension: fileExtension), !types.contains(type) {
                types.append(type)
            }
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        let delegate = GGDocumentPickerDelegate(pick: { url in
            GGCustomFonts.importFont(at: url, completion: { result in
                try? FileManager.default.removeItem(at: url)
                switch result {
                case let .added(font):
                    context.presentToast(GGStrings.Appearance.Font.added(name: font.familyName))
                case .notAFont:
                    context.presentToast(GGStrings.Appearance.Font.notAFont)
                case .tooMany:
                    context.presentToast(GGStrings.Appearance.Font.tooMany)
                }
            })
        })
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &GGPickers.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        context.presentNative(picker)
    }

    private static func pickBackgroundFromPhotos(context: GGMenuContext, kind: GGAnimatedBackgroundKind) {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 1
        configuration.filter = .any(of: [.videos, .images])
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = GGPhotoPickerDelegate(pick: { url in
            GGPickers.startImport(url, context: context, kind: kind, cleanup: {
                try? FileManager.default.removeItem(at: url)
            })
        }, failed: {
            context.presentToast(GGStrings.Appearance.Background.failed)
        })
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &GGPickers.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        context.presentNative(picker)
    }
}

private final class GGDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let pick: (URL) -> Void

    init(pick: @escaping (URL) -> Void) {
        self.pick = pick
        super.init()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first {
            self.pick(url)
        }
    }
}

/// Photos hands out GIFs as images: the GIF representation is asked for first, then a movie. The
/// provided file is temporary, so it is copied before the callback returns.
private final class GGPhotoPickerDelegate: NSObject, PHPickerViewControllerDelegate {
    private let pick: (URL) -> Void
    private let failed: () -> Void

    init(pick: @escaping (URL) -> Void, failed: @escaping () -> Void) {
        self.pick = pick
        self.failed = failed
        super.init()
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else {
            return
        }
        let typeIdentifier: String
        let fileExtension: String
        if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
            typeIdentifier = UTType.gif.identifier
            fileExtension = "gif"
        } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            typeIdentifier = UTType.movie.identifier
            fileExtension = "mov"
        } else {
            self.failed()
            return
        }
        let pick = self.pick
        let failed = self.failed
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            guard let url else {
                DispatchQueue.main.async {
                    failed()
                }
                return
            }
            let copyURL = FileManager.default.temporaryDirectory.appendingPathComponent("gg-background-\(UInt32.random(in: 0 ... UInt32.max)).\(fileExtension)")
            do {
                try FileManager.default.copyItem(at: url, to: copyURL)
            } catch {
                DispatchQueue.main.async {
                    failed()
                }
                return
            }
            DispatchQueue.main.async {
                pick(copyURL)
            }
        }
    }
}
