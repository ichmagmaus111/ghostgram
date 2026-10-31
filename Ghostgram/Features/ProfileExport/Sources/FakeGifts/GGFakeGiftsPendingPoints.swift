import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import GGCore

// Handlers for the two points of requests/W4-1.md R2 (added by W4-R, Ghostgram/GGHooks/Core/GGGiftHooks.swift):
//   - `GGGiftHooks.hasLocalGifts` — the own profile shows its "Gifts" tab when it has only fake
//     gifts (the tab is decided in the frozen PeerInfoData.swift from the server's gift count);
//   - `GGGiftHooks.invalidate()` — an open own profile re-publishes its gift list after a fake gift
//     was added, edited or deleted (otherwise it updates on its next page load).

enum GGFakeGiftsPendingPoints {
    static func register() {
        GGGiftHooks.hasLocalGifts.register({ account, peerId in
            guard GGFakeGiftsSettings.isEnabled.value, peerId == account.peerId else {
                return false
            }
            return !GGFakeGiftsStore.shared.resolvedGifts(accountPeerId: peerId).isEmpty
        })
    }

    /// The store published a new list for an account.
    static func storeDidChange() {
        GGGiftHooks.invalidate()
    }
}
