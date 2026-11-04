import Foundation
import GGAppearanceSettings

/// Entry point of the GGAppearance feature module (owner W2-4): appearance of messages, theme and
/// backgrounds, the profile's info rows and header.
///
/// One snapshot (`GGAppearanceSnapshot`) carries everything that changes the theme or the layout of
/// messages; it rebuilds the theme once per change (GGThemeHooks.invalidate). Decorations that need
/// no relayout (animated backgrounds, snowfall, screen-edge bands) follow their own settings' signals.
public enum GGAppearanceModule {
    /// Declares settings, menu rows, hook handlers and migrations. Called once on the main
    /// thread from `GGFeatures.registerAll()`, before `GGHookRegistry.freeze()`.
    public static func register() {
        assert(Thread.isMainThread)
        GGAppearanceSettings.declare()
        GGAppearanceMigration.register()

        GGFonts.register()
        GGCustomFonts.registerProvider()
        GGAppearanceTheme.register()
        GGAmoledKeyboard.register()
        GGChatMessages.register()
        GGChatDecor.register()
        GGChatListDecor.register()
        GGProfileDecor.register()
        GGAppearancePendingPoints.register()

        GGAppearanceMenu.register()
    }
}
