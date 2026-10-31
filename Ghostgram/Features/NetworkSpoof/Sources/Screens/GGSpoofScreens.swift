import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import AlertUI
import PresentationDataUtils
import LocalizedPeerData
import GGCore

// Screens of «Подмены»: phone number, profile substitution. A typed number stays in the screen until
// «Готово»: nothing is written per keystroke.

func ggSpoofMakePhoneController(context: AccountContext) -> ViewController {
    let account = context.account.id.gg
    weak var weakController: ViewController?
    let draft = ValuePromise<String?>(nil, ignoreRepeated: true)
    let draftValue = Atomic<String?>(value: nil)

    let model = combineLatest(queue: .mainQueue(), GGNetworkSpoofSettings.fakePhoneEnabled.signal(for: account), GGNetworkSpoofSettings.fakePhone.signal(for: account), draft.get(), GGLocalization.shared.languageCodeSignal)
    |> map { enabled, number, draftText, _ -> GGSpoofScreenModel in
        var model = GGSpoofScreenModel(title: GGStrings.NetworkSpoof.Phone.title)
        model.sections.append([
            GGSpoofRow(id: "enabled", kind: .toggle(title: GGStrings.NetworkSpoof.Phone.enable, value: enabled, enabled: !number.isEmpty || enabled)),
            GGSpoofRow(id: "number.header", kind: .header(GGStrings.NetworkSpoof.Phone.numberHeader)),
            GGSpoofRow(id: "number", kind: .numberInput(title: "+", text: draftText ?? number, placeholder: "79991234567")),
            GGSpoofRow(id: "footer", kind: .footer(GGStrings.NetworkSpoof.Phone.footer))
        ])
        model.toggle["enabled"] = { value in
            GGNetworkSpoofSettings.fakePhoneEnabled.set(value, for: account)
        }
        model.text["number"] = { value in
            let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(15))
            let _ = draftValue.swap(digits)
            draft.set(digits)
        }
        if draftText != nil {
            model.rightButton = (GGStrings.NetworkSpoof.done, {
                if let digits = draftValue.swap(nil) {
                    GGNetworkSpoofSettings.fakePhone.set(digits, for: account)
                    if digits.isEmpty {
                        GGNetworkSpoofSettings.fakePhoneEnabled.set(false, for: account)
                    }
                }
                draft.set(nil)
                weakController?.view.endEditing(true)
            })
        }
        return model
    }
    let controller = ggSpoofMakeListController(context: context, model: model)
    weakController = controller
    return controller
}

func ggSpoofMakeProfilesController(context: AccountContext) -> ViewController {
    let account = context.account.id.gg
    weak var weakController: ViewController?
    let push: (ViewController) -> Void = { controller in
        (weakController?.navigationController as? NavigationController)?.pushViewController(controller)
    }

    let redirects = GGNetworkSpoofSettings.profileRedirects.signal(for: account)
    let peers = redirects
    |> mapToSignal { redirects -> Signal<[EnginePeer.Id: EnginePeer], NoError> in
        var ids: [EnginePeer.Id] = []
        for (source, target) in redirects {
            if let key = GGPeerKey(string: source) {
                ids.append(PeerId(ggKey: key))
            }
            ids.append(PeerId(ggKey: target))
        }
        return context.engine.data.get(EngineDataMap(ids.map(TelegramEngine.EngineData.Item.Peer.Peer.init)))
        |> map { result -> [EnginePeer.Id: EnginePeer] in
            var peers: [EnginePeer.Id: EnginePeer] = [:]
            for (id, peer) in result {
                if let peer {
                    peers[id] = peer
                }
            }
            return peers
        }
    }

    let model = combineLatest(queue: .mainQueue(), GGNetworkSpoofSettings.profileRedirectEnabled.signal(for: account), redirects, peers, GGLocalization.shared.languageCodeSignal)
    |> map { enabled, redirects, peers, _ -> GGSpoofScreenModel in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let name: (EnginePeer.Id) -> String = { id in
            return peers[id]?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder) ?? GGStrings.NetworkSpoof.Profiles.unknownPeer
        }
        var model = GGSpoofScreenModel(title: GGStrings.NetworkSpoof.Profiles.title)
        model.sections.append([
            GGSpoofRow(id: "enabled", kind: .toggle(title: GGStrings.NetworkSpoof.Profiles.enable, value: enabled, enabled: true)),
            GGSpoofRow(id: "enabled.footer", kind: .footer(GGStrings.NetworkSpoof.Profiles.footer))
        ])
        model.toggle["enabled"] = { value in
            GGNetworkSpoofSettings.profileRedirectEnabled.set(value, for: account)
        }

        var rows: [GGSpoofRow] = [GGSpoofRow(id: "pairs.header", kind: .header(GGStrings.NetworkSpoof.Profiles.pairsHeader))]
        for source in redirects.keys.sorted() {
            guard let sourceKey = GGPeerKey(string: source), let target = redirects[source] else {
                continue
            }
            let rowId = "pair.\(source)"
            rows.append(GGSpoofRow(id: rowId, kind: .disclosure(title: GGStrings.NetworkSpoof.Profiles.pair(source: name(PeerId(ggKey: sourceKey)), target: name(PeerId(ggKey: target))), label: "")))
            model.tap[rowId] = {
                let alert = textAlertController(context: context, title: nil, text: GGStrings.NetworkSpoof.Profiles.removeConfirm, actions: [
                    TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                    TextAlertAction(type: .destructiveAction, title: GGStrings.NetworkSpoof.Profiles.remove, action: {
                        var current = GGNetworkSpoofSettings.profileRedirects.value(for: account)
                        current.removeValue(forKey: source)
                        GGNetworkSpoofSettings.profileRedirects.set(current, for: account)
                    })
                ])
                weakController?.present(alert, in: .window(.root))
            }
        }
        rows.append(GGSpoofRow(id: "pairs.add", kind: .action(title: GGStrings.NetworkSpoof.Profiles.add, destructive: false, enabled: true)))
        model.tap["pairs.add"] = {
            let sourcePicker = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.excludeSavedMessages, .excludeSecretChats, .doNotSearchMessages], hasContactSelector: false, title: GGStrings.NetworkSpoof.Profiles.pickSource))
            sourcePicker.peerSelected = { [weak sourcePicker] sourcePeer, _ in
                let targetPicker = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.excludeSavedMessages, .excludeSecretChats, .doNotSearchMessages], hasContactSelector: false, title: GGStrings.NetworkSpoof.Profiles.pickTarget))
                targetPicker.peerSelected = { [weak targetPicker] targetPeer, _ in
                    if targetPeer.id != sourcePeer.id {
                        var current = GGNetworkSpoofSettings.profileRedirects.value(for: account)
                        current[sourcePeer.id.ggKey.stringValue] = targetPeer.id.ggKey
                        GGNetworkSpoofSettings.profileRedirects.set(current, for: account)
                        if !GGNetworkSpoofSettings.profileRedirectEnabled.value(for: account) {
                            GGNetworkSpoofSettings.profileRedirectEnabled.set(true, for: account)
                        }
                    }
                    targetPicker?.dismiss()
                }
                sourcePicker?.dismiss()
                push(targetPicker)
            }
            push(sourcePicker)
        }
        model.sections.append(rows)
        return model
    }
    let controller = ggSpoofMakeListController(context: context, model: model)
    weakController = controller
    return controller
}
