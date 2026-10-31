import Foundation
import TelegramCore
import AccountContext
import GGCore
import GGHooks
import GGCameraPipeline
import GGCallCameraHooks
import GGCallsMediaHooks
import GGFeaturesShared

/// Entry point of the GGCameraMasks feature module. Owner: W3-2.
public enum GGCameraMasksModule {
    /// Declares settings, menu rows, hook handlers and migrations. Called once on the main
    /// thread from `GGFeatures.registerAll()`, before `GGHookRegistry.freeze()`.
    public static func register() {
        assert(Thread.isMainThread)
        GGCameraPipelineSettings.declare()
        GGMaskSettings.declare()
        GGVirtualCameraSettings.declare()
        GGCameraMasksMigrations.register()

        // Round videos: the masks button, panel and processor exist only while masks are on (or
        // the anonymous mode of this account is). Otherwise the camera screen is upstream's.
        GGCameraHooks.roundVideoCamera.register({ context in
            guard GGMaskEngine.isActive(for: context.accountId) else {
                return nil
            }
            return GGRoundVideoMasksExtension(accountId: context.accountId)
        }, order: 100)

        // Calls: one processor in the capturer's frame hook (returns at once while masks are off),
        // the virtual camera's capturer, and two buttons in the call screen's column.
        GGCallMasks.install()
        GGCallCameraHooks.cameraCapturer.register({
            return GGVirtualCameraFeeder.makeCapturer()
        }, order: 100)
        GGCallCameraHooks.cameraSwitch.register({ capturer, isFront in
            return GGVirtualCameraFeeder.switchCamera(capturer: capturer, isFront: isFront)
        }, order: 100)
        GGCallsMediaHooks.overlayItems.register({ screen in
            let accountId = screen.context.account.id.gg
            GGCallMasks.shared.currentAccount = accountId
            // Only the buttons of features that are on: with both off the call screen gets no overlay.
            var items: [GGCallOverlayItem] = []
            if GGMaskSettings.inCalls.value || GGAnonymousMode.isActive.value(for: accountId) {
                items.append(GGCallMasksOverlayItem(accountId: accountId))
            }
            if GGVirtualCameraSettings.enabled.value {
                items.append(GGVirtualCameraOverlayItem(call: screen.call, groupCall: screen.groupCall))
            }
            return items
        }, order: 200)

        // Outgoing media: the photo watermark and «video as a round video».
        GGPhotoWatermarkHandler.register()
        GGRoundVideoImportHandler.register()

        // Telegram's size limit of a round video, known before any round video is encoded (the
        // gallery ones too, which never open the round camera); the camera re-reads it.
        GGLifecycleHooks.rootControllersDidLoad.register({ context, _ in
            GGRoundVideoServerLimits.update(encoding: context.getAppConfigValue("round_video_encoding") as? [String: Any])
            // The calls' account and own video for masks and the virtual camera, also without a call screen.
            GGCameraCallsMonitor.shared.start(sharedContext: context.sharedContext)
        }, order: 300)

        GGCameraMasksMenu.register()

        // Files of the old app (own masks, virtual camera media): moved once, off the launch
        // thread; each is a single existence check when there is nothing to move.
        GGMaskStore.migrateLegacyMasksIfNeeded()
        GGVirtualCameraLibrary.migrateLegacyFilesIfNeeded()
    }
}
