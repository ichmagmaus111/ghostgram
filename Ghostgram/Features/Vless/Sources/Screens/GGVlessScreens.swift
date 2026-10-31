import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import AlertUI
import PresentationDataUtils
import GGCore
import GGFeaturesShared

// Screens of «VPN по подписке»: servers and subscriptions (status, choice, ping), a new
// subscription, a subscription's settings.

enum GGVlessText {
    static func status(_ status: GGVlessStatus) -> String {
        switch status {
        case .off:
            return GGStrings.Vless.Status.off
        case .notBundled:
            return GGStrings.Vless.Status.notBundled
        case .noServer:
            return GGStrings.Vless.Status.noServer
        case .starting:
            return GGStrings.Vless.Status.starting
        case let .running(serverName):
            return GGStrings.Vless.Status.running(server: serverName)
        case let .unreachable(serverName):
            return GGStrings.Vless.Status.unreachable(server: serverName)
        case let .failed(failure):
            switch failure {
            case .loadFailed:
                return GGStrings.Vless.Status.loadFailed
            case .configInvalid:
                return GGStrings.Vless.Status.configInvalid
            case .startFailed:
                return GGStrings.Vless.Status.startFailed
            }
        }
    }

    static func error(_ error: GGVlessFetchError) -> String {
        return GGVlessText.error(code: GGVlessController.errorCode(error))
    }

    static func error(code: String) -> String {
        if code.hasPrefix("http:") {
            return GGStrings.Vless.Error.http(code: String(code.dropFirst("http:".count)))
        }
        switch code {
        case "invalidURL":
            return GGStrings.Vless.Error.invalidURL
        case "tooLarge":
            return GGStrings.Vless.Error.tooLarge
        case "empty":
            return GGStrings.Vless.Error.empty
        default:
            return GGStrings.Vless.Error.network
        }
    }

    static func bytes(_ value: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func date(_ timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: GGLocalization.shared.languageCode)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    static func interval(_ interval: GGVlessUpdateInterval) -> String {
        switch interval {
        case .provider:
            return GGStrings.Vless.Subscription.Interval.provider
        case .hours6:
            return GGStrings.Vless.Subscription.Interval.hours6
        case .hours12:
            return GGStrings.Vless.Subscription.Interval.hours12
        case .hours24:
            return GGStrings.Vless.Subscription.Interval.hours24
        case .manual:
            return GGStrings.Vless.Subscription.Interval.manual
        }
    }

    /// Usage, expiry, last refresh or its error — one info block under a subscription's header.
    static func subscriptionInfo(_ subscription: GGVlessSubscription) -> String {
        var lines: [String] = [GGStrings.Vless.Subscription.servers(count: subscription.servers.count)]
        if let usage = subscription.usage {
            let used = usage.upload + usage.download
            if usage.total > 0 {
                lines.append(GGStrings.Vless.Servers.usage(used: GGVlessText.bytes(used), total: GGVlessText.bytes(usage.total)))
            } else {
                lines.append(GGStrings.Vless.Servers.usageUnlimited(used: GGVlessText.bytes(used)))
            }
            if usage.expire > 0 {
                lines.append(GGStrings.Vless.Servers.expires(date: GGVlessText.date(Double(usage.expire))))
            }
        }
        if subscription.url == nil {
            lines.append(GGStrings.Vless.Servers.manual)
        } else if let error = subscription.lastError {
            lines.append(GGStrings.Vless.Error.lastRefresh(reason: GGVlessText.error(code: error)))
        } else if subscription.updatedAt > 0 {
            lines.append(GGStrings.Vless.Servers.updated(date: GGVlessText.date(subscription.updatedAt)))
        }
        return lines.joined(separator: "\n")
    }
}

func ggVlessMakeServersController(context: AccountContext) -> ViewController {
    GGVlessController.shared.attach(context: context)
    weak var weakController: ViewController?
    let push: (ViewController) -> Void = { controller in
        (weakController?.navigationController as? NavigationController)?.pushViewController(controller)
    }

    let model = combineLatest(queue: .mainQueue(),
        GGVlessStore.shared.subscriptionsSignal,
        GGVlessController.shared.status,
        GGVlessController.shared.pingResults,
        GGVlessController.shared.traffic(),
        GGSettingsStore.shared.revision,
        GGLocalization.shared.languageCodeSignal
    )
    |> map { subscriptions, status, pings, traffic, _, _ -> GGVlessScreenModel in
        var model = GGVlessScreenModel(title: GGStrings.Vless.Servers.title)
        let selectedId = GGVlessSettings.selectedServer.value

        var statusRows: [GGVlessRow] = [GGVlessRow(id: "status.header", kind: .header(GGStrings.Vless.Status.title))]
        // The same switch as in the menu: this screen is also reached from Telegram's proxy screen.
        let enabled = GGVlessSettings.enabled.value
        let canSwitch = enabled || (GGXrayCore.isBundled && !selectedId.isEmpty)
        statusRows.append(GGVlessRow(id: "status.enabled", kind: .toggle(title: GGStrings.Vless.Menu.enable, value: enabled, enabled: canSwitch)))
        model.toggle["status.enabled"] = { value in
            GGVlessSettings.enabled.set(value)
        }
        var statusText = GGVlessText.status(status)
        if let traffic {
            statusText += "\n" + GGStrings.Vless.Status.traffic(up: GGVlessText.bytes(traffic.uplink), down: GGVlessText.bytes(traffic.downlink))
        }
        if !selectedId.isEmpty && GGVlessStore.shared.server(id: selectedId) == nil, case let .running(serverName) = status {
            statusText += "\n" + GGStrings.Vless.Servers.removed(server: serverName)
        }
        statusRows.append(GGVlessRow(id: "status.text", kind: .info(statusText)))
        model.sections.append(statusRows)

        var actions: [GGVlessRow] = [GGVlessRow(id: "action.add", kind: .action(title: GGStrings.Vless.Servers.add, destructive: false, enabled: true))]
        model.tap["action.add"] = {
            push(ggVlessMakeAddController(context: context))
        }
        if !subscriptions.isEmpty {
            actions.append(GGVlessRow(id: "action.ping", kind: .action(title: GGStrings.Vless.Servers.ping, destructive: false, enabled: true)))
            model.tap["action.ping"] = {
                GGVlessController.shared.pingAll()
            }
            if subscriptions.contains(where: { $0.url != nil }) {
                actions.append(GGVlessRow(id: "action.refresh", kind: .action(title: GGStrings.Vless.Servers.refreshAll, destructive: false, enabled: true)))
                model.tap["action.refresh"] = {
                    for subscription in GGVlessStore.shared.subscriptions where subscription.url != nil {
                        let _ = GGVlessController.shared.refresh(subscriptionId: subscription.id).start()
                    }
                }
            }
        } else {
            actions.append(GGVlessRow(id: "action.empty", kind: .footer(GGStrings.Vless.Servers.empty)))
        }
        model.sections.append(actions)

        for subscription in subscriptions {
            var rows: [GGVlessRow] = [GGVlessRow(id: "sub.\(subscription.id).header", kind: .header(subscription.name.isEmpty ? GGStrings.Vless.Subscription.title : subscription.name))]
            for server in subscription.servers {
                let rowId = "server.\(subscription.id).\(server.id)"
                var label = ""
                if let ping = pings[server.id] {
                    label = ping >= 0 ? GGStrings.Vless.Servers.pingMs(ms: String(ping)) : GGStrings.Vless.Servers.pingFailed
                }
                rows.append(GGVlessRow(id: rowId, kind: .check(title: server.name, label: label, checked: server.id == selectedId)))
                let serverId = server.id
                model.tap[rowId] = {
                    GGVlessSettings.selectedServer.set(serverId)
                }
            }
            let settingsId = "sub.\(subscription.id).settings"
            rows.append(GGVlessRow(id: settingsId, kind: .disclosure(title: GGStrings.Vless.Servers.settings, label: "")))
            let subscriptionId = subscription.id
            model.tap[settingsId] = {
                push(ggVlessMakeSubscriptionController(context: context, subscriptionId: subscriptionId))
            }
            rows.append(GGVlessRow(id: "sub.\(subscription.id).info", kind: .footer(GGVlessText.subscriptionInfo(subscription))))
            model.sections.append(rows)
        }
        return model
    }
    let controller = ggVlessMakeListController(context: context, model: model)
    weakController = controller
    return controller
}

func ggVlessMakeAddController(context: AccountContext) -> ViewController {
    weak var weakController: ViewController?
    struct State: Equatable {
        var link = ""
        var name = ""
        var loading = false
        var error: String?
    }
    let state = ValuePromise(State(), ignoreRepeated: true)
    let stateValue = Atomic(value: State())
    let update: ((inout State) -> Void) -> Void = { f in
        state.set(stateValue.modify { current in
            var current = current
            f(&current)
            return current
        })
    }
    let addDisposable = MetaDisposable()

    let model = combineLatest(queue: .mainQueue(), state.get(), GGLocalization.shared.languageCodeSignal)
    |> map { state, _ -> GGVlessScreenModel in
        var model = GGVlessScreenModel(title: GGStrings.Vless.Add.title)
        model.sections.append([
            GGVlessRow(id: "link.header", kind: .header(GGStrings.Vless.Add.linkHeader)),
            GGVlessRow(id: "link", kind: .multilineInput(text: state.link, placeholder: GGStrings.Vless.Add.linkPlaceholder)),
            GGVlessRow(id: "link.footer", kind: .footer(GGStrings.Vless.Add.linkFooter))
        ])
        model.sections.append([
            GGVlessRow(id: "name.header", kind: .header(GGStrings.Vless.Add.nameHeader)),
            GGVlessRow(id: "name", kind: .input(text: state.name, placeholder: GGStrings.Vless.Add.namePlaceholder))
        ])
        var actionRows: [GGVlessRow] = [GGVlessRow(id: "add", kind: .action(title: state.loading ? GGStrings.Vless.Add.adding : GGStrings.Vless.Add.add, destructive: false, enabled: !state.loading && !state.link.isEmpty))]
        if let error = state.error {
            actionRows.append(GGVlessRow(id: "error", kind: .footer(GGStrings.Vless.Add.failed(reason: error))))
        }
        model.sections.append(actionRows)
        model.text["link"] = { value in
            update { $0.link = value }
        }
        model.text["name"] = { value in
            update { $0.name = value }
        }
        model.tap["add"] = {
            let current = stateValue.with { $0 }
            if current.loading || current.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            update {
                $0.loading = true
                $0.error = nil
            }
            addDisposable.set((GGVlessController.shared.addSubscription(input: current.link, name: current.name)
            |> deliverOnMainQueue).start(next: { subscription in
                if GGVlessSettings.selectedServer.value.isEmpty, let first = subscription.servers.first {
                    GGVlessSettings.selectedServer.set(first.id)
                }
                weakController?.dismiss()
            }, error: { error in
                update {
                    $0.loading = false
                    $0.error = GGVlessText.error(error)
                }
            }))
        }
        return model
    }
    let controller = ggVlessMakeListController(context: context, model: model)
    controller.navigationPresentation = .modal
    weakController = controller
    return controller
}

func ggVlessMakeSubscriptionController(context: AccountContext, subscriptionId: String) -> ViewController {
    weak var weakController: ViewController?
    // Text edits stay in the screen until «Готово»: no write per keystroke.
    let draftName = Atomic<String?>(value: nil)
    let draftURL = Atomic<String?>(value: nil)
    let refreshDisposable = MetaDisposable()

    let model = combineLatest(queue: .mainQueue(), GGVlessStore.shared.subscriptionsSignal, GGLocalization.shared.languageCodeSignal)
    |> map { subscriptions, _ -> GGVlessScreenModel in
        var model = GGVlessScreenModel(title: GGStrings.Vless.Subscription.title)
        guard let subscription = subscriptions.first(where: { $0.id == subscriptionId }) else {
            return model
        }
        model.sections.append([
            GGVlessRow(id: "name.header", kind: .header(GGStrings.Vless.Subscription.nameHeader)),
            GGVlessRow(id: "name", kind: .input(text: draftName.with { $0 } ?? subscription.name, placeholder: GGStrings.Vless.Add.namePlaceholder))
        ])
        model.text["name"] = { value in
            let _ = draftName.swap(value)
        }
        if let url = subscription.url {
            model.sections.append([
                GGVlessRow(id: "url.header", kind: .header(GGStrings.Vless.Subscription.urlHeader)),
                GGVlessRow(id: "url", kind: .multilineInput(text: draftURL.with { $0 } ?? url, placeholder: GGStrings.Vless.Add.linkPlaceholder))
            ])
            model.text["url"] = { value in
                let _ = draftURL.swap(value)
            }
            var intervalRows: [GGVlessRow] = [GGVlessRow(id: "interval.header", kind: .header(GGStrings.Vless.Subscription.intervalHeader))]
            for interval in GGVlessUpdateInterval.allCases {
                let rowId = "interval.\(interval.rawValue)"
                intervalRows.append(GGVlessRow(id: rowId, kind: .check(title: GGVlessText.interval(interval), label: "", checked: subscription.updateInterval == interval)))
                model.tap[rowId] = {
                    GGVlessController.shared.updateSubscription(id: subscriptionId, { $0.updateInterval = interval })
                }
            }
            intervalRows.append(GGVlessRow(id: "interval.footer", kind: .footer(GGStrings.Vless.Subscription.intervalFooter)))
            model.sections.append(intervalRows)
            model.sections.append([GGVlessRow(id: "refresh", kind: .action(title: GGStrings.Vless.Subscription.refresh, destructive: false, enabled: true))])
            model.tap["refresh"] = {
                refreshDisposable.set(GGVlessController.shared.refresh(subscriptionId: subscriptionId).start())
            }
        }
        model.sections.append([
            GGVlessRow(id: "delete", kind: .action(title: GGStrings.Vless.Subscription.delete, destructive: true, enabled: true)),
            GGVlessRow(id: "info", kind: .footer(GGVlessText.subscriptionInfo(subscription)))
        ])
        let name = subscription.name
        model.tap["delete"] = {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let alert = textAlertController(context: context, title: nil, text: GGStrings.Vless.Subscription.deleteConfirm(name: name), actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: GGStrings.Vless.Subscription.delete, action: {
                    GGVlessController.shared.removeSubscription(id: subscriptionId)
                    let _ = weakController?.navigationController?.popViewController(animated: true)
                })
            ])
            weakController?.present(alert, in: .window(.root))
        }
        model.rightButton = (GGStrings.Vless.Subscription.save, {
            let name = draftName.swap(nil)
            let url = draftURL.swap(nil)
            var urlChanged = false
            GGVlessController.shared.updateSubscription(id: subscriptionId, { subscription in
                if let name {
                    subscription.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let url, subscription.url != nil {
                    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && trimmed != subscription.url {
                        subscription.url = trimmed
                        subscription.lastError = nil
                        urlChanged = true
                    }
                }
            })
            if urlChanged {
                refreshDisposable.set(GGVlessController.shared.refresh(subscriptionId: subscriptionId).start())
            }
            let _ = weakController?.navigationController?.popViewController(animated: true)
        })
        return model
    }
    let controller = ggVlessMakeListController(context: context, model: model)
    weakController = controller
    return controller
}
