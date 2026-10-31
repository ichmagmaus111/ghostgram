import Foundation
import AVFoundation
import GGCore

// Compiled into TelegramAudio (filegroup //Ghostgram/Features/Voice:TelegramAudioPoints), owner W3-1.

public enum GGAudioSessionHooks {
    /// Policy (any `true`): record voice messages and round videos with the built-in microphone even
    /// when a headset (wired, AirPods, Bluetooth) is connected (SG-F3). Calls are not affected.
    public static let prefersBuiltInMicrophoneForRecording = GGHookPoint<() -> Bool>("audioSession.builtInMicrophoneForRecording")

    static func prefersBuiltInMicrophone() -> Bool {
        if GGAudioSessionHooks.prefersBuiltInMicrophoneForRecording.isEmpty {
            return false
        }
        for handler in GGAudioSessionHooks.prefersBuiltInMicrophoneForRecording.handlers {
            if handler() {
                return true
            }
        }
        return false
    }
}

/// `ManagedAudioSessionImpl.setupOutputMode`, after the upstream input choice, for recording sessions
/// with a headset connected. Moving the output off Bluetooth is what lets the built-in microphone take
/// over (a Bluetooth headset keeps its own microphone while it holds the route).
func ggApplyBuiltInMicrophoneIfNeeded(isRecording: Bool, isHeadsetConnected: Bool) {
    guard isRecording, isHeadsetConnected, GGAudioSessionHooks.prefersBuiltInMicrophone() else {
        return
    }
    let session = AVAudioSession.sharedInstance()
    guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
        return
    }
    let _ = try? session.overrideOutputAudioPort(.speaker)
    let _ = try? session.setPreferredInput(builtIn)
}
