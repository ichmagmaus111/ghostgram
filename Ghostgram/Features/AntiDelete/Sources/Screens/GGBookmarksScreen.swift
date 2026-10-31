import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import AccountContext
import LocalizedPeerData
import GGCore
import GGFeaturesShared

/// «Все закладки» (or the bookmarks of one chat): newest first, a tap opens the message, a swipe
/// removes the bookmark. Bookmarks belong to the account (its own Postbox).
func ggMakeBookmarksController(context: AccountContext, peerId: PeerId?) -> ViewController {
    let postbox = context.account.postbox
    weak var weakController: ViewController?

    let _ = GGAntiDeleteOperations.reconcileBookmarks(postbox: postbox, accountId: context.account.id).start()

    let data = GGAntiDeleteIndexStore.bookmarksSignal(postbox: postbox)
    |> mapToSignal { list -> Signal<([GGBookmarkEntry], [EnginePeer.Id: EnginePeer]), NoError> in
        var entries = list.entries
        if let peerId {
            entries = entries.filter { $0.message.peer == peerId.ggKey }
        }
        let ids = Array(Set(entries.map { PeerId(ggKey: $0.message.peer) }))
        return context.engine.data.get(EngineDataMap(ids.map(TelegramEngine.EngineData.Item.Peer.Peer.init)))
        |> map { result -> ([GGBookmarkEntry], [EnginePeer.Id: EnginePeer]) in
            var peers: [EnginePeer.Id: EnginePeer] = [:]
            for (id, peer) in result {
                if let peer {
                    peers[id] = peer
                }
            }
            return (entries, peers)
        }
    }

    let model = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, data)
    |> map { presentationData, data -> GGADScreenModel in
        let (entries, peers) = data
        var title = GGStrings.Bookmarks.All.title
        if let peerId, let peer = peers[peerId] {
            title = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        }
        var model = GGADScreenModel(title: .text(title), sections: [])
        if entries.isEmpty {
            model.sections.append(GGADSection(id: "empty", rows: [GGADRow(id: "empty", kind: .footer(GGStrings.Bookmarks.All.empty))]))
            return model
        }
        var rows: [GGADRow] = []
        for entry in entries {
            let messageId = MessageId(ggKey: entry.message)
            guard let peer = peers[messageId.peerId] else {
                continue
            }
            let rowId = "bookmark.\(entry.message.stringValue)"
            let date = stringForMediumDate(timestamp: entry.messageDate, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat)
            rows.append(GGADRow(id: rowId, kind: .peer(peer: peer, text: entry.title, label: date, removeTitle: GGStrings.Bookmarks.All.remove)))
            let threadId = entry.threadId
            model.tap[rowId] = {
                if let navigationController = weakController?.navigationController as? NavigationController {
                    ggOpenMessage(context: context, navigationController: navigationController, messageId: messageId, threadId: threadId)
                }
            }
            model.remove[rowId] = {
                GGAntiDeleteMessageMenu.setBookmark(context: context, messageId: messageId, title: nil)
            }
        }
        rows.append(GGADRow(id: "footer", kind: .footer(GGStrings.Bookmarks.All.footer)))
        model.sections.append(GGADSection(id: "bookmarks", rows: rows))
        return model
    }

    let controller = ggMakeADListController(context: context, model: model)
    weakController = controller
    return controller
}
