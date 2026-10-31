import Foundation
import SwiftSignalKit
import GGCore

/// The part of GGCameraMasks other zones read: the anonymous mode (a mask and a voice in one tap).
/// The voice changer (W3-1) asks `GGAnonymousMode.voicePreset(for:)` and, while it answers, uses
/// that preset instead of the user's own; it registers its presets for the menu in
/// `GGAnonymousMode.voicePresets`. Owner: W3-2.
public enum GGCameraMasksShared {
    /// Called from `GGFeaturesShared.registerForApp()` and `.registerForExtension()`.
    public static func register() {
        GGAnonymousMode.declare()
    }
}

/// A voice preset the anonymous mode can use (registered by the voice changer).
public struct GGAnonymousVoicePreset {
    public let id: String
    public let title: () -> String

    public init(id: String, title: @escaping () -> String) {
        self.id = id
        self.title = title
    }
}

/// «Анонимный режим»: a temporary override over the user's own choices, per account. While it is on,
/// round videos and calls of that account use the anonymous mask, and the voice changer uses the
/// anonymous preset. Nothing is snapshotted or restored: turning it off simply removes the override,
/// so it can never restore a preset of another account. Picking a mask by hand turns it off for that
/// account (the manual choice wins), so the two never disagree.
public enum GGAnonymousMode {
    public static let isActive = GGAccountSetting<Bool>("cameraMasks.anonymous.active", default: false)
    /// `GGMaskSelection` storage ("builtin:<id>", "catalog:<id>", "user:<id>").
    public static let mask = GGSetting<String>("cameraMasks.anonymous.mask", default: "builtin:pixelate")
    /// Id of a preset from `voicePresets`.
    public static let voice = GGSetting<String>("cameraMasks.anonymous.voice", default: "robot")

    /// The voice changer's presets for the menu. Empty: the voice row is hidden.
    public static let voicePresets = GGHookPoint<() -> [GGAnonymousVoicePreset]>("cameraMasks.anonymousVoicePresets")

    static func declare() {
        let _ = GGAnonymousMode.isActive
        let _ = GGAnonymousMode.mask
        let _ = GGAnonymousMode.voice
    }

    /// The preset the voice changer must use for this account now, or nil (the user's own settings).
    public static func voicePreset(for account: GGAccountID) -> String? {
        guard GGAnonymousMode.isActive.value(for: account) else {
            return nil
        }
        let value = GGAnonymousMode.voice.value
        return value.isEmpty ? nil : value
    }

    /// The anonymous mask storage for this account now, or nil.
    public static func maskOverride(for account: GGAccountID) -> String? {
        guard GGAnonymousMode.isActive.value(for: account) else {
            return nil
        }
        return GGAnonymousMode.mask.value
    }

    public static func allVoicePresets() -> [GGAnonymousVoicePreset] {
        var result: [GGAnonymousVoicePreset] = []
        for handler in GGAnonymousMode.voicePresets.handlers {
            result.append(contentsOf: handler())
        }
        return result
    }
}
