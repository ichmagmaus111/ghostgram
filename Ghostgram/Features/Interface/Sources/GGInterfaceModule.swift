import Foundation

/// Entry point of the GGInterface feature module. Owner: W2-5.
public enum GGInterfaceModule {
    /// Declares settings, menu rows, hook handlers and migrations. Called once on the main
    /// thread from `GGFeatures.registerAll()`, before `GGHookRegistry.freeze()`.
    public static func register() {
        assert(Thread.isMainThread)
        InterfaceSettings.declare()
        InterfaceMigrations.register()
        // Hot paths read this snapshot; it follows every settings change from here on.
        InterfaceSnapshots.shared.start()

        GGChatListFeature.register()
        GGFoldersFeature.register()
        GGTabBarFeature.register()
        GGSettingsTabLayout.register()
        GGInputFeature.register()
        GGInputBarEditor.register()
        GGQuickButtonsFeature.register()
        GGCustomReactions.register()
        GGIconPackResolver.shared.register()
        GGIconPackStorage.shared.migrateLegacyPacksIfNeeded()
        GGIslandBadge.shared.register()
        // Handlers of points that request R4/R9 add to GGHooks (Sources/Pending).
        GGInterfacePending.register()

        InterfaceMenu.register()
    }
}
