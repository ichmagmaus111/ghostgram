import Foundation
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import Vision
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import PromptUI
import GGCore
import GGFeaturesShared

// The mask studio: own masks → editor of one mask (live preview, cost, layers) → adding a layer
// (try-on from the catalog of filters) → parameters of a layer. Edits stay in memory and reach the
// preview at once; the disk is written when an edit is finished. No timers: the measured frame
// rate is read when the screen rebuilds.

// MARK: - Home

func ggMakeMaskStudioHome(context: AccountContext) -> ViewController {
    weak var controllerRef: ViewController?
    var entries: [GGMaskStoreEntry] = []
    var storageSize: Int64 = 0
    let refresh = ValuePromise<Int>(0, ignoreRepeated: false)
    var refreshValue = 0
    let bump = {
        refreshValue += 1
        refresh.set(refreshValue)
    }
    let extra: Signal<Void, NoError> = combineLatest(GGMaskStore.shared.entries, GGMaskEngine.shared.changes.get(), refresh.get())
    |> deliverOnMainQueue
    |> map { value, _, _ -> Void in
        entries = value
        return Void()
    }

    let openEditor: (String) -> Void = { id in
        if let editor = ggMakeMaskEditor(context: context, maskId: id) {
            controllerRef?.push(editor)
        }
    }

    let create: () -> Void = {
        controllerRef?.present(promptController(context: context, text: GGStrings.CameraMasks.Studio.create, subtitle: GGStrings.CameraMasks.Studio.createText, value: GGStrings.CameraMasks.Studio.defaultName, placeholder: GGStrings.CameraMasks.Studio.namePlaceholder, characterLimit: 64, apply: { value in
            guard let value else {
                return
            }
            GGMaskStore.shared.create(name: value, completion: { result in
                switch result {
                case let .success(id):
                    openEditor(id)
                case let .failure(error):
                    ggPresentStudioError(context: context, controller: controllerRef, error: error)
                }
            })
        }), in: .window(.root))
    }

    let importMask = {
        let box = GGDocumentPickerBox()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.data, UTType.json, UTType.plainText], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = box
        box.retain()
        box.onDocument = { url in
            box.releaseHandlers()
            guard let url else {
                return
            }
            GGMaskStore.shared.importPackage(at: url, completion: { result in
                try? FileManager.default.removeItem(at: url)
                switch result {
                case let .success(id):
                    openEditor(id)
                case let .failure(error):
                    ggPresentStudioError(context: context, controller: controllerRef, error: error)
                }
            })
        }
        ggPresentNative(picker, from: controllerRef)
    }

    let entryActions: (GGMaskStoreEntry) -> Void = { entry in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let name = entry.manifest.displayName(languageCode: GGLocalization.shared.languageCode)
        let sheet = UIAlertController(title: name, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: GGStrings.CameraMasks.Studio.open, style: .default, handler: { _ in
            openEditor(entry.id)
        }))
        sheet.addAction(UIAlertAction(title: GGStrings.CameraMasks.Studio.apply, style: .default, handler: { _ in
            GGMaskEngine.shared.select(.user(entry.id), account: context.account.id.gg)
        }))
        sheet.addAction(UIAlertAction(title: GGStrings.CameraMasks.Studio.rename, style: .default, handler: { _ in
            controllerRef?.present(promptController(context: context, text: GGStrings.CameraMasks.Studio.rename, value: name, placeholder: GGStrings.CameraMasks.Studio.namePlaceholder, characterLimit: 64, apply: { value in
                if let value {
                    GGMaskStore.shared.rename(id: entry.id, name: value, completion: { _ in })
                }
            }), in: .window(.root))
        }))
        sheet.addAction(UIAlertAction(title: GGStrings.CameraMasks.Studio.duplicate, style: .default, handler: { _ in
            GGMaskStore.shared.duplicate(id: entry.id, completion: { _ in })
        }))
        sheet.addAction(UIAlertAction(title: GGStrings.CameraMasks.Studio.share, style: .default, handler: { _ in
            ggShareMask(id: entry.id, controller: controllerRef)
        }))
        sheet.addAction(UIAlertAction(title: GGStrings.CameraMasks.Studio.delete, style: .destructive, handler: { _ in
            ggConfirmDeleteMask(context: context, controller: controllerRef, id: entry.id, name: name, completion: {
                GGMaskStore.shared.diskSize(completion: { size in
                    storageSize = size
                    bump()
                })
            })
        }))
        sheet.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        ggPresentNative(sheet, from: controllerRef)
    }

    let controller = ggMakeListScreen(context: context, extra: extra, content: {
        var rows: [GGListRow] = []
        rows.append(GGListRow(id: "create.header", section: 0, kind: .header(GGStrings.CameraMasks.Studio.sandbox)))
        rows.append(GGListRow(id: "create", section: 0, kind: .action(title: GGStrings.CameraMasks.Studio.create, destructive: false, enabled: true), action: create))
        rows.append(GGListRow(id: "import", section: 0, kind: .action(title: GGStrings.CameraMasks.Studio.importFile, destructive: false, enabled: true), action: importMask))

        rows.append(GGListRow(id: "masks.header", section: 1, kind: .header(GGStrings.CameraMasks.Studio.myMasks)))
        if entries.isEmpty {
            rows.append(GGListRow(id: "masks.empty", section: 1, kind: .footer(GGStrings.CameraMasks.Studio.empty)))
        }
        let current = GGMaskSelection(storage: GGMaskSettings.selection.value)
        for entry in entries {
            let budget = GGMaskBudget.evaluate(entry.manifest.effects)
            let applied = current == .user(entry.id) ? " · " + GGStrings.CameraMasks.Studio.applied : ""
            let label = GGStrings.CameraMasks.Studio.layers(count: entry.manifest.effects.count) + " · " + GGStrings.CameraMasks.Studio.fps(fps: "\(budget.estimatedFps)") + applied
            rows.append(GGListRow(id: "mask." + entry.id, section: 1, kind: .disclosure(title: entry.manifest.displayName(languageCode: GGLocalization.shared.languageCode), label: label, icon: GGMaskStore.shared.thumbnail(id: entry.id).map { ggStudioIcon($0) }, enabled: true), action: {
                entryActions(entry)
            }))
        }
        var footer = GGStrings.CameraMasks.Studio.info
        if storageSize > 0 {
            footer += "\n" + GGStrings.CameraMasks.Studio.storage(size: ByteCountFormatter.string(fromByteCount: storageSize, countStyle: .file))
        }
        rows.append(GGListRow(id: "footer", section: 2, kind: .footer(footer)))
        return GGListScreenContent(title: GGStrings.CameraMasks.Studio.title, rows: rows)
    })
    controllerRef = controller
    GGMaskStore.shared.diskSize(completion: { size in
        storageSize = size
        bump()
    })
    return controller
}

private func ggStudioIcon(_ image: UIImage) -> UIImage {
    let side: CGFloat = 30.0
    let format = UIGraphicsImageRendererFormat()
    return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
        UIBezierPath(roundedRect: CGRect(x: 0.0, y: 0.0, width: side, height: side), cornerRadius: 7.0).addClip()
        image.draw(in: CGRect(x: 0.0, y: 0.0, width: side, height: side))
    }
}

private func ggShareMask(id: String, controller: ViewController?) {
    GGMaskStore.shared.export(id: id, completion: { url in
        guard let url else {
            return
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url)
        }
        ggPresentNative(activity, from: controller)
    })
}

private func ggConfirmDeleteMask(context: AccountContext, controller: ViewController?, id: String, name: String, willDelete: @escaping () -> Void = {}, completion: @escaping () -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    controller?.present(textAlertController(context: context, title: GGStrings.CameraMasks.Studio.deleteTitle, text: name, actions: [
        TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
        TextAlertAction(type: .destructiveAction, title: GGStrings.CameraMasks.Studio.delete, action: {
            willDelete()
            if GGMaskSelection(storage: GGMaskSettings.selection.value) == .user(id) {
                GGMaskSettings.selection.set("")
            }
            if GGMaskSelection(storage: GGAnonymousMode.mask.value) == .user(id) {
                GGAnonymousMode.mask.reset()
            }
            GGMaskStore.shared.delete(id: id, completion: completion)
        })
    ]), in: .window(.root))
}

private func ggPresentStudioError(context: AccountContext, controller: ViewController?, error: GGMaskStoreError) {
    let text: String
    switch error {
    case .emptyName:
        text = GGStrings.CameraMasks.Studio.Error.emptyName
    case .package:
        text = GGStrings.CameraMasks.Studio.Error.package
    case let .version(version):
        text = GGStrings.CameraMasks.Studio.Error.version(version: "\(version)")
    case .read:
        text = GGStrings.CameraMasks.Studio.Error.read
    case .asset:
        text = GGStrings.CameraMasks.Studio.Error.asset
    case .notFound:
        text = GGStrings.CameraMasks.Studio.Error.notFound
    case .write:
        text = GGStrings.CameraMasks.Studio.Error.write
    }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    controller?.present(textAlertController(context: context, title: GGStrings.CameraMasks.Studio.Error.title, text: text, actions: [
        TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
    ]), in: .window(.root))
}

// MARK: - Editor

func ggMakeMaskEditor(context: AccountContext, maskId: String) -> ViewController? {
    guard let session = GGMaskStudioSession(maskId: maskId) else {
        return nil
    }
    weak var controllerRef: ViewController?
    let extra: Signal<Void, NoError> = combineLatest(session.changes.get(), GGMaskEngine.shared.changes.get())
    |> deliverOnMainQueue
    |> map { _, _ -> Void in
        return Void()
    }
    let languageCode = { GGLocalization.shared.languageCode }

    let layerActions: (Int) -> Void = { index in
        let manifest = session.manifest
        guard index < manifest.effects.count else {
            return
        }
        let effect = manifest.effects[index]
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let sheet = UIAlertController(title: GGMaskStudioNames.layerTitle(effect), message: nil, preferredStyle: .actionSheet)
        if effect.type == .filter {
            sheet.addAction(UIAlertAction(title: GGStrings.CameraMasks.Studio.configure, style: .default, handler: { _ in
                controllerRef?.push(ggMakeLayerParams(context: context, session: session, index: index))
            }))
        }
        sheet.addAction(UIAlertAction(title: effect.isEnabled ? GGStrings.CameraMasks.Studio.turnOff : GGStrings.CameraMasks.Studio.turnOn, style: .default, handler: { _ in
            session.update(persist: true) { manifest in
                manifest.effects[index].enabled = !effect.isEnabled
            }
        }))
        if index > 0 {
            sheet.addAction(UIAlertAction(title: GGStrings.CameraMasks.Studio.moveDown, style: .default, handler: { _ in
                session.update(persist: true) { manifest in
                    manifest.effects.swapAt(index, index - 1)
                }
            }))
        }
        if index + 1 < manifest.effects.count {
            sheet.addAction(UIAlertAction(title: GGStrings.CameraMasks.Studio.moveUp, style: .default, handler: { _ in
                session.update(persist: true) { manifest in
                    manifest.effects.swapAt(index, index + 1)
                }
            }))
        }
        sheet.addAction(UIAlertAction(title: GGStrings.CameraMasks.Studio.removeLayer, style: .destructive, handler: { _ in
            session.update(persist: true) { manifest in
                manifest.effects.remove(at: index)
            }
        }))
        sheet.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        ggPresentNative(sheet, from: controllerRef)
    }

    let addFaceSwap = {
        let effect = GGFilterCatalog.descriptor("face.swapImage")?.makeEffect() ?? GGMaskEffect.filter("face.swapImage")
        guard GGMaskBudget.canAppend(effect, to: session.manifest.effects) else {
            ggStudioAlert(context: context, controller: controllerRef, title: GGStrings.CameraMasks.Filter.Face.swapImage, text: GGStrings.CameraMasks.Studio.tooHeavy)
            return
        }
        ggPickPhoto(controller: controllerRef, completion: { image in
            guard let image else {
                return
            }
            ggCropFace(image, completion: { cropped in
                guard let cropped else {
                    ggStudioAlert(context: context, controller: controllerRef, title: GGStrings.CameraMasks.Studio.noFaceTitle, text: GGStrings.CameraMasks.Studio.noFaceText)
                    return
                }
                GGMaskStore.shared.importImage(cropped, maskId: session.maskId, completion: { name in
                    guard let name else {
                        return
                    }
                    var layer = effect
                    layer.asset = name
                    session.update(persist: true) { manifest in
                        manifest.effects.append(layer)
                    }
                    controllerRef?.push(ggMakeLayerParams(context: context, session: session, index: session.manifest.effects.count - 1))
                })
            })
        })
    }

    let controller = ggMakeListScreen(context: context, extra: extra, content: {
        let manifest = session.manifest
        let budget = GGMaskBudget.evaluate(manifest.effects)
        var rows: [GGListRow] = []
        rows.append(GGListRow(id: "preview", section: 0, kind: .view(height: 340.0, key: "preview", make: {
            return session.makePreviewView()
        }, update: { _ in })))
        rows.append(GGListRow(id: "preview.hint", section: 0, kind: .footer(GGStrings.CameraMasks.Studio.previewHint)))

        rows.append(GGListRow(id: "load.header", section: 1, kind: .header(GGStrings.CameraMasks.Studio.loadSection)))
        let summary: String
        if budget.violations.contains(.overBudget) {
            summary = GGStrings.CameraMasks.Studio.budgetOver
        } else if budget.isWarning {
            summary = GGStrings.CameraMasks.Studio.budgetWarning
        } else {
            summary = GGStrings.CameraMasks.Studio.budgetOk
        }
        rows.append(GGListRow(id: "load.estimate", section: 1, kind: .disclosure(title: GGStrings.CameraMasks.Studio.estimate, label: summary + " · " + GGStrings.CameraMasks.Studio.fps(fps: "\(budget.estimatedFps)"), icon: nil, enabled: false)))
        if let fps = session.measuredFps {
            let simplified = session.isSimplified ? " · " + GGStrings.CameraMasks.Studio.simplified : ""
            rows.append(GGListRow(id: "load.measured", section: 1, kind: .disclosure(title: GGStrings.CameraMasks.Studio.measured, label: GGStrings.CameraMasks.Studio.fps(fps: "\(fps)") + simplified, icon: nil, enabled: false)))
        }
        for (index, violation) in budget.violations.enumerated() {
            rows.append(GGListRow(id: "load.violation.\(index)", section: 1, kind: .footer(GGMaskStudioNames.violation(violation))))
        }

        rows.append(GGListRow(id: "layers.header", section: 2, kind: .header(GGStrings.CameraMasks.Studio.layersSection)))
        if manifest.effects.isEmpty {
            rows.append(GGListRow(id: "layers.empty", section: 2, kind: .footer(GGStrings.CameraMasks.Studio.layersEmpty)))
        }
        for (index, effect) in manifest.effects.enumerated() {
            rows.append(GGListRow(id: "layer.\(index)", section: 2, kind: .disclosure(title: GGMaskStudioNames.layerTitle(effect), label: GGMaskStudioNames.layerSubtitle(effect), icon: nil, enabled: true), action: {
                layerActions(index)
            }))
        }
        let canAdd = manifest.effects.count < GGMaskBudget.maximumEffects
        rows.append(GGListRow(id: "layers.add", section: 2, kind: .action(title: GGStrings.CameraMasks.Studio.addLayer, destructive: false, enabled: true), action: {
            if !canAdd {
                ggStudioAlert(context: context, controller: controllerRef, title: GGStrings.CameraMasks.Studio.limitTitle, text: GGStrings.CameraMasks.Studio.limitText(count: GGMaskBudget.maximumEffects))
                return
            }
            controllerRef?.push(ggMakeFilterPicker(context: context, session: session))
        }))
        rows.append(GGListRow(id: "layers.faceSwap", section: 2, kind: .action(title: GGStrings.CameraMasks.Studio.faceSwap, destructive: false, enabled: canAdd), action: addFaceSwap))

        rows.append(GGListRow(id: "mask.header", section: 3, kind: .header(GGStrings.CameraMasks.Studio.maskSection)))
        let name = manifest.displayName(languageCode: languageCode())
        rows.append(GGListRow(id: "mask.name", section: 3, kind: .disclosure(title: GGStrings.CameraMasks.Studio.name, label: name, icon: nil, enabled: true), action: {
            controllerRef?.present(promptController(context: context, text: GGStrings.CameraMasks.Studio.rename, value: name, placeholder: GGStrings.CameraMasks.Studio.namePlaceholder, characterLimit: 64, apply: { value in
                guard let value else {
                    return
                }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return
                }
                session.update(persist: true) { manifest in
                    manifest.name[languageCode()] = trimmed
                    manifest.name["en"] = trimmed
                }
            }), in: .window(.root))
        }))
        rows.append(GGListRow(id: "mask.snapshot", section: 3, kind: .action(title: GGStrings.CameraMasks.Studio.snapshot, destructive: false, enabled: true), action: {
            if !session.hasRunningPreview {
                ggStudioAlert(context: context, controller: controllerRef, title: GGStrings.CameraMasks.Studio.snapshot, text: GGStrings.CameraMasks.Studio.snapshotNeedsCamera)
                return
            }
            session.setThumbnailFromCamera()
        }))
        let isApplied = GGMaskSelection(storage: GGMaskSettings.selection.value) == .user(maskId)
        rows.append(GGListRow(id: "mask.apply", section: 3, kind: .disclosure(title: GGStrings.CameraMasks.Studio.apply, label: isApplied ? GGStrings.CameraMasks.Studio.applied : "", icon: nil, enabled: true), action: {
            session.flush()
            GGMaskEngine.shared.select(.user(maskId), account: context.account.id.gg)
            ggStudioAlert(context: context, controller: controllerRef, title: GGStrings.CameraMasks.Studio.appliedTitle, text: GGStrings.CameraMasks.Studio.appliedText)
        }))
        rows.append(GGListRow(id: "mask.share", section: 3, kind: .action(title: GGStrings.CameraMasks.Studio.share, destructive: false, enabled: true), action: {
            session.flush()
            ggShareMask(id: maskId, controller: controllerRef)
        }))
        rows.append(GGListRow(id: "mask.duplicate", section: 3, kind: .action(title: GGStrings.CameraMasks.Studio.duplicate, destructive: false, enabled: true), action: {
            session.flush()
            GGMaskStore.shared.duplicate(id: maskId, completion: { newId in
                if let newId, let editor = ggMakeMaskEditor(context: context, maskId: newId) {
                    controllerRef?.push(editor)
                }
            })
        }))
        rows.append(GGListRow(id: "mask.delete", section: 3, kind: .action(title: GGStrings.CameraMasks.Studio.deleteMask, destructive: true, enabled: true), action: {
            ggConfirmDeleteMask(context: context, controller: controllerRef, id: maskId, name: name, willDelete: {
                session.markDeleted()
            }, completion: {
                let _ = (controllerRef?.navigationController as? NavigationController)?.popViewController(animated: true)
            })
        }))
        rows.append(GGListRow(id: "footer", section: 4, kind: .footer(GGStrings.CameraMasks.Studio.editorFooter)))
        return GGListScreenContent(title: name, rows: rows)
    })
    controller.didAppear = { _ in
        // A mask without a picture gets the first masked frame of the preview as one.
        if GGMaskStore.shared.thumbnail(id: maskId) == nil {
            session.setThumbnailFromCamera()
        }
    }
    controller.didDisappear = { _ in
        session.flush()
    }
    controllerRef = controller
    return controller
}

/// Whether a screen that just disappeared was closed (popped) rather than covered by a pushed one.
/// Telegram's navigation keeps a weak reference to the stack after a pop, so the reference itself
/// says nothing; the stack does.
private func ggWasClosed(_ controller: ViewController?) -> Bool {
    guard let controller else {
        return true
    }
    guard let navigationController = controller.navigationController as? NavigationController else {
        return true
    }
    return !navigationController.viewControllers.contains(where: { $0 === controller })
}

private func ggStudioAlert(context: AccountContext, controller: ViewController?, title: String, text: String) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    controller?.present(textAlertController(context: context, title: title, text: text, actions: [
        TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
    ]), in: .window(.root))
}

// MARK: - Filter picker

private func ggMakeFilterPicker(context: AccountContext, session: GGMaskStudioSession) -> ViewController {
    weak var controllerRef: ViewController?
    var chosenId: String?
    var committed = false
    let extra: Signal<Void, NoError> = session.changes.get() |> map { _ -> Void in return Void() }

    let controller = ggMakeListScreen(context: context, extra: extra, content: {
        var rows: [GGListRow] = []
        rows.append(GGListRow(id: "preview", section: 0, kind: .view(height: 260.0, key: "preview", make: {
            return session.makePreviewView()
        }, update: { _ in })))
        rows.append(GGListRow(id: "hint", section: 0, kind: .footer(GGStrings.CameraMasks.Studio.pickerHint)))
        var existing = session.manifest.effects
        if let index = session.provisionalIndex, index < existing.count {
            existing.remove(at: index)
        }
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        for (sectionIndex, category) in GGFilterCategory.allCases.enumerated() {
            let section = sectionIndex + 1
            rows.append(GGListRow(id: "category." + category.rawValue, section: section, kind: .header(GGMaskStudioNames.category(category))))
            for descriptor in GGFilterCatalog.descriptors(in: category) where descriptor.minimumOS <= osMajor {
                let effect = descriptor.makeEffect()
                let fits = GGMaskBudget.canAppend(effect, to: existing)
                rows.append(GGListRow(id: "filter." + descriptor.id, section: section, kind: .checkbox(title: GGMaskStudioNames.filterTitle(descriptor.id), subtitle: GGMaskStudioNames.filterSubtitle(descriptor), checked: chosenId == descriptor.id, enabled: true), action: {
                    if !fits {
                        ggStudioAlert(context: context, controller: controllerRef, title: GGMaskStudioNames.filterTitle(descriptor.id), text: GGStrings.CameraMasks.Studio.tooHeavy)
                        return
                    }
                    chosenId = descriptor.id
                    committed = false
                    session.tryOn(effect)
                }))
            }
        }
        return GGListScreenContent(title: GGStrings.CameraMasks.Studio.addLayer, rows: rows, rightButton: (GGStrings.CameraMasks.Studio.add, chosenId != nil, {
            guard let index = session.commitProvisional() else {
                return
            }
            committed = true
            chosenId = nil
            controllerRef?.push(ggMakeLayerParams(context: context, session: session, index: index))
        }))
    })
    controller.didDisappear = { [weak controller] _ in
        if !committed && ggWasClosed(controller) {
            session.discardProvisional()
        }
    }
    controllerRef = controller
    return controller
}

// MARK: - Layer parameters

private let ggPalette: [(hex: String, title: () -> String)] = [
    ("#FFFFFF", { GGStrings.CameraMasks.Palette.white }), ("#000000", { GGStrings.CameraMasks.Palette.black }),
    ("#8A8A8A", { GGStrings.CameraMasks.Palette.grey }), ("#FF3B30", { GGStrings.CameraMasks.Palette.red }),
    ("#FF8800", { GGStrings.CameraMasks.Palette.orange }), ("#FFD60A", { GGStrings.CameraMasks.Palette.yellow }),
    ("#34C759", { GGStrings.CameraMasks.Palette.green }), ("#00C7BE", { GGStrings.CameraMasks.Palette.teal }),
    ("#0A84FF", { GGStrings.CameraMasks.Palette.blue }), ("#5E5CE6", { GGStrings.CameraMasks.Palette.indigo }),
    ("#BF5AF2", { GGStrings.CameraMasks.Palette.purple }), ("#FF2D55", { GGStrings.CameraMasks.Palette.pink }),
    ("#C8304A", { GGStrings.CameraMasks.Palette.lipstick }), ("#FFDD88", { GGStrings.CameraMasks.Palette.warmLight }),
    ("#001133", { GGStrings.CameraMasks.Palette.deepBlue }), ("#0A0033", { GGStrings.CameraMasks.Palette.night })
]

private func ggMakeLayerParams(context: AccountContext, session: GGMaskStudioSession, index: Int) -> ViewController {
    weak var controllerRef: ViewController?
    let extra: Signal<Void, NoError> = session.changes.get() |> map { _ -> Void in return Void() }

    /// Changes one parameter. Ticks update the preview only; `persist` writes the mask.
    let setParam: (String, GGMaskParamValue, Bool) -> Void = { id, value, persist in
        session.update(persist: persist) { manifest in
            guard index < manifest.effects.count else {
                return
            }
            var params = manifest.effects[index].params ?? [:]
            params[id] = value
            manifest.effects[index].params = params
            if id == "anchor", let anchor = value.text.flatMap(GGMaskAnchor.init(rawValue:)) {
                manifest.effects[index].anchor = anchor
            }
        }
    }

    let controller = ggMakeListScreen(context: context, extra: extra, content: {
        let manifest = session.manifest
        var rows: [GGListRow] = []
        guard index < manifest.effects.count else {
            rows.append(GGListRow(id: "gone", section: 0, kind: .footer(GGStrings.CameraMasks.Studio.layerGone)))
            return GGListScreenContent(title: GGStrings.CameraMasks.Studio.paramsTitle, rows: rows)
        }
        let effect = manifest.effects[index]
        let theme = context.sharedContext.currentPresentationData.with { $0 }.theme
        rows.append(GGListRow(id: "preview", section: 0, kind: .view(height: 300.0, key: "preview", make: {
            return session.makePreviewView()
        }, update: { _ in })))

        guard let filterId = effect.filterId, let descriptor = GGFilterCatalog.descriptor(filterId) else {
            rows.append(GGListRow(id: "unknown", section: 1, kind: .footer(GGStrings.CameraMasks.Studio.unknownFilter)))
            rows.append(GGListRow(id: "remove", section: 1, kind: .action(title: GGStrings.CameraMasks.Studio.removeLayer, destructive: true, enabled: true), action: {
                session.update(persist: true) { manifest in
                    manifest.effects.remove(at: index)
                }
                let _ = (controllerRef?.navigationController as? NavigationController)?.popViewController(animated: true)
            }))
            return GGListScreenContent(title: GGStrings.CameraMasks.Studio.paramsTitle, rows: rows)
        }

        rows.append(GGListRow(id: "params.header", section: 1, kind: .header(GGStrings.CameraMasks.Studio.paramsSection)))
        let value: (GGFilterParam) -> GGMaskParamValue = { param in
            if let current = effect.params?[param.id], current != .unknown {
                return current
            }
            return param.defaultValue
        }
        func sliderRow(_ rowId: String, title: String, current: Double, range: ClosedRange<Double>, step: Double, apply: @escaping (Double, Bool) -> Void) -> GGListRow {
            return GGListRow(id: rowId, section: 1, kind: .view(height: GGSliderBlockView.height, key: "\(rowId)|\(current)|\(title)", make: {
                return GGSliderBlockView(frame: .zero)
            }, update: { view in
                guard let slider = view as? GGSliderBlockView else {
                    return
                }
                slider.step = step
                slider.format = { value in
                    return step >= 1.0 ? "\(Int(value))" : String(format: "%.2f", value)
                }
                slider.configure(title: title, value: current, range: range, theme: theme)
                slider.changed = { value in
                    apply(value, false)
                }
                slider.committed = { value in
                    apply(value, true)
                }
            }))
        }
        for param in descriptor.params {
            let title = GGMaskStudioNames.paramTitle(param.id)
            switch param.kind {
            case let .slider(min, max, step):
                rows.append(sliderRow("param." + param.id, title: title, current: value(param).number ?? min, range: min ... max, step: step, apply: { number, persist in
                    setParam(param.id, .number(number), persist)
                }))
            case .toggle:
                rows.append(GGListRow(id: "param." + param.id, section: 1, kind: .toggle(title: title, value: value(param).bool ?? false, enabled: true), toggled: { newValue in
                    setParam(param.id, .bool(newValue), true)
                }))
            case .color:
                let hex = value(param).text ?? "#FFFFFF"
                rows.append(GGListRow(id: "param." + param.id, section: 1, kind: .disclosure(title: title, label: hex.uppercased(), icon: ggColorSwatch(hex), enabled: true), action: {
                    ggPickColor(context: context, controller: controllerRef, title: title, current: hex, apply: { newHex in
                        setParam(param.id, .color(newHex), true)
                    })
                }))
            case .point:
                let point = value(param).point ?? CGPoint(x: 0.5, y: 0.5)
                rows.append(sliderRow("param." + param.id + ".x", title: title + " · X", current: Double(point.x), range: 0.0 ... 1.0, step: 0.01, apply: { x, persist in
                    let current = session.manifest.effects[index].params?[param.id]?.point ?? point
                    setParam(param.id, .point(CGPoint(x: x, y: Double(current.y))), persist)
                }))
                rows.append(sliderRow("param." + param.id + ".y", title: title + " · Y", current: Double(point.y), range: 0.0 ... 1.0, step: 0.01, apply: { y, persist in
                    let current = session.manifest.effects[index].params?[param.id]?.point ?? point
                    setParam(param.id, .point(CGPoint(x: Double(current.x), y: y)), persist)
                }))
            case .anchor, .blendMode:
                let options: [(value: String, title: String)] = param.kind == .anchor ? GGMaskAnchor.allCases.map { (value: $0.rawValue, title: GGMaskStudioNames.anchor($0)) } : GGMaskBlendMode.allCases.map { (value: $0.rawValue, title: GGMaskStudioNames.blendMode($0)) }
                let current = value(param).text ?? ""
                rows.append(GGListRow(id: "param." + param.id, section: 1, kind: .disclosure(title: title, label: options.first(where: { $0.value == current })?.title ?? current, icon: nil, enabled: true), action: {
                    let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
                    for option in options {
                        sheet.addAction(UIAlertAction(title: (option.value == current ? "✓ " : "") + option.title, style: .default, handler: { _ in
                            setParam(param.id, .text(option.value), true)
                        }))
                    }
                    sheet.addAction(UIAlertAction(title: context.sharedContext.currentPresentationData.with({ $0 }).strings.Common_Cancel, style: .cancel))
                    ggPresentNative(sheet, from: controllerRef)
                }))
            case .image:
                let hasImage = effect.asset != nil
                rows.append(GGListRow(id: "param.image", section: 1, kind: .disclosure(title: title, label: hasImage ? GGStrings.CameraMasks.Studio.imageChosen : GGStrings.CameraMasks.Studio.imageNone, icon: nil, enabled: true), action: {
                    ggPickPhoto(controller: controllerRef, completion: { image in
                        guard let image else {
                            return
                        }
                        let store: (UIImage) -> Void = { picked in
                            GGMaskStore.shared.importImage(picked, maskId: session.maskId, completion: { name in
                                guard let name else {
                                    return
                                }
                                session.update(persist: true) { manifest in
                                    manifest.effects[index].asset = name
                                }
                            })
                        }
                        if descriptor.id == "face.swapImage" {
                            ggCropFace(image, completion: { cropped in
                                if let cropped {
                                    store(cropped)
                                } else {
                                    ggStudioAlert(context: context, controller: controllerRef, title: GGStrings.CameraMasks.Studio.noFaceTitle, text: GGStrings.CameraMasks.Studio.noFaceText)
                                }
                            })
                        } else {
                            store(image)
                        }
                    })
                }))
                if hasImage {
                    rows.append(GGListRow(id: "param.image.clear", section: 1, kind: .action(title: GGStrings.CameraMasks.Studio.imageClear, destructive: true, enabled: true), action: {
                        session.update(persist: true) { manifest in
                            manifest.effects[index].asset = nil
                        }
                    }))
                } else {
                    rows.append(GGListRow(id: "param.image.hint", section: 1, kind: .footer(GGStrings.CameraMasks.Studio.imageNeeded)))
                }
            case .emoji:
                let current = value(param).text ?? "🙂"
                rows.append(GGListRow(id: "param." + param.id, section: 1, kind: .disclosure(title: title, label: current, icon: nil, enabled: true), action: {
                    controllerRef?.present(promptController(context: context, text: GGStrings.CameraMasks.Studio.emojiPrompt, value: current, characterLimit: 8, apply: { text in
                        guard let text else {
                            return
                        }
                        let glyph = String(text.trimmingCharacters(in: .whitespaces).prefix(2))
                        setParam(param.id, .text(glyph.isEmpty ? "🙂" : glyph), true)
                    }), in: .window(.root))
                }))
            case .curve5, .curveRGB:
                let count = param.kind == .curve5 ? 5 : 15
                var values = value(param).numbers ?? []
                if values.count != count {
                    values = (0 ..< count).map { Double($0 % 5) / 4.0 }
                }
                for i in 0 ..< count {
                    let channel: String
                    if param.kind == .curveRGB {
                        channel = [GGStrings.CameraMasks.Studio.curveRed, GGStrings.CameraMasks.Studio.curveGreen, GGStrings.CameraMasks.Studio.curveBlue][i / 5] + " · "
                    } else {
                        channel = title + " · "
                    }
                    rows.append(sliderRow("param.\(param.id).\(i)", title: channel + GGStrings.CameraMasks.Studio.curvePoint(index: "\(i % 5 + 1)"), current: values[i], range: 0.0 ... 1.0, step: 0.01, apply: { number, persist in
                        var updated = session.manifest.effects[index].params?[param.id]?.numbers ?? values
                        if updated.count != count {
                            updated = values
                        }
                        updated[i] = number
                        setParam(param.id, .numbers(updated), persist)
                    }))
                }
            }
        }
        if descriptor.param("opacity") == nil {
            rows.append(sliderRow("layer.opacity", title: GGStrings.CameraMasks.Studio.layerOpacity, current: effect.opacity ?? 1.0, range: 0.0 ... 1.0, step: 0.01, apply: { number, persist in
                session.update(persist: persist) { manifest in
                    manifest.effects[index].opacity = number >= 0.999 ? nil : number
                }
            }))
        }

        rows.append(GGListRow(id: "layer.header", section: 2, kind: .header(GGStrings.CameraMasks.Studio.layerSection)))
        rows.append(GGListRow(id: "layer.enabled", section: 2, kind: .toggle(title: GGStrings.CameraMasks.Studio.layerEnabled, value: effect.isEnabled, enabled: true), toggled: { value in
            session.update(persist: true) { manifest in
                manifest.effects[index].enabled = value ? nil : false
            }
        }))
        rows.append(GGListRow(id: "layer.reset", section: 2, kind: .action(title: GGStrings.CameraMasks.Studio.resetLayer, destructive: false, enabled: true), action: {
            session.update(persist: true) { manifest in
                var fresh = descriptor.makeEffect()
                fresh.asset = manifest.effects[index].asset
                fresh.anchor = manifest.effects[index].anchor
                manifest.effects[index] = fresh
            }
        }))
        rows.append(GGListRow(id: "layer.remove", section: 2, kind: .action(title: GGStrings.CameraMasks.Studio.removeLayer, destructive: true, enabled: true), action: {
            session.update(persist: true) { manifest in
                manifest.effects.remove(at: index)
            }
            let _ = (controllerRef?.navigationController as? NavigationController)?.popViewController(animated: true)
        }))
        rows.append(GGListRow(id: "layer.footer", section: 2, kind: .footer(GGStrings.CameraMasks.Studio.layerCost(units: "\(GGMaskBudget.cost(of: effect))") + GGMaskStudioNames.needsSuffix(GGFilterCatalog.visionNeeds(of: effect)))))
        return GGListScreenContent(title: GGMaskStudioNames.filterTitle(descriptor.id), rows: rows)
    })
    controller.didDisappear = { _ in
        session.flush()
    }
    controllerRef = controller
    return controller
}

private func ggColorSwatch(_ hex: String) -> UIImage? {
    guard let rgba = ggParseHexColor(hex) else {
        return nil
    }
    let format = UIGraphicsImageRendererFormat()
    return UIGraphicsImageRenderer(size: CGSize(width: 22.0, height: 22.0), format: format).image { _ in
        UIColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: 1.0).setFill()
        UIBezierPath(ovalIn: CGRect(x: 1.0, y: 1.0, width: 20.0, height: 20.0)).fill()
        UIColor(white: 0.5, alpha: 0.5).setStroke()
        UIBezierPath(ovalIn: CGRect(x: 1.0, y: 1.0, width: 20.0, height: 20.0)).stroke()
    }
}

private func ggPickColor(context: AccountContext, controller: ViewController?, title: String, current: String, apply: @escaping (String) -> Void) {
    let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
    for entry in ggPalette {
        sheet.addAction(UIAlertAction(title: (entry.hex.uppercased() == current.uppercased() ? "✓ " : "") + entry.title(), style: .default, handler: { _ in
            apply(entry.hex)
        }))
    }
    sheet.addAction(UIAlertAction(title: GGStrings.CameraMasks.Studio.customColor, style: .default, handler: { _ in
        controller?.present(promptController(context: context, text: GGStrings.CameraMasks.Studio.customColor, subtitle: GGStrings.CameraMasks.Studio.customColorText, value: current, characterLimit: 9, apply: { value in
            guard let value else {
                return
            }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard ggParseHexColor(trimmed) != nil else {
                ggStudioAlert(context: context, controller: controller, title: GGStrings.CameraMasks.Studio.badColorTitle, text: GGStrings.CameraMasks.Studio.badColorText)
                return
            }
            apply(trimmed.hasPrefix("#") ? trimmed : "#" + trimmed)
        }), in: .window(.root))
    }))
    sheet.addAction(UIAlertAction(title: context.sharedContext.currentPresentationData.with({ $0 }).strings.Common_Cancel, style: .cancel))
    ggPresentNative(sheet, from: controller)
}

// MARK: - Pickers

private final class GGPhotoPickerBox: GGPickerDelegateBox, PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
            self.onImage?(nil)
            self.releaseHandlers()
            return
        }
        provider.loadObject(ofClass: UIImage.self, completionHandler: { object, _ in
            DispatchQueue.main.async {
                self.onImage?(object as? UIImage)
                self.releaseHandlers()
            }
        })
    }
}

private final class GGDocumentPickerBox: GGPickerDelegateBox, UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.onDocument?(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.onDocument?(nil)
    }
}

private func ggPickPhoto(controller: ViewController?, completion: @escaping (UIImage?) -> Void) {
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = 1
    let picker = PHPickerViewController(configuration: configuration)
    let box = GGPhotoPickerBox()
    box.onImage = completion
    box.retain()
    picker.delegate = box
    ggPresentNative(picker, from: controller)
}

/// The largest face of a photo, cropped square with room around it (the face swap's source).
private func ggCropFace(_ image: UIImage, completion: @escaping (UIImage?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let normalized = GGMaskStore.downscaled(image, maxSide: 2048.0)
        guard let cgImage = normalized.cgImage else {
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else {
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let box = face.boundingBox
        let side = min(max(box.width * width, box.height * height) * 1.8, min(width, height))
        let center = CGPoint(x: box.midX * width, y: (1.0 - box.midY) * height)
        var rect = CGRect(x: center.x - side / 2.0, y: center.y - side / 2.0, width: side, height: side)
        rect.origin.x = max(0.0, min(width - side, rect.origin.x))
        rect.origin.y = max(0.0, min(height - side, rect.origin.y))
        let cropped = cgImage.cropping(to: rect.integral).map { UIImage(cgImage: $0) }
        DispatchQueue.main.async {
            completion(cropped)
        }
    }
}
