import Foundation
import UIKit
import SwiftSignalKit
import GGCore

/// One mask being edited. The manifest lives in memory: every change reaches the live preview at
/// once (the preview's processor reads `preparedMask`), and the disk is written only when an edit
/// is finished — a slider released, a layer added, the screen closed — never on every tick.
final class GGMaskStudioSession {
    let maskId: String
    private let lock = NSLock()
    private var manifestValue: GGMaskManifest
    private var prepared: GGPreparedMask
    private let assets: GGMaskAssets
    private var isDirty = false
    /// The mask was deleted from the studio: nothing may write it back.
    private var isDeleted = false

    let changes = ValuePromise<Int>(0, ignoreRepeated: false)
    private var changesValue = 0

    /// The layer the filter picker is trying on (removed if the picker is left with Back).
    private(set) var provisionalIndex: Int?

    /// The previews of the studio screens (each screen has its own; only the one in a window runs
    /// its camera). Held weakly: a screen that is gone takes its preview with it.
    private final class WeakPreview {
        weak var view: GGMaskPreviewCameraView?

        init(_ view: GGMaskPreviewCameraView) {
            self.view = view
        }
    }
    private var previews: [WeakPreview] = []

    func makePreviewView() -> GGMaskPreviewCameraView {
        let view = GGMaskPreviewCameraView(maskProvider: { [weak self] in
            return self?.preparedMask
        }, autoStart: true)
        self.previews.removeAll(where: { $0.view == nil })
        self.previews.append(WeakPreview(view))
        return view
    }

    /// The preview on screen now, if any.
    private var activePreview: GGMaskPreviewCameraView? {
        for preview in self.previews.reversed() {
            if let view = preview.view, view.window != nil {
                return view
            }
        }
        return nil
    }

    /// «≈N fps on this device» while a preview runs.
    var measuredFps: Int? {
        guard let preview = self.activePreview else {
            return nil
        }
        let fps = preview.camera.processor.measuredFps
        return fps > 0 ? fps : nil
    }

    var isSimplified: Bool {
        return self.activePreview?.camera.processor.isSimplified ?? false
    }

    var hasRunningPreview: Bool {
        return self.activePreview?.camera.state == .running
    }

    init?(maskId: String) {
        guard let manifest = GGMaskStore.shared.manifest(id: maskId) else {
            return nil
        }
        self.maskId = maskId
        self.manifestValue = manifest
        self.assets = GGMaskAssets(directory: GGMaskStore.shared.assetsDirectory(id: maskId))
        self.prepared = GGPreparedMask(selection: .user(maskId), manifest: manifest, assets: self.assets)
    }

    var manifest: GGMaskManifest {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.manifestValue
    }

    /// Any thread (the preview's capture queue).
    var preparedMask: GGPreparedMask? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.prepared
    }

    /// Main thread. `persist`: the edit is finished, write it.
    func update(persist: Bool, _ f: (inout GGMaskManifest) -> Void) {
        self.lock.lock()
        var manifest = self.manifestValue
        f(&manifest)
        self.manifestValue = manifest
        self.prepared = GGPreparedMask(selection: .user(self.maskId), manifest: manifest, assets: self.assets)
        self.lock.unlock()
        self.isDirty = true
        if persist {
            self.flush()
        }
        self.changesValue += 1
        self.changes.set(self.changesValue)
    }

    /// Writes the manifest if it changed since the last write.
    func flush() {
        guard self.isDirty, !self.isDeleted else {
            return
        }
        self.isDirty = false
        GGMaskStore.shared.save(self.manifest)
    }

    /// Called before the mask is deleted, so a closing screen does not save it again.
    func markDeleted() {
        self.isDeleted = true
        self.isDirty = false
    }

    // MARK: Provisional layer (the filter picker's try-on)

    func tryOn(_ effect: GGMaskEffect) {
        self.update(persist: false) { manifest in
            if let index = self.provisionalIndex, index < manifest.effects.count {
                manifest.effects[index] = effect
            } else {
                manifest.effects.append(effect)
                self.provisionalIndex = manifest.effects.count - 1
            }
        }
    }

    /// Keeps the tried-on layer; returns its index.
    func commitProvisional() -> Int? {
        let index = self.provisionalIndex
        self.provisionalIndex = nil
        self.flush()
        return index
    }

    func discardProvisional() {
        guard let index = self.provisionalIndex else {
            return
        }
        self.provisionalIndex = nil
        self.update(persist: false) { manifest in
            if index < manifest.effects.count {
                manifest.effects.remove(at: index)
            }
        }
        self.isDirty = false
    }

    /// The next masked frame of the preview on screen becomes the mask's picture.
    func setThumbnailFromCamera() {
        self.activePreview?.camera.takeSnapshot({ [weak self] image in
            guard let self, let image else {
                return
            }
            GGMaskStore.shared.setThumbnail(id: self.maskId, image: image)
        })
    }
}
