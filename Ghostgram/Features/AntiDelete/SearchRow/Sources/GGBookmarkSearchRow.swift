import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import GGCore
import GGFeaturesShared

/// The row of bookmarks of a chat under its search field (`ChatSearchNavigationContentNode`): a
/// tap jumps to the bookmarked message. Lives in its own small library so the upstream node only
/// creates it, lays it out and asks for its height (three `// GHOST:` lines).
public final class GGBookmarkSearchRow: NSObject {
    public static let rowHeight: CGFloat = 40.0

    public let view: UIView
    private let scrollView: UIScrollView
    private var buttons: [UIButton] = []
    private var entries: [GGBookmarkEntry] = []
    private var theme: PresentationTheme
    private var disposable: Disposable?
    private let navigate: (MessageId) -> Void
    private let requestLayout: () -> Void
    private var lastFrame: CGRect = .zero

    /// nil when bookmarks are off or the chat has no peer: no row and no subscription at all.
    public static func make(context: AccountContext, chatLocation: ChatLocation, theme: PresentationTheme, navigate: @escaping (MessageId) -> Void, requestLayout: @escaping () -> Void) -> GGBookmarkSearchRow? {
        guard GGBookmarkSettings.enabled.value, let peerId = chatLocation.peerId else {
            return nil
        }
        return GGBookmarkSearchRow(postbox: context.account.postbox, peerId: peerId, threadId: chatLocation.threadId, theme: theme, navigate: navigate, requestLayout: requestLayout)
    }

    private init(postbox: Postbox, peerId: PeerId, threadId: Int64?, theme: PresentationTheme, navigate: @escaping (MessageId) -> Void, requestLayout: @escaping () -> Void) {
        self.theme = theme
        self.navigate = navigate
        self.requestLayout = requestLayout
        self.view = UIView()
        self.view.clipsToBounds = true
        self.scrollView = UIScrollView()
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.alwaysBounceHorizontal = true
        self.view.addSubview(self.scrollView)

        super.init()

        let peerKey = peerId.ggKey
        self.disposable = (GGAntiDeleteIndexStore.bookmarksSignal(postbox: postbox)
        |> map { list -> [GGBookmarkEntry] in
            return list.entries(peer: peerKey, threadId: threadId)
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak self] entries in
            self?.update(entries: entries)
        })
    }

    deinit {
        self.disposable?.dispose()
    }

    public var height: CGFloat {
        return self.entries.isEmpty ? 0.0 : GGBookmarkSearchRow.rowHeight
    }

    private func update(entries: [GGBookmarkEntry]) {
        let wasVisible = !self.entries.isEmpty
        self.entries = entries
        for button in self.buttons {
            button.removeFromSuperview()
        }
        self.buttons = entries.enumerated().map { index, entry in
            let button = UIButton(type: .custom)
            button.tag = index
            button.setTitle("🔖 " + entry.title, for: .normal)
            button.titleLabel?.font = Font.medium(15.0)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.layer.cornerRadius = 15.0
            button.addTarget(self, action: #selector(self.buttonPressed(_:)), for: .touchUpInside)
            self.scrollView.addSubview(button)
            return button
        }
        self.applyTheme()
        if wasVisible != !entries.isEmpty {
            self.requestLayout()
        } else {
            self.layout(frame: self.lastFrame)
        }
    }

    @objc private func buttonPressed(_ sender: UIButton) {
        guard sender.tag >= 0 && sender.tag < self.entries.count else {
            return
        }
        self.navigate(MessageId(ggKey: self.entries[sender.tag].message))
    }

    public func updateTheme(_ theme: PresentationTheme) {
        if self.theme === theme {
            return
        }
        self.theme = theme
        self.applyTheme()
    }

    private func applyTheme() {
        let accent = self.theme.chat.inputPanel.panelControlAccentColor
        for button in self.buttons {
            button.setTitleColor(accent, for: .normal)
            button.backgroundColor = accent.withAlphaComponent(0.12)
        }
    }

    /// `frame` is the area under the search field, in the navigation content node.
    public func layout(frame: CGRect) {
        self.lastFrame = frame
        self.view.frame = frame
        self.view.isHidden = self.entries.isEmpty
        self.scrollView.frame = CGRect(origin: CGPoint(), size: frame.size)
        var x: CGFloat = 16.0
        let buttonHeight: CGFloat = 30.0
        let font = Font.medium(15.0)
        for button in self.buttons {
            let title = button.title(for: .normal) ?? ""
            let titleWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
            let width = min(220.0, max(60.0, titleWidth + 24.0))
            button.frame = CGRect(x: x, y: floor((frame.height - buttonHeight) * 0.5), width: width, height: buttonHeight)
            x += width + 8.0
        }
        self.scrollView.contentSize = CGSize(width: x + 8.0, height: frame.height)
    }
}
