import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import LocalizedPeerData
import ItemListUI
import GGCore
import GGSettingsUI

// More › Fake gifts: the switch, the account's list, "Delete all". One editor for a gift
// (sender — a chat, anonymous or none; caption; date; shown / pinned; delete), reached from the list
// and from the gift's own «…».

enum GGFakeGiftsMenu {
    static func register() {
        GGMenuRegistry.register(GGMenuRow(
            id: "fakeGifts.isEnabled",
            section: .main(of: .moreFakeGifts),
            order: 100,
            title: { GGStrings.FakeGifts.Menu.enable },
            subtitle: { GGStrings.FakeGifts.Menu.enableInfo },
            kind: .toggle(.global(GGFakeGiftsSettings.isEnabled)),
            searchKeywords: { [GGStrings.FakeGifts.Menu.keywords] }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "fakeGifts.list",
            section: .main(of: .moreFakeGifts),
            order: 200,
            title: { GGStrings.FakeGifts.Menu.list },
            subtitle: { GGStrings.FakeGifts.Menu.listInfo },
            icon: .bundle("Chat/Context Menu/Gift"),
            kind: .action({ context in
                context.push(ggMakeFakeGiftsListScreen(context: context.context))
            }),
            isVisible: { _ in GGFakeGiftsSettings.isEnabled.value },
            searchKeywords: { [GGStrings.FakeGifts.Menu.keywords] },
            label: { context in
                let count = GGFakeGiftsStore.shared.records(accountPeerId: context.context.account.peerId).count
                return count == 0 ? nil : "\(count)"
            }
        ))
    }
}

func ggFakeGiftTitle(_ gift: StarGift, number: Int32?) -> String {
    switch gift {
    case let .unique(uniqueGift):
        return "\(uniqueGift.title) #\(uniqueGift.number)"
    case let .generic(generic):
        let title = generic.title ?? GGStrings.FakeGifts.List.giftTitle
        if let number = number {
            return "\(title) #\(number)"
        }
        return title
    }
}

private let ggFakeGiftDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

/// Main thread only (the formatter is shared by the screens).
func ggFakeGiftDateString(_ date: Int32) -> String {
    assert(Thread.isMainThread)
    ggFakeGiftDateFormatter.locale = Locale(identifier: GGLocalization.shared.languageCode)
    return ggFakeGiftDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(date)))
}

func ggMakeFakeGiftsListScreen(context: AccountContext) -> ViewController {
    let accountPeerId = context.account.peerId
    weak var controllerRef: ItemListController?

    let model = combineLatest(queue: .mainQueue(), GGFakeGiftsStore.shared.recordsSignal(accountPeerId: accountPeerId), GGLocalization.shared.languageCodeSignal)
    |> map { records, _ -> GGPEScreenModel in
        var model = GGPEScreenModel(title: GGStrings.FakeGifts.List.title)
        var rows: [GGPERow] = [GGPERow(id: "header", kind: .header(GGStrings.FakeGifts.List.header))]
        if records.isEmpty {
            rows.append(GGPERow(id: "empty", kind: .info(GGStrings.FakeGifts.List.empty)))
        }
        for record in records {
            var label = ggFakeGiftDateString(record.date)
            if record.pinnedToTop {
                label = GGStrings.FakeGifts.List.pinned + " · " + label
            } else if !record.savedToProfile {
                label = GGStrings.FakeGifts.List.hidden + " · " + label
            }
            let id = "gift\(record.localId)"
            rows.append(GGPERow(id: id, kind: .disclosure(title: ggFakeGiftTitle(record.gift, number: record.number), label: label, icon: nil, enabled: true)))
            let localId = record.localId
            model.tap[id] = {
                controllerRef?.push(ggMakeFakeGiftEditor(context: context, localId: localId))
            }
        }
        rows.append(GGPERow(id: "footer", kind: .footer(GGStrings.FakeGifts.List.footer)))
        model.sections.append(rows)
        if !records.isEmpty {
            model.sections.append([GGPERow(id: "deleteAll", kind: .action(title: GGStrings.FakeGifts.List.deleteAll, destructive: true, enabled: true))])
            model.tap["deleteAll"] = {
                ggPEConfirmDestructive(context: context, from: controllerRef, title: GGStrings.FakeGifts.List.deleteAllTitle, text: GGStrings.FakeGifts.List.deleteAllText, confirm: GGStrings.FakeGifts.List.deleteAllConfirm, action: {
                    GGFakeGiftsStore.shared.removeAll(accountPeerId: accountPeerId)
                })
            }
        }
        return model
    }
    let controller = ggPEMakeListController(context: context, model: model)
    controllerRef = controller
    return controller
}

/// The editor works on a draft; "Done" writes it once.
func ggMakeFakeGiftEditor(context: AccountContext, localId: Int64) -> ViewController {
    let accountPeerId = context.account.peerId
    weak var controllerRef: ItemListController?

    guard let initial = GGFakeGiftsStore.shared.records(accountPeerId: accountPeerId).first(where: { $0.localId == localId }) else {
        return ggMakeFakeGiftsListScreen(context: context)
    }
    let draft = ValuePromise<GGFakeGiftRecord>(initial, ignoreRepeated: true)
    let draftValue = Atomic<GGFakeGiftRecord>(value: initial)
    let updateDraft: ((inout GGFakeGiftRecord) -> Void) -> Void = { transform in
        var value = draftValue.with { $0 }
        transform(&value)
        let _ = draftValue.swap(value)
        draft.set(value)
    }

    let sender: Signal<EnginePeer?, NoError> = draft.get()
    |> map { record -> EnginePeer.Id? in
        return record.fromPeer.map(PeerId.init(ggKey:))
    }
    |> distinctUntilChanged
    |> mapToSignal { peerId -> Signal<EnginePeer?, NoError> in
        guard let peerId = peerId else {
            return .single(nil)
        }
        return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
    }

    let model = combineLatest(queue: .mainQueue(), draft.get(), sender, GGLocalization.shared.languageCodeSignal)
    |> map { record, senderPeer, _ -> GGPEScreenModel in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        var model = GGPEScreenModel(title: ggFakeGiftTitle(record.gift, number: record.number))

        let senderLabel: String
        if record.nameHidden {
            senderLabel = GGStrings.FakeGifts.Editor.anonymous
        } else if let senderPeer = senderPeer {
            senderLabel = senderPeer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        } else {
            senderLabel = GGStrings.FakeGifts.Editor.noSender
        }
        model.sections.append([
            GGPERow(id: "senderHeader", kind: .header(GGStrings.FakeGifts.Editor.senderHeader)),
            GGPERow(id: "sender", kind: .peer(title: GGStrings.FakeGifts.Editor.sender, label: senderLabel, peer: record.nameHidden ? nil : senderPeer))
        ])
        model.tap["sender"] = {
            ggPEPresentActionSheet(context: context, from: controllerRef, buttons: [
                (title: GGStrings.FakeGifts.Editor.chooseSender, isDestructive: false, action: {
                    let picker = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.excludeSecretChats, .doNotSearchMessages], hasContactSelector: true, title: GGStrings.FakeGifts.Editor.chooseSender))
                    picker.peerSelected = { [weak picker] peer, _ in
                        updateDraft { record in
                            record.fromPeer = peer.id.ggKey
                            record.nameHidden = false
                        }
                        picker?.dismiss()
                    }
                    controllerRef?.push(picker)
                }),
                (title: GGStrings.FakeGifts.Editor.anonymous, isDestructive: false, action: {
                    updateDraft { record in
                        record.nameHidden = true
                    }
                }),
                (title: GGStrings.FakeGifts.Editor.noSender, isDestructive: false, action: {
                    updateDraft { record in
                        record.fromPeer = nil
                        record.nameHidden = false
                    }
                })
            ])
        }

        model.sections.append([
            GGPERow(id: "captionHeader", kind: .header(GGStrings.FakeGifts.Editor.captionHeader)),
            GGPERow(id: "caption", kind: .multilineInput(text: record.text ?? "", placeholder: GGStrings.FakeGifts.Editor.captionPlaceholder))
        ])
        model.text["caption"] = { text in
            updateDraft { record in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if record.text != text {
                    // A typed caption has no entities of its own.
                    record.entities = nil
                }
                record.text = trimmed.isEmpty ? nil : text
            }
        }

        model.sections.append([
            GGPERow(id: "dateHeader", kind: .header(GGStrings.FakeGifts.Editor.dateHeader)),
            GGPERow(id: "date", kind: .disclosure(title: GGStrings.FakeGifts.Editor.date, label: ggFakeGiftDateString(record.date), icon: nil, enabled: true))
        ])
        model.tap["date"] = {
            let now = Int32(Date().timeIntervalSince1970)
            let day: Int32 = 24 * 60 * 60
            let presets: [(String, Int32)] = [
                (GGStrings.FakeGifts.Editor.dateNow, now),
                (GGStrings.FakeGifts.Editor.dateYesterday, now - day),
                (GGStrings.FakeGifts.Editor.dateWeek, now - 7 * day),
                (GGStrings.FakeGifts.Editor.dateMonth, now - 30 * day),
                (GGStrings.FakeGifts.Editor.dateYear, now - 365 * day)
            ]
            ggPEPresentActionSheet(context: context, from: controllerRef, buttons: presets.map { preset in
                return (title: preset.0, isDestructive: false, action: {
                    updateDraft { record in
                        record.date = preset.1
                    }
                })
            })
        }

        model.sections.append([
            GGPERow(id: "shown", kind: .toggle(title: GGStrings.FakeGifts.Editor.shown, value: record.savedToProfile, enabled: true)),
            GGPERow(id: "pinned", kind: .toggle(title: GGStrings.FakeGifts.Editor.pinned, value: record.pinnedToTop, enabled: true)),
            GGPERow(id: "flagsFooter", kind: .footer(GGStrings.FakeGifts.Editor.flagsFooter))
        ])
        model.toggle["shown"] = { value in
            updateDraft { record in
                record.savedToProfile = value
                if !value {
                    record.pinnedToTop = false
                }
            }
        }
        model.toggle["pinned"] = { value in
            updateDraft { record in
                record.pinnedToTop = value
                if value {
                    record.savedToProfile = true
                }
            }
        }

        model.sections.append([GGPERow(id: "delete", kind: .action(title: GGStrings.FakeGifts.Editor.delete, destructive: true, enabled: true))])
        model.tap["delete"] = {
            ggPEConfirmDestructive(context: context, from: controllerRef, title: GGStrings.FakeGifts.Editor.deleteTitle, text: GGStrings.FakeGifts.Editor.deleteText, confirm: GGStrings.FakeGifts.Editor.delete, action: {
                GGFakeGiftsStore.shared.remove(accountPeerId: accountPeerId, localId: localId)
                controllerRef?.dismiss()
            })
        }

        model.rightButton = (title: presentationData.strings.Common_Done, enabled: true, action: {
            let value = draftValue.with { $0 }
            GGFakeGiftsStore.shared.update(accountPeerId: accountPeerId, localId: localId, { record in
                record = value
            })
            controllerRef?.dismiss()
        })
        return model
    }
    let controller = ggPEMakeListController(context: context, model: model)
    controllerRef = controller
    return controller
}
