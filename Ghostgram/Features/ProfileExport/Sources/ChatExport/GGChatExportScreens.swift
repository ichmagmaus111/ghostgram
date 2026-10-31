import Foundation
import UIKit
import Display
import AppBundle
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import LocalizedPeerData
import ContextUI
import ItemListUI
import GGCore
import GGHooks
import GGSettingsUI

// Screens of the export: what to include (the choice is remembered), the progress with "Cancel",
// the result ("Save to Files", "Share ZIP", "Done" — the temporary tree is deleted
// after it was saved), and the list of exports left unfinished. Entry points: «…» of a profile and
// Messages › Chat export.

enum GGChatExportMenu {
    static let infoSection = GGMenuSectionID("messages.export.info")

    static func register() {
        GGMenuRegistry.register(GGMenuRow(
            id: "chatExport.chat",
            section: .main(of: .messagesExport),
            order: 100,
            title: { GGStrings.ChatExport.Menu.chat },
            subtitle: { GGStrings.ChatExport.Menu.chatInfo },
            icon: .bundle("Chat/Context Menu/Message"),
            kind: .action({ context in
                ggChatExportPickChat(context: context.context, push: { controller in
                    context.push(controller)
                })
            }),
            searchKeywords: { [GGStrings.ChatExport.Menu.keywords] }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "chatExport.account",
            section: .main(of: .messagesExport),
            order: 200,
            title: { GGStrings.ChatExport.Menu.account },
            subtitle: { GGStrings.ChatExport.Menu.accountInfo },
            icon: .bundle("Chat/Context Menu/Archive"),
            kind: .action({ context in
                context.push(ggMakeChatExportSetupScreen(context: context.context, mode: .account, title: GGStrings.ChatExport.Setup.accountTitle))
            }),
            searchKeywords: { [GGStrings.ChatExport.Menu.keywords] }
        ))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(
            id: GGChatExportMenu.infoSection,
            screen: .tab(.messagesExport),
            order: 300,
            footer: { _ in GGStrings.ChatExport.Menu.footer }
        ))
        GGMenuRegistry.register(GGMenuRow(
            id: "chatExport.jobs",
            section: GGChatExportMenu.infoSection,
            order: 100,
            title: { GGStrings.ChatExport.Menu.jobs },
            subtitle: { GGStrings.ChatExport.Menu.jobsInfo },
            icon: .bundle("Chat/Context Menu/Download"),
            kind: .action({ context in
                if GGChatExportManager.shared.current != nil {
                    // The screen of the current export offers «Save to Files» and «Share ZIP» once it
                    // is done: the same check as before an export starts.
                    GGChatExportAuth.authenticate(reason: GGStrings.ChatExport.Jobs.authReason, completion: { success in
                        if success {
                            context.push(ggMakeChatExportProgressScreen(context: context.context))
                        }
                    })
                } else {
                    context.push(ggMakeChatExportJobsScreen(context: context.context))
                }
            }),
            searchKeywords: { [GGStrings.ChatExport.Menu.keywords] }
        ))

        GGPeerInfoHooks.menuItems.register({ peerInfo in
            if peerInfo.isSettings {
                return []
            }
            let context = peerInfo.context
            let peer = peerInfo.chatPeer ?? peerInfo.peer
            weak let controller = peerInfo.controller
            return [.action(ContextMenuActionItem(text: GGStrings.ChatExport.Menu.profileItem, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Download"), color: theme.contextMenu.primaryColor)
            }, action: { contextController, _ in
                contextController?.dismiss(completion: nil)
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let title = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                controller?.push(ggMakeChatExportSetupScreen(context: context, mode: .chat(peer.id.ggKey), title: title))
            }))]
        })
    }
}

private func ggChatExportPickChat(context: AccountContext, push: @escaping (ViewController) -> Void) {
    let picker = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.doNotSearchMessages], hasContactSelector: false, title: GGStrings.ChatExport.Menu.chat))
    picker.peerSelected = { [weak picker] peer, _ in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let title = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        let setup = ggMakeChatExportSetupScreen(context: context, mode: .chat(peer.id.ggKey), title: title)
        if let navigationController = picker?.navigationController as? NavigationController {
            navigationController.replaceTopController(setup, animated: true)
        } else {
            push(setup)
        }
    }
    push(picker)
}

private func ggChatExportSizeLabel(_ value: String) -> String {
    if value == "0" {
        return GGStrings.ChatExport.Setup.sizeUnlimited
    }
    return GGStrings.ChatExport.Setup.sizeMegabytes(size: value)
}

private func ggChatExportErrorText(_ code: String?) -> String {
    switch code {
    case "noSpace":
        return GGStrings.ChatExport.Progress.errorNoSpace
    case "chatNotFound":
        return GGStrings.ChatExport.Progress.errorChatNotFound
    default:
        return GGStrings.ChatExport.Progress.errorWrite
    }
}

// MARK: - Setup

func ggMakeChatExportSetupScreen(context: AccountContext, mode: GGChatExportMode, title: String) -> ViewController {
    weak var controllerRef: ItemListController?

    let model = combineLatest(queue: .mainQueue(), GGSettingsStore.shared.revision, GGLocalization.shared.languageCodeSignal)
    |> map { _, _ -> GGPEScreenModel in
        var model = GGPEScreenModel(title: GGStrings.ChatExport.Setup.title)
        let options = GGChatExportSettings.currentOptions()

        model.sections.append([
            GGPERow(id: "target", kind: .header(GGStrings.ChatExport.Setup.target)),
            GGPERow(id: "targetName", kind: .info(title))
        ])

        let toggles: [(String, String, GGSetting<Bool>)] = [
            ("photos", GGStrings.ChatExport.Setup.photos, GGChatExportSettings.photos),
            ("videos", GGStrings.ChatExport.Setup.videos, GGChatExportSettings.videos),
            ("voice", GGStrings.ChatExport.Setup.voiceMessages, GGChatExportSettings.voiceMessages),
            ("round", GGStrings.ChatExport.Setup.videoMessages, GGChatExportSettings.videoMessages),
            ("stickers", GGStrings.ChatExport.Setup.stickers, GGChatExportSettings.stickers),
            ("gifs", GGStrings.ChatExport.Setup.gifs, GGChatExportSettings.gifs),
            ("files", GGStrings.ChatExport.Setup.files, GGChatExportSettings.files)
        ]
        var mediaRows: [GGPERow] = [GGPERow(id: "mediaHeader", kind: .header(GGStrings.ChatExport.Setup.mediaHeader))]
        for (id, label, setting) in toggles {
            mediaRows.append(GGPERow(id: id, kind: .check(title: label, subtitle: nil, checked: setting.value)))
            model.tap[id] = {
                setting.set(!setting.value)
            }
        }
        if options.includesMedia {
            mediaRows.append(GGPERow(id: "size", kind: .disclosure(title: GGStrings.ChatExport.Setup.sizeLimit, label: ggChatExportSizeLabel(GGChatExportSettings.sizeLimit.value), icon: nil, enabled: true)))
            model.tap["size"] = {
                ggPEPresentActionSheet(context: context, from: controllerRef, buttons: GGChatExportSettings.sizeLimitValues.map { value in
                    return (title: ggChatExportSizeLabel(value), isDestructive: false, action: {
                        GGChatExportSettings.sizeLimit.set(value)
                    })
                })
            }
        }
        mediaRows.append(GGPERow(id: "mediaFooter", kind: .footer(GGStrings.ChatExport.Setup.mediaFooter)))
        model.sections.append(mediaRows)

        let format = GGChatExportSettings.format.value
        model.sections.append([
            GGPERow(id: "formatHeader", kind: .header(GGStrings.ChatExport.Setup.formatHeader)),
            GGPERow(id: "formatHTML", kind: .check(title: GGStrings.ChatExport.Setup.formatHtml, subtitle: nil, checked: format == "html")),
            GGPERow(id: "formatJSON", kind: .check(title: GGStrings.ChatExport.Setup.formatJson, subtitle: nil, checked: format == "json")),
            GGPERow(id: "formatBoth", kind: .check(title: GGStrings.ChatExport.Setup.formatBoth, subtitle: nil, checked: format != "html" && format != "json"))
        ])
        model.tap["formatHTML"] = {
            GGChatExportSettings.format.set("html")
        }
        model.tap["formatJSON"] = {
            GGChatExportSettings.format.set("json")
        }
        model.tap["formatBoth"] = {
            GGChatExportSettings.format.set("both")
        }

        var startFooter = GGStrings.ChatExport.Setup.startFooter
        if case .account = mode {
            startFooter = GGStrings.ChatExport.Setup.accountFooter
        }
        if let free = GGChatExportJob.freeSpace() {
            startFooter += "\n" + GGStrings.ChatExport.Setup.freeSpace(size: GGChatExportFormat.fileSize(free))
        }
        model.sections.append([
            GGPERow(id: "start", kind: .action(title: GGStrings.ChatExport.Setup.start, destructive: false, enabled: true)),
            GGPERow(id: "startFooter", kind: .footer(startFooter))
        ])
        model.tap["start"] = {
            guard let controller = controllerRef else {
                return
            }
            if GGChatExportManager.shared.isBusy {
                ggPEPresentToast(context: context, from: controller, text: GGStrings.ChatExport.Setup.alreadyRunning)
                return
            }
            if let free = GGChatExportJob.freeSpace(), free < GGChatExportJob.minimumFreeSpace {
                ggPEPresentToast(context: context, from: controller, text: GGStrings.ChatExport.Progress.errorNoSpace)
                return
            }
            GGChatExportAuth.authenticate(reason: GGStrings.ChatExport.Setup.authReason, completion: { success in
                guard success, let controller = controllerRef else {
                    return
                }
                if GGChatExportManager.shared.start(context: context, mode: mode, title: title) {
                    if let navigationController = controller.navigationController as? NavigationController {
                        navigationController.replaceTopController(ggMakeChatExportProgressScreen(context: context), animated: true)
                    }
                } else {
                    ggPEPresentToast(context: context, from: controller, text: GGStrings.ChatExport.Setup.alreadyRunning)
                }
            })
        }
        return model
    }
    let controller = ggPEMakeListController(context: context, model: model)
    controllerRef = controller
    return controller
}

// MARK: - Progress and result

private final class GGChatExportPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let completed: () -> Void

    init(completed: @escaping () -> Void) {
        self.completed = completed
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.completed()
    }
}

/// Keeps the document picker's delegate alive as long as the screen.
private final class GGChatExportDelegateHolder {
    var delegate: GGChatExportPickerDelegate?
}

private func ggPEPresentNative(_ controller: UIViewController, from presenter: ViewController?) {
    guard var top = presenter?.view.window?.rootViewController else {
        return
    }
    while let presented = top.presentedViewController {
        top = presented
    }
    if let popover = controller.popoverPresentationController {
        popover.sourceView = top.view
        popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0.0, height: 0.0)
        popover.permittedArrowDirections = []
    }
    top.present(controller, animated: true)
}

func ggMakeChatExportProgressScreen(context: AccountContext) -> ViewController {
    weak var controllerRef: ItemListController?
    let pickerDelegate = GGChatExportDelegateHolder()
    let archiving = ValuePromise<Float?>(nil, ignoreRepeated: true)
    let archiveDisposable = MetaDisposable()

    let model = combineLatest(queue: .mainQueue(), GGChatExportManager.shared.progress, archiving.get(), GGLocalization.shared.languageCodeSignal)
    |> map { progress, archiveProgress, _ -> GGPEScreenModel in
        var model = GGPEScreenModel(title: GGStrings.ChatExport.Progress.title)
        guard let progress = progress, let job = GGChatExportManager.shared.current else {
            model.sections.append([GGPERow(id: "none", kind: .info(GGStrings.ChatExport.Progress.none))])
            return model
        }
        let jobId = progress.jobId

        var status: String
        switch progress.stage {
        case .planning:
            status = GGStrings.ChatExport.Progress.planning
        case .sections:
            status = GGStrings.ChatExport.Progress.sections
        case .chats:
            status = GGStrings.ChatExport.Progress.chat(index: "\(min(progress.chatIndex + 1, progress.chatCount))", count: progress.chatCount, name: progress.chatName ?? "")
        case .finished:
            status = GGStrings.ChatExport.Progress.finished
        case .failed:
            status = GGStrings.ChatExport.Progress.failed(reason: ggChatExportErrorText(progress.errorCode))
        }
        let stats = GGStrings.ChatExport.Progress.stats(messages: "\(progress.messages)", files: "\(progress.files)", size: GGChatExportFormat.fileSize(progress.bytes))
        model.sections.append([
            GGPERow(id: "header", kind: .header(progress.title)),
            GGPERow(id: "status", kind: .info(status + "\n" + stats))
        ])

        switch progress.stage {
        case .finished:
            var rows: [GGPERow] = [
                GGPERow(id: "saveFiles", kind: .action(title: GGStrings.ChatExport.Progress.saveToFiles, destructive: false, enabled: archiveProgress == nil)),
                GGPERow(id: "shareZip", kind: .action(title: archiveProgress.map { GGStrings.ChatExport.Progress.archiving(percent: "\(Int($0 * 100.0))") } ?? GGStrings.ChatExport.Progress.shareZip, destructive: false, enabled: archiveProgress == nil)),
                GGPERow(id: "done", kind: .action(title: GGStrings.ChatExport.Progress.done, destructive: true, enabled: true))
            ]
            rows.append(GGPERow(id: "doneFooter", kind: .footer(GGStrings.ChatExport.Progress.doneFooter)))
            model.sections.append(rows)
            let finish = {
                archiveDisposable.set(nil)
                GGChatExportManager.shared.discard(jobId: jobId)
                controllerRef?.dismiss()
            }
            model.tap["saveFiles"] = {
                let picker = UIDocumentPickerViewController(forExporting: [job.resultURL], asCopy: true)
                let delegate = GGChatExportPickerDelegate(completed: finish)
                pickerDelegate.delegate = delegate
                picker.delegate = delegate
                ggPEPresentNative(picker, from: controllerRef)
            }
            model.tap["shareZip"] = {
                archiving.set(0.0)
                archiveDisposable.set((GGChatExportManager.shared.archive(folder: job.resultURL)
                |> deliverOnMainQueue).start(next: { value, url in
                    archiving.set(url == nil && value < 1.0 ? value : nil)
                    if let url = url {
                        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                        activity.completionWithItemsHandler = { _, completed, _, _ in
                            if completed {
                                finish()
                            }
                        }
                        ggPEPresentNative(activity, from: controllerRef)
                    } else if value >= 1.0, let controller = controllerRef {
                        ggPEPresentToast(context: context, from: controller, text: GGStrings.ChatExport.Progress.zipFailed)
                    }
                }))
            }
            model.tap["done"] = finish
        case .failed:
            model.sections.append([
                GGPERow(id: "retry", kind: .action(title: GGStrings.ChatExport.Progress.retry, destructive: false, enabled: true)),
                GGPERow(id: "delete", kind: .action(title: GGStrings.ChatExport.Progress.delete, destructive: true, enabled: true))
            ])
            model.tap["retry"] = {
                if let free = GGChatExportJob.freeSpace(), free < GGChatExportJob.minimumFreeSpace, let controller = controllerRef {
                    ggPEPresentToast(context: context, from: controller, text: GGStrings.ChatExport.Progress.errorNoSpace)
                    return
                }
                GGChatExportManager.shared.retry()
            }
            model.tap["delete"] = {
                GGChatExportManager.shared.discard(jobId: jobId)
                controllerRef?.dismiss()
            }
        case .planning, .sections, .chats:
            model.sections.append([
                GGPERow(id: "cancel", kind: .action(title: GGStrings.ChatExport.Progress.cancel, destructive: true, enabled: true)),
                GGPERow(id: "cancelFooter", kind: .footer(GGStrings.ChatExport.Progress.runningFooter))
            ])
            model.tap["cancel"] = {
                ggPEConfirmDestructive(context: context, from: controllerRef, title: GGStrings.ChatExport.Progress.cancelTitle, text: GGStrings.ChatExport.Progress.cancelText, confirm: GGStrings.ChatExport.Progress.cancel, action: {
                    GGChatExportManager.shared.cancel()
                    controllerRef?.dismiss()
                })
            }
        }
        return model
    }
    let controller = ggPEMakeListController(context: context, model: model)
    controllerRef = controller

    // The screen does not lock while it shows a running export.
    let idleDisposable = MetaDisposable()
    controller.didAppear = { _ in
        idleDisposable.set((GGChatExportManager.shared.progress
        |> deliverOnMainQueue).start(next: { progress in
            UIApplication.shared.isIdleTimerDisabled = progress?.isRunning == true
        }))
    }
    controller.didDisappear = { _ in
        idleDisposable.set(nil)
        UIApplication.shared.isIdleTimerDisabled = false
    }
    return controller
}

// MARK: - Unfinished exports

func ggMakeChatExportJobsScreen(context: AccountContext) -> ViewController {
    weak var controllerRef: ItemListController?
    let format = GGChatExportFormat(languageCode: GGLocalization.shared.languageCode)

    let model = combineLatest(queue: .mainQueue(), GGChatExportManager.shared.storedJobs(accountId: context.account.id.int64), GGLocalization.shared.languageCodeSignal)
    |> map { journals, _ -> GGPEScreenModel in
        var model = GGPEScreenModel(title: GGStrings.ChatExport.Jobs.title)
        var rows: [GGPERow] = [GGPERow(id: "header", kind: .header(GGStrings.ChatExport.Jobs.header))]
        if journals.isEmpty {
            rows.append(GGPERow(id: "empty", kind: .info(GGStrings.ChatExport.Jobs.empty)))
        }
        for journal in journals {
            let id = "job" + journal.id
            let state: String
            switch journal.stage {
            case .finished:
                state = GGStrings.ChatExport.Jobs.finished
            case .failed:
                state = ggChatExportErrorText(journal.errorCode)
            case .planning, .sections, .chats:
                state = GGStrings.ChatExport.Jobs.paused(index: "\(journal.chatIndex)", count: journal.chats.count)
            }
            rows.append(GGPERow(id: id, kind: .disclosure(title: journal.title, label: format.full(journal.createdAt) + " · " + state, icon: nil, enabled: true)))
            model.tap[id] = {
                var buttons: [(title: String, isDestructive: Bool, action: () -> Void)] = []
                if journal.stage != .finished {
                    buttons.append((title: GGStrings.ChatExport.Jobs.resume, isDestructive: false, action: {
                        GGChatExportAuth.authenticate(reason: GGStrings.ChatExport.Setup.authReason, completion: { success in
                            guard success, let controller = controllerRef else {
                                return
                            }
                            if GGChatExportManager.shared.resume(context: context, journal: journal) {
                                controller.push(ggMakeChatExportProgressScreen(context: context))
                            } else {
                                ggPEPresentToast(context: context, from: controller, text: GGStrings.ChatExport.Setup.alreadyRunning)
                            }
                        })
                    }))
                } else {
                    buttons.append((title: GGStrings.ChatExport.Jobs.open, isDestructive: false, action: {
                        // A finished export can be saved or shared from its screen: Face ID first, as
                        // before it was made.
                        GGChatExportAuth.authenticate(reason: GGStrings.ChatExport.Jobs.authReason, completion: { success in
                            guard success, let controller = controllerRef else {
                                return
                            }
                            if GGChatExportManager.shared.resume(context: context, journal: journal) {
                                controller.push(ggMakeChatExportProgressScreen(context: context))
                            }
                        })
                    }))
                }
                buttons.append((title: GGStrings.ChatExport.Jobs.delete, isDestructive: true, action: {
                    GGChatExportManager.shared.discard(jobId: journal.id)
                }))
                ggPEPresentActionSheet(context: context, from: controllerRef, title: journal.title, buttons: buttons)
            }
        }
        rows.append(GGPERow(id: "footer", kind: .footer(GGStrings.ChatExport.Jobs.footer)))
        model.sections.append(rows)
        return model
    }
    let controller = ggPEMakeListController(context: context, model: model)
    controllerRef = controller
    return controller
}
