// Compiled into ChatListUI (filegroup //Ghostgram/GGHooks:ChatListUIHookSources).
// «Папки внизу» (W2-5 folders_tweaks, SG-A5): the folder tabs of the root chat list in their own
// glass strip above the tab bar instead of the header. ChatListControllerNode hands the tabs it
// built for the header to `takeTabs` (every header layout, both the full container layout and
// `requestNavigationBarLayout`); the strip is laid out there and the list's bottom inset grows by
// `reservedHeight`. The strip is a second HeaderPanelContainerComponent with the same tabs, so
// taps, the context menu, editing and reordering are the header's own.
//
// While `GGChatListFolderStrip.atBottom` is off, `takeTabs` returns the tabs unchanged and nothing
// is created: the header is upstream's.

import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramPresentationData
import AccountContext
import HeaderPanelContainerComponent
import HorizontalTabsComponent
import ChatListTitleView

final class GGChatListBottomFolderStrip {
    /// Gap between the strip and the tab bar; the same again under the list's last row.
    private static let spacing: CGFloat = 8.0

    private var host: ComponentView<Empty>?
    /// Height the list leaves free at its bottom for the strip; 0 while the strip is not shown.
    private(set) var reservedHeight: CGFloat = 0.0

    init() {
    }

    /// The tabs for the header. With «Папки внизу» on they go to the strip (laid out here, in
    /// `parentView` above `aboveView`) and the header gets nil. `isHidden`: search or an inline
    /// forum covers the list — the strip fades out, the tabs still stay out of the header.
    func takeTabs(_ tabs: AnyComponent<Empty>?, context: AccountContext, layout: ContainerViewLayout, theme: PresentationTheme, parentView: UIView, aboveView: UIView, isHidden: Bool, transition: ComponentTransition) -> AnyComponent<Empty>? {
        let strip = ggChatListFolderStrip(context: context)
        if !strip.atBottom {
            self.remove(transition: transition)
            return tabs
        }
        guard let tabs = tabs, !isHidden else {
            self.remove(transition: transition)
            return nil
        }

        let host: ComponentView<Empty>
        var hostTransition = transition
        if let current = self.host {
            host = current
        } else {
            host = ComponentView()
            self.host = host
            hostTransition = .immediate
        }
        let width = layout.size.width - layout.safeInsets.left - layout.safeInsets.right
        let size = host.update(
            transition: hostTransition,
            component: AnyComponent(HeaderPanelContainerComponent(
                theme: theme,
                tabs: tabs,
                panels: [],
                ggTabsHeightOffset: strip.heightOffset
            )),
            environment: {},
            containerSize: CGSize(width: width, height: 10000.0)
        )
        // `intrinsicInsets.bottom` of the chat list is the top of the tab bar (TabBarController), or
        // the safe area when the tab bar is hidden.
        let bottomEdge = layout.size.height - layout.insets(options: []).bottom
        let frame = CGRect(origin: CGPoint(x: layout.safeInsets.left, y: bottomEdge - GGChatListBottomFolderStrip.spacing - size.height), size: size)
        if let view = host.view {
            if view.superview == nil {
                parentView.insertSubview(view, aboveSubview: aboveView)
                view.alpha = 0.0
            }
            hostTransition.setFrame(view: view, frame: frame)
            transition.setAlpha(view: view, alpha: 1.0)
        }
        self.reservedHeight = size.height + GGChatListBottomFolderStrip.spacing * 2.0
        return nil
    }

    /// Follows a swipe between folders, as the header's tabs do (ChatListController).
    func updateTabSwitchFraction(fraction: CGFloat, isDragging: Bool, transition: ComponentTransition) {
        self.tabsView?.updateTabSwitchFraction(fraction: fraction, isDragging: isDragging, transition: transition)
    }

    /// The folder order after the tabs were reordered in the strip, as ChatListController maps the
    /// header's (`Int32.min` — «All chats» — is 0). Nil when nothing was reordered here.
    var reorderedFilterIds: [Int32]? {
        guard let itemIds = self.tabsView?.reorderedItemIds else {
            return nil
        }
        return itemIds.compactMap { item -> Int32? in
            guard let value = item.base as? Int32 else {
                return nil
            }
            if value == Int32.min {
                return 0
            }
            return value
        }
    }

    private var tabsView: HorizontalTabsComponent.View? {
        guard let containerView = self.host?.view as? HeaderPanelContainerComponent.View else {
            return nil
        }
        return containerView.tabs as? HorizontalTabsComponent.View
    }

    private func remove(transition: ComponentTransition) {
        self.reservedHeight = 0.0
        guard let host = self.host else {
            return
        }
        self.host = nil
        if let view = host.view {
            transition.setAlpha(view: view, alpha: 0.0, completion: { [weak view] _ in
                view?.removeFromSuperview()
            })
        }
    }
}
