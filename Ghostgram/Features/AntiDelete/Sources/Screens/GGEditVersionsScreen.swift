import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import AccountContext
import Pasteboard
import GGCore
import GGFeaturesShared

/// «История правок» of one message: the current text and every saved version with its server
/// date. A long tap copies a version. No alert with an unbounded text: a list.
func ggMakeEditVersionsController(context: AccountContext, messageId: MessageId) -> ViewController {
    weak var weakController: ViewController?
    let message = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))

    let model = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, message)
    |> map { presentationData, message -> GGADScreenModel in
        var model = GGADScreenModel(title: .text(GGStrings.AntiDelete.Versions.title), sections: [])
        guard let message = message?._asMessage() else {
            model.sections.append(GGADSection(id: "empty", rows: [GGADRow(id: "empty", kind: .footer(GGStrings.AntiDelete.Versions.gone))]))
            return model
        }
        let state = GGAntiDeleteMessageState(attributes: message.attributes)
        let current = message.ggEffectiveText
        var currentText = current.text
        if currentText.isEmpty, let token = ggAntiDeleteMediaToken(message.media) {
            currentText = ggAntiDeleteMediaTitle(token)
        }
        model.sections.append(GGADSection(id: "current", rows: [
            GGADRow(id: "current.header", kind: .header(GGStrings.AntiDelete.Versions.current)),
            GGADRow(id: "current", kind: .text(currentText))
        ]))
        model.tap["current"] = {
            storeMessageTextInPasteboard(current.text, entities: current.entities)
        }

        let versions = state.history?.versions ?? []
        if versions.isEmpty {
            model.sections.append(GGADSection(id: "none", rows: [GGADRow(id: "none", kind: .footer(GGStrings.AntiDelete.Versions.none))]))
        } else {
            var rows: [GGADRow] = []
            for (index, version) in versions.enumerated().reversed() {
                let date = stringForMediumDate(timestamp: version.date, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat)
                var text = version.text
                if let media = version.mediaDescription {
                    let mediaTitle = ggAntiDeleteMediaTitle(media)
                    text = text.isEmpty ? mediaTitle : mediaTitle + "\n" + text
                }
                rows.append(GGADRow(id: "version.\(index).header", kind: .header(date)))
                rows.append(GGADRow(id: "version.\(index)", kind: .text(text)))
                model.tap["version.\(index)"] = {
                    storeMessageTextInPasteboard(version.text, entities: version.entities)
                }
            }
            rows.append(GGADRow(id: "versions.footer", kind: .footer(GGStrings.AntiDelete.Versions.copyHint)))
            model.sections.append(GGADSection(id: "versions", rows: rows))
        }

        var actions: [GGADRow] = [GGADRow(id: "open", kind: .action(title: GGStrings.AntiDelete.History.openInChat, destructive: false))]
        model.tap["open"] = {
            if let navigationController = weakController?.navigationController as? NavigationController {
                ggOpenMessage(context: context, navigationController: navigationController, messageId: messageId, threadId: message.threadId)
            }
        }
        if !versions.isEmpty {
            actions.append(GGADRow(id: "clear", kind: .action(title: GGStrings.AntiDelete.History.clearVersions, destructive: true)))
            model.tap["clear"] = {
                let _ = GGAntiDeleteOperations.removeEditHistory(postbox: context.account.postbox, accountId: context.account.id, messageIds: [messageId]).start()
            }
        }
        model.sections.append(GGADSection(id: "actions", rows: actions))
        return model
    }

    let controller = ggMakeADListController(context: context, model: model)
    weakController = controller
    return controller
}
