// Compiled into TelegramCore (filegroup //Ghostgram/GGHooks:TelegramCoreHookSources).
// Profile gifts: features may add local-only gifts to a profile's list (fake gifts on the
// user's own profile) and handle actions on them without the network.

import Foundation
import Postbox
import SwiftSignalKit
import GGCore

public struct GGProfileGiftsQuery {
    public let account: Account
    public let peerId: PeerId
    public let collectionId: Int32?
}

public enum GGProfileGiftAction {
    case setSavedToProfile(Bool)
    case setPinnedToTop(Bool)
}

public enum GGGiftHooks {
    /// Transformer of the state a profile's gift list publishes (called on every state push).
    public static let profileGifts = GGHookPoint<(inout ProfileGiftsContext.State, GGProfileGiftsQuery) -> Void>("gifts.profileGifts")

    /// Policy: `true` = the feature handled the action for this gift locally; upstream does not
    /// call the network and re-publishes the state.
    public static let localGiftAction = GGHookPoint<(StarGiftReference, GGProfileGiftAction, GGProfileGiftsQuery) -> Bool>("gifts.localGiftAction")

    /// Policy (any `true`): the profile has local-only gifts, so its «Gifts» tab is shown although
    /// the server counts none (own profile, PeerInfoData). Asked on every update of the profile's
    /// data, possibly off the main thread: answer from memory.
    public static let hasLocalGifts = GGHookPoint<(Account, PeerId) -> Bool>("gifts.hasLocalGifts")

    /// Policy (any `true`): the gift is local-only. It takes no slot of the server's pin limit and is
    /// never sent to the server in the pinned list. Main thread or the list's queue: answer from memory.
    public static let isLocalGift = GGHookPoint<(StarGiftReference, Account) -> Bool>("gifts.isLocalGift")

    /// Every live profile gift list (`ProfileGiftsContext`) publishes its state again, through
    /// `profileGifts` — call after local gifts were added, changed or removed. Any thread.
    public static func invalidate() {
        ggProfileGiftsInvalidations.putNext(Void())
    }
}

private let ggProfileGiftsInvalidations = ValuePipe<Void>()

/// GHOST hook target: PeerInfoData — the own profile's «Gifts» tab without gifts on the server.
public func ggProfileHasLocalGifts(account: Account, peerId: PeerId) -> Bool {
    if GGGiftHooks.hasLocalGifts.isEmpty {
        return false
    }
    for handler in GGGiftHooks.hasLocalGifts.handlers {
        if handler(account, peerId) {
            return true
        }
    }
    return false
}

/// GHOST hook target: PeerInfoData — the own profile's data is published again when its local-only
/// gifts change (`GGGiftHooks.invalidate()`), so the «Gifts» tab appears with the first one and goes
/// with the last one while the profile is open. Any other profile: `signal` as is.
public func ggRepublishOnLocalGiftsChange<T>(_ signal: Signal<T, NoError>, account: Account, peerId: PeerId) -> Signal<T, NoError> {
    if GGGiftHooks.hasLocalGifts.isEmpty || peerId != account.peerId {
        return signal
    }
    let changes: Signal<Void, NoError> = .single(Void()) |> then(ggProfileGiftsInvalidations.signal())
    return combineLatest(signal, changes)
    |> map { value, _ -> T in
        return value
    }
}

/// GHOST hook target: the pin limit of a profile's gift list (GiftsListView, PeerInfoGiftsPaneNode)
/// — `true` = a local-only gift (no server pin slot).
public func ggIsLocalProfileGift(_ reference: StarGiftReference?, account: Account) -> Bool {
    guard let reference, !GGGiftHooks.isLocalGift.isEmpty else {
        return false
    }
    for handler in GGGiftHooks.isLocalGift.handlers {
        if handler(reference, account) {
            return true
        }
    }
    return false
}

/// The pinned gifts that count against the server's limit (local-only gifts do not).
public func ggServerPinnedCount(_ references: [StarGiftReference], account: Account) -> Int {
    if GGGiftHooks.isLocalGift.isEmpty {
        return references.count
    }
    return references.filter { !ggIsLocalProfileGift($0, account: account) }.count
}

/// The first gifts of a list as the pinned order takes them: up to `maxCount` that count against the
/// server's limit, local-only gifts among them without taking a slot (upstream: `prefix(maxCount)`).
public func ggPinnedPrefix(_ gifts: [ProfileGiftsContext.State.StarGift], maxCount: Int, account: Account) -> [ProfileGiftsContext.State.StarGift] {
    if GGGiftHooks.isLocalGift.isEmpty {
        return Array(gifts.prefix(maxCount))
    }
    var result: [ProfileGiftsContext.State.StarGift] = []
    var serverCount = 0
    for gift in gifts {
        if ggIsLocalProfileGift(gift.reference, account: account) {
            result.append(gift)
            continue
        }
        if serverCount >= maxCount {
            break
        }
        serverCount += 1
        result.append(gift)
    }
    return result
}

/// GHOST hook target: `ProfileGiftsContextImpl.updatePinnedToTopStarGifts` — the new pinned list's
/// local-only gifts are pinned / unpinned by the feature (`localGiftAction`), and only the others
/// go on to the server. `currentlyPinned` = the published state's pinned gifts (local ones included).
func ggSplitLocalPinnedGifts(_ references: [StarGiftReference], currentlyPinned: [StarGiftReference], account: Account, peerId: PeerId, collectionId: Int32?) -> [StarGiftReference] {
    if GGGiftHooks.isLocalGift.isEmpty || GGGiftHooks.localGiftAction.isEmpty {
        return references
    }
    var server: [StarGiftReference] = []
    let wasPinned = Set(currentlyPinned)
    for reference in references {
        if ggIsLocalProfileGift(reference, account: account) {
            if !wasPinned.contains(reference) {
                let _ = ggHandleLocalGiftAction(reference, action: .setPinnedToTop(true), account: account, peerId: peerId, collectionId: collectionId)
            }
        } else {
            server.append(reference)
        }
    }
    let kept = Set(references)
    for reference in currentlyPinned where !kept.contains(reference) && ggIsLocalProfileGift(reference, account: account) {
        let _ = ggHandleLocalGiftAction(reference, action: .setPinnedToTop(false), account: account, peerId: peerId, collectionId: collectionId)
    }
    return server
}

/// GHOST hook target: `ProfileGiftsContextImpl.init`. `republish` runs on the context's queue after
/// `GGGiftHooks.invalidate()`. Nil — nothing subscribed — while no feature transforms profile gifts.
func ggObserveProfileGiftsInvalidation(queue: Queue, _ republish: @escaping () -> Void) -> Disposable? {
    if GGGiftHooks.profileGifts.isEmpty {
        return nil
    }
    return ggProfileGiftsInvalidations.signal().start(next: { _ in
        queue.async {
            republish()
        }
    })
}

func ggTransformProfileGifts(_ state: inout ProfileGiftsContext.State, account: Account, peerId: PeerId, collectionId: Int32?) {
    if GGGiftHooks.profileGifts.isEmpty {
        return
    }
    let query = GGProfileGiftsQuery(account: account, peerId: peerId, collectionId: collectionId)
    for handler in GGGiftHooks.profileGifts.handlers {
        handler(&state, query)
    }
}

func ggHandleLocalGiftAction(_ reference: StarGiftReference, action: GGProfileGiftAction, account: Account, peerId: PeerId, collectionId: Int32?) -> Bool {
    if GGGiftHooks.localGiftAction.isEmpty {
        return false
    }
    let query = GGProfileGiftsQuery(account: account, peerId: peerId, collectionId: collectionId)
    for handler in GGGiftHooks.localGiftAction.handlers {
        if handler(reference, action, query) {
            return true
        }
    }
    return false
}
