import Foundation
import GGCore
import GGHooks
import GGFeaturesShared

/// Entry point of the GGMessages feature module (W2-3): restriction bypasses, the outgoing text
/// pipeline, translation, the message menu and gestures, the «Чаты» and «Уведомления» sections.
public enum GGMessagesModule {
    /// Declares settings, menu rows, hook handlers and migrations. Called once on the main
    /// thread from `GGFeatures.registerAll()`, before `GGHookRegistry.freeze()`.
    public static func register() {
        // Settings shared with upstream modules and the extensions are declared by
        // GGMessagesShared.register() (called before this one by GGFeaturesShared.registerForApp()).
        let _ = GGOutgoingPipeline.replacementRules

        GGRestrictionHandlers.register()
        GGKeptMediaMenu.register()
        GGMessageDecorations.register()
        GGOutgoingPipeline.register()
        GGOutgoingTransforms.register()
        GGTranslationProviders.register()
        GGTranslateBeforeSending.register()
        GGPhotoTranslation.register()
        GGTranslationMenu.register()
        GGTranslationQuickAction.register()
        GGMessageMenuCustomization.register()
        GGInputAndGestures.register()
        GGAutoQuote.register()
        GGOutgoingLanguageMenu.register()
        GGChatsHandlers.register()
        GGPinnedChats.register()
        GGLocalCreatorMode.register()

        GGMessagesMenu.register()
        GGMessagesMigrations.register()

        // Placeholders of dropped pushes the notification extension did not live to remove
        // (GGEmptyNotifications); one async query, nothing when there are none.
        GGLifecycleHooks.applicationDidBecomeActive.register({
            GGEmptyNotifications.removeDelivered()
        })
    }
}
