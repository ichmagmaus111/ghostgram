import Foundation

/// The pure part of «Безлимитные закрепы»: lists in, lists out, no Postbox. A pinned list is the
/// server's part (the first `limit` counted items) followed by a tail only this device knows; `tail`
/// is the remembered set of local-only pins. `isCounted` — the items the server limit counts.
enum GGPinnedTailModel {
    struct SyncResult<Item> {
        /// Stored on this device.
        let stored: [Item]
        /// Sent to the server.
        let toServer: [Item]
        /// The new tail record.
        let tail: [Item]
    }

    /// The server's part of a list: the first `limit` counted items; items that are not counted keep
    /// their places (upstream drops them on the wire itself).
    static func serverPart<Item>(_ items: [Item], limit: Int, isCounted: (Item) -> Bool) -> [Item] {
        var result: [Item] = []
        result.reserveCapacity(items.count)
        var counted = 0
        for item in items {
            if isCounted(item) {
                if counted >= limit {
                    continue
                }
                counted += 1
            }
            result.append(item)
        }
        return result
    }

    /// The tail when nothing was remembered yet: the counted items beyond the limit — the server only
    /// ever got the prefix (also true for the old client, whose tail lies in the same Postbox list).
    static func positionalTail<Item>(_ items: [Item], limit: Int, isCounted: (Item) -> Bool) -> [Item] {
        var result: [Item] = []
        var counted = 0
        for item in items where isCounted(item) {
            counted += 1
            if counted > limit {
                result.append(item)
            }
        }
        return result
    }

    /// The server's list replaces the stored one: the server's list, then the tail pins it lacks — in
    /// the stored order, or in the record's order when the stored list was wiped (an account state
    /// reset empties every chat list before the server's list arrives). A pin missing from both the
    /// server's list and the tail was unpinned elsewhere and goes away, as upstream. The new tail is
    /// exactly what was appended.
    static func fromServer<Item: Hashable>(server: [Item], local: [Item], tail: [Item], isCounted: (Item) -> Bool) -> (stored: [Item], tail: [Item]) {
        let serverSet = Set(server)
        let tailSet = Set(tail)
        let candidates: [Item]
        if local.contains(where: isCounted) {
            candidates = local.filter { tailSet.contains($0) }
        } else {
            candidates = tail
        }
        var stored = server
        var newTail: [Item] = []
        for item in candidates where isCounted(item) && !serverSet.contains(item) {
            stored.append(item)
            newTail.append(item)
        }
        return (stored, newTail)
    }

    /// The part of `items` a synchronization sends: every counted item the server already has (`remote`)
    /// keeps its place, and the others take only the room the limit leaves — so a server that holds
    /// more pins than the current limit (Premium ended, the app configuration not loaded yet) never
    /// loses them to a forced reorder, and no new pin is sent that the server would refuse. Items that
    /// are not counted keep their places. When every counted item fits the limit this is the whole
    /// list, as `serverPart` gives it.
    static func syncedServerPart<Item: Hashable>(_ items: [Item], remote: [Item], limit: Int, isCounted: (Item) -> Bool) -> [Item] {
        let remoteSet = Set(remote)
        var known = 0
        for item in items where isCounted(item) && remoteSet.contains(item) {
            known += 1
        }
        var room = max(0, limit - known)
        var result: [Item] = []
        result.reserveCapacity(items.count)
        for item in items {
            if isCounted(item) && !remoteSet.contains(item) {
                if room == 0 {
                    continue
                }
                room -= 1
            }
            result.append(item)
        }
        return result
    }

    /// A synchronization: `previous` is the stored list at the first change not synchronized yet,
    /// `local` the stored list now, `remote` the server's list.
    static func sync<Item: Hashable>(previous: [Item], local: [Item], remote: [Item], tail: [Item], limit: Int, isCounted: (Item) -> Bool) -> SyncResult<Item> {
        let remoteSet = Set(remote)
        let tailSet = Set(tail)
        var stored: [Item]
        if previous == local {
            // Nothing changed here since the last synchronization: the server's list wins (upstream),
            // the tail stays after it.
            stored = remote
            for item in local where isCounted(item) && tailSet.contains(item) && !remoteSet.contains(item) {
                stored.append(item)
            }
        } else {
            // Upstream's merge, except that only what the server could know counts as "unpinned on
            // the server": the tail never reached it, so its absence from `remote` means nothing.
            let previousCounted = previous.filter(isCounted)
            let locallyRemoved = Set(previousCounted).subtracting(local.filter(isCounted))
            let remotelyRemoved = Set(previousCounted.filter { !tailSet.contains($0) }).subtracting(remoteSet)
            stored = local.filter { !remotelyRemoved.contains($0) }
            let storedSet = Set(stored)
            stored.append(contentsOf: remote.filter { !locallyRemoved.contains($0) && !storedSet.contains($0) })
        }
        let toServer = GGPinnedTailModel.syncedServerPart(stored, remote: remote, limit: limit, isCounted: isCounted)
        let toServerSet = Set(toServer)
        var newTail: [Item] = []
        for item in stored where isCounted(item) {
            if !toServerSet.contains(item) {
                // Beyond the server's part.
                newTail.append(item)
            } else if tailSet.contains(item) && !remoteSet.contains(item) {
                // Moved up into the server's part, not confirmed by the server yet: if the request fails,
                // the next server list must not take it for a pin removed elsewhere.
                newTail.append(item)
            }
        }
        return SyncResult(stored: stored, toServer: toServer, tail: newTail)
    }

    /// The stored list goes to the server as is (Saved Messages: pin, unpin, reorder).
    static func push<Item: Hashable>(proposed: [Item], tail: [Item], limit: Int, isCounted: (Item) -> Bool) -> (toServer: [Item], tail: [Item]) {
        let toServer = GGPinnedTailModel.serverPart(proposed, limit: limit, isCounted: isCounted)
        let toServerSet = Set(toServer)
        let tailSet = Set(tail)
        var newTail: [Item] = []
        for item in proposed where isCounted(item) {
            // Beyond the server's part, or moved up into it and not confirmed by a server list yet.
            if !toServerSet.contains(item) || tailSet.contains(item) {
                newTail.append(item)
            }
        }
        return (toServer, newTail)
    }
}
