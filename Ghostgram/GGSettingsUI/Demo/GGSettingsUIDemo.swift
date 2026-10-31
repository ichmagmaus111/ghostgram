import Foundation
import UIKit
import Display
import TelegramPresentationData
import ItemListUI
import GGCore
import GGSettingsUI

// Demo registration of the menu skeleton. NOT part of the normal launch: it exists so the
// orchestrator can check every row type and every preview in the simulator before wave 2.
// Enable it by adding `//Ghostgram/GGSettingsUI:GGSettingsUIDemo` to the deps of GGFeatures and
// calling `GGSettingsUIDemo.register()` right after `GGSettingsUI.register()` (see USAGE.md).

enum GGSettingsUIDemoSettings {
    static let toggle = GGSetting<Bool>("menuDemo.toggle", default: false)
    static let choice = GGSetting<String>("menuDemo.choice", default: "a")
    static let longChoice = GGSetting<String>("menuDemo.longChoice", default: "1")
    static let slider = GGSetting<Double>("menuDemo.slider", default: 50.0)
    static let discrete = GGSetting<String>("menuDemo.discrete", default: "medium")
    static let cards = GGSetting<String>("menuDemo.cards", default: "round")
    static let group = GGSetting<Bool>("menuDemo.group", default: false)
    static let groupFirst = GGSetting<Bool>("menuDemo.groupFirst", default: true)
    static let groupSecond = GGSetting<Bool>("menuDemo.groupSecond", default: false)
    static let groupThird = GGSetting<Bool>("menuDemo.groupThird", default: false)
    static let listFirst = GGSetting<Bool>("menuDemo.listFirst", default: true)
    static let listSecond = GGSetting<Bool>("menuDemo.listSecond", default: false)
    static let listThird = GGSetting<Bool>("menuDemo.listThird", default: false)
    static let restart = GGSetting<Bool>("menuDemo.restart", default: false, flags: [.requiresRestart])
    static let accountToggle = GGAccountSetting<Bool>("menuDemo.accountToggle", default: false)
    static let transparency = GGSetting<Double>("menuDemo.transparency", default: 50.0)
    static let segmentToggle = GGSetting<Bool>("menuDemo.segmentToggle", default: false)

    static func touchAll() {
        let _ = toggle
        let _ = choice
        let _ = longChoice
        let _ = slider
        let _ = discrete
        let _ = cards
        let _ = group
        let _ = groupFirst
        let _ = groupSecond
        let _ = groupThird
        let _ = listFirst
        let _ = listSecond
        let _ = listThird
        let _ = restart
        let _ = accountToggle
        let _ = transparency
        let _ = segmentToggle
    }
}

/// A custom preview: a rounded square whose corner radius follows the demo slider while it is
/// dragged (draft), then the stored value.
private final class GGDemoPreviewView: UIView, GGMenuPreviewView {
    private let shapeView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.shapeView)
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    func update(context: GGMenuContext) {
        let theme = context.presentationData.theme
        self.backgroundColor = ggPreviewBackgroundColor(theme: theme)
        self.shapeView.backgroundColor = theme.list.itemAccentColor
        let value = context.displayValue(.global(GGSettingsUIDemoSettings.slider))
        self.shapeView.layer.cornerRadius = CGFloat(value) / 100.0 * 30.0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = 60.0
        self.shapeView.frame = CGRect(x: floor((self.bounds.width - side) / 2.0), y: floor((self.bounds.height - side) / 2.0), width: side, height: side)
    }
}

private func ggDemoCardImage(_ kind: String, theme: PresentationTheme) -> UIImage? {
    let size = CGSize(width: 40.0, height: 40.0)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
        theme.list.itemAccentColor.setFill()
        let rect = CGRect(origin: CGPoint(), size: size)
        switch kind {
        case "round":
            UIBezierPath(ovalIn: rect).fill()
        case "squircle":
            UIBezierPath(roundedRect: rect, cornerRadius: 12.0).fill()
        default:
            UIBezierPath(rect: rect).fill()
        }
    }
}

public enum GGSettingsUIDemo {
    public static let tabId = GGMenuTabID("menuDemo.tab")

    public static func register() {
        assert(Thread.isMainThread)
        GGSettingsUIDemoSettings.touchAll()
        GGSettingsUI.showsEmptyScreens = true

        let tabId = GGSettingsUIDemo.tabId
        GGMenuRegistry.register(
            tab: GGMenuTabDescriptor(
                id: tabId,
                parent: .category(.more),
                title: { GGStrings.Menu.Demo.title },
                topView: GGMenuTopView(content: .animation("ChatListFolders"), text: { GGStrings.Menu.Demo.topText }),
                segments: [
                    GGMenuSegment(id: "first", title: { GGStrings.Menu.Demo.segmentFirst }),
                    GGMenuSegment(id: "second", title: { GGStrings.Menu.Demo.segmentSecond })
                ]
            ),
            linkIn: .moreTabs,
            order: 900,
            subtitle: { GGStrings.Menu.Demo.subtitle },
            icon: .system("hammer"),
            label: { _ in
                return GGSettingsUIDemoSettings.toggle.value ? GGStrings.Menu.Demo.on : nil
            }
        )

        let previews = GGMenuSectionID("menuDemo.previews")
        let rows = GGMenuSectionID("menuDemo.rows")
        let more = GGMenuSectionID("menuDemo.more")
        let second = GGMenuSectionID("menuDemo.second")
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: previews, screen: .tab(tabId), order: 100, segment: "first", header: { GGStrings.Menu.Demo.previewsHeader }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: rows, screen: .tab(tabId), order: 200, segment: "first", header: { GGStrings.Menu.Demo.rowsHeader }, footer: { _ in GGStrings.Menu.Demo.rowsFooter }))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: more, screen: .tab(tabId), order: 300, segment: "first"))
        GGMenuRegistry.register(section: GGMenuSectionDescriptor(id: second, screen: .tab(tabId), order: 400, segment: "second", header: { GGStrings.Menu.Demo.secondHeader }))

        // Previews.
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.miniChat", section: previews, order: 100, title: { "" }, kind: .preview(.miniChat(GGMiniChatConfiguration(scope: "menuDemo", height: 236.0, content: { _ in
            var content = GGMiniChatContent.sample(header: GGMiniChatContent.sampleHeader())
            content.messages.append(GGPreviewMessage(id: 3, isOutgoing: true, text: GGStrings.Menu.Preview.pendingText, isPending: true, ageSeconds: 60))
            return content
        })))))
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.transparency", section: previews, order: 200, title: { GGStrings.Menu.Demo.transparency }, kind: .slider(.global(GGSettingsUIDemoSettings.transparency), range: 0.0 ... 100.0, step: 5.0, format: { value in
            return "\(Int(value)) %"
        })))
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.miniChatList", section: previews, order: 300, title: { "" }, kind: .preview(.miniChatList(GGMiniChatListConfiguration(scope: "menuDemo", height: 228.0, rows: { _ in
            return GGPreviewChatListRow.samples()
        })))))
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.customPreview", section: previews, order: 400, title: { "" }, kind: .preview(.custom(height: 120.0, make: { _ in
            return GGDemoPreviewView(frame: CGRect())
        }))))

        // Modifiers: the second demo message follows the transparency slider (draft while dragging)
        // and is marked «edited»; the first chat row gets typing while the demo toggle is on.
        GGPreviewModifiers.registerChatModifier(id: "menuDemo.transparency", order: 100) { messages, context in
            guard context.previewScope == "menuDemo" else {
                return
            }
            let transparency = context.displayValue(.global(GGSettingsUIDemoSettings.transparency))
            for i in 0 ..< messages.count where messages[i].id == 2 {
                messages[i].alpha = CGFloat(max(0.15, 1.0 - transparency / 100.0))
                messages[i].isEdited = true
                messages[i].mark = GGPreviewMark(icon: .bundle("Chat/Context Menu/Delete"))
            }
        }
        GGPreviewModifiers.registerChatListModifier(id: "menuDemo.typing", order: 100) { rows, context in
            guard context.previewScope == "menuDemo", GGSettingsUIDemoSettings.toggle.value, !rows.isEmpty else {
                return
            }
            rows[0].isTyping = true
        }

        // One row of every kind.
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.toggle", section: rows, order: 100, title: { GGStrings.Menu.Demo.toggle }, subtitle: { GGStrings.Menu.Demo.toggleExample }, kind: .toggle(.global(GGSettingsUIDemoSettings.toggle)), searchKeywords: { [GGStrings.Menu.Demo.keywords] }))
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.choice", section: rows, order: 200, title: { GGStrings.Menu.Demo.choice }, icon: .bundle("Chat/Context Menu/Customize"), kind: .choice(.global(GGSettingsUIDemoSettings.choice), options: [
            GGMenuChoiceOption(value: "a", title: { GGStrings.Menu.Demo.optionA }),
            GGMenuChoiceOption(value: "b", title: { GGStrings.Menu.Demo.optionB }),
            GGMenuChoiceOption(value: "c", title: { GGStrings.Menu.Demo.optionC })
        ])))
        var longOptions: [GGMenuChoiceOption] = []
        for index in 1 ... 9 {
            longOptions.append(GGMenuChoiceOption(value: "\(index)", title: { GGStrings.Menu.Demo.optionNumber(number: "\(index)") }))
        }
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.longChoice", section: rows, order: 300, title: { GGStrings.Menu.Demo.longChoice }, icon: .bundle("Chat/Context Menu/List"), kind: .choice(.global(GGSettingsUIDemoSettings.longChoice), options: longOptions)))
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.slider", section: rows, order: 400, title: { GGStrings.Menu.Demo.slider }, kind: .slider(.global(GGSettingsUIDemoSettings.slider), range: 0.0 ... 100.0, step: 1.0, format: { value in
            return "\(Int(value))"
        })))
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.discrete", section: rows, order: 500, title: { GGStrings.Menu.Demo.discrete }, kind: .discreteChoice(.global(GGSettingsUIDemoSettings.discrete), options: [
            GGMenuChoiceOption(value: "off", title: { GGStrings.Menu.Demo.levelOff }),
            GGMenuChoiceOption(value: "medium", title: { GGStrings.Menu.Demo.levelMedium }),
            GGMenuChoiceOption(value: "high", title: { GGStrings.Menu.Demo.levelHigh })
        ])))
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.cards", section: rows, order: 600, title: { GGStrings.Menu.Demo.cards }, kind: .cards(.global(GGSettingsUIDemoSettings.cards), options: [
            GGMenuCardOption(value: "round", title: { GGStrings.Menu.Demo.shapeRound }, image: { theme in ggDemoCardImage("round", theme: theme) }),
            GGMenuCardOption(value: "squircle", title: { GGStrings.Menu.Demo.shapeSquircle }, image: { theme in ggDemoCardImage("squircle", theme: theme) }),
            GGMenuCardOption(value: "square", title: { GGStrings.Menu.Demo.shapeSquare }, image: { theme in ggDemoCardImage("square", theme: theme) })
        ])))
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.group", section: rows, order: 700, title: { GGStrings.Menu.Demo.group }, kind: .expandableGroup(master: .global(GGSettingsUIDemoSettings.group), children: [
            GGMenuRow(id: "menuDemo.groupFirst", section: rows, order: 100, title: { GGStrings.Menu.Demo.groupFirst }, kind: .toggle(.global(GGSettingsUIDemoSettings.groupFirst))),
            GGMenuRow(id: "menuDemo.groupSecond", section: rows, order: 200, title: { GGStrings.Menu.Demo.groupSecond }, kind: .toggle(.global(GGSettingsUIDemoSettings.groupSecond))),
            GGMenuRow(id: "menuDemo.groupThird", section: rows, order: 300, title: { GGStrings.Menu.Demo.groupThird }, kind: .toggle(.global(GGSettingsUIDemoSettings.groupThird)))
        ])))
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.list", section: rows, order: 750, title: { GGStrings.Menu.Demo.list }, kind: .expandableList(children: [
            GGMenuRow(id: "menuDemo.listFirst", section: rows, order: 100, title: { GGStrings.Menu.Demo.groupFirst }, kind: .toggle(.global(GGSettingsUIDemoSettings.listFirst))),
            GGMenuRow(id: "menuDemo.listSecond", section: rows, order: 200, title: { GGStrings.Menu.Demo.groupSecond }, kind: .toggle(.global(GGSettingsUIDemoSettings.listSecond))),
            GGMenuRow(id: "menuDemo.listThird", section: rows, order: 300, title: { GGStrings.Menu.Demo.groupThird }, kind: .toggle(.global(GGSettingsUIDemoSettings.listThird)))
        ], summary: { count in
            return GGStrings.Menu.Demo.listCount(selected: "\(count.selected)", total: "\(count.total)")
        })))
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.action", section: rows, order: 800, title: { GGStrings.Menu.Demo.action }, icon: .bundle("Chat/Context Menu/Info"), kind: .action({ context in
            context.presentToast(GGStrings.Menu.Demo.actionDone)
        })))

        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.restart", section: more, order: 100, title: { GGStrings.Menu.Demo.restart }, kind: .toggle(.global(GGSettingsUIDemoSettings.restart))))
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.accountToggle", section: more, order: 200, title: { GGStrings.Menu.Demo.accountToggle }, subtitle: { GGStrings.Menu.Demo.accountToggleInfo }, kind: .toggle(.account(GGSettingsUIDemoSettings.accountToggle))))
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.dependent", section: more, order: 300, title: { GGStrings.Menu.Demo.dependent }, kind: .action({ context in
            context.presentToast(GGStrings.Menu.Demo.actionDone)
        }), isVisible: { _ in
            return GGSettingsUIDemoSettings.toggle.value
        }))
        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.custom", section: more, order: 400, title: { GGStrings.Menu.Demo.custom }, kind: .custom({ context in
            return ItemListTextItem(presentationData: context.itemListPresentationData, text: .plain(GGStrings.Menu.Demo.custom), sectionId: context.sectionId)
        })))

        GGMenuRegistry.register(GGMenuRow(id: "menuDemo.segmentToggle", section: second, order: 100, title: { GGStrings.Menu.Demo.segmentToggle }, kind: .toggle(.global(GGSettingsUIDemoSettings.segmentToggle))))
    }
}
