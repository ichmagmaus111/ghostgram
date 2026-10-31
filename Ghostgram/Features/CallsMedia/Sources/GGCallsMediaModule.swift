import Foundation

/// Entry point of the GGCallsMedia feature module. Owner: W3-3.
public enum GGCallsMediaModule {
    /// Declares settings, menu rows, hook handlers and migrations. Called once on the main
    /// thread from `GGFeatures.registerAll()`, before `GGHookRegistry.freeze()`.
    public static func register() {
        assert(Thread.isMainThread)
        GGCallsMediaSettings.declare()
        GGCallsMediaMigrations.register()

        GGTransferTuning.register()
        GGGalleryTweaks.register()
        GGSubtitlesFeature.register()
        GGDownloadStatusViews.register()
        GGCallFeatures.register()
        GGCallsMediaMenu.register()

        // Handlers of the points that requests R1 and R2 add to GGHooks (Sources/Pending).
        GGCallsMediaPending.register()
    }
}
