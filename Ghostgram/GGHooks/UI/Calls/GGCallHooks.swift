// Outgoing calls: a gate before the call starts («Подтверждать звонки»). Call site:
// `AccountContextImpl.requestCall` (TelegramUI/Sources/AccountContext.swift) — every outgoing
// one-to-one call (chat header, profile, call list, Siri hand-off) goes through it.

import Foundation
import TelegramCore
import AccountContext
import GGCore

public struct GGOutgoingCallRequest {
    public let context: AccountContext
    public let peerId: EnginePeer.Id
    public let isVideo: Bool
}

public enum GGCallHooks {
    /// Gate before an outgoing call. Return `true` to take over and call `proceed()` after the
    /// check; the call site is entered again and the gate is not asked a second time. Main thread.
    public static let outgoingCall = GGHookPoint<(GGOutgoingCallRequest, @escaping () -> Void) -> Bool>("calls.outgoingCall")

    private static var bypass = false

    /// `true` = a gate took over; the call site returns.
    public static func interceptOutgoingCall(context: AccountContext, peerId: EnginePeer.Id, isVideo: Bool, proceed: @escaping () -> Void) -> Bool {
        if GGCallHooks.outgoingCall.isEmpty {
            return false
        }
        if GGCallHooks.bypass {
            GGCallHooks.bypass = false
            return false
        }
        let request = GGOutgoingCallRequest(context: context, peerId: peerId, isVideo: isVideo)
        let continuation: () -> Void = {
            GGCallHooks.bypass = true
            proceed()
        }
        for handler in GGCallHooks.outgoingCall.handlers {
            if handler(request, continuation) {
                return true
            }
        }
        return false
    }
}
