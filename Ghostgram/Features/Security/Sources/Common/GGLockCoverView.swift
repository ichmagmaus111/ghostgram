import Foundation
import UIKit
import Display
import TelegramPresentationData
import AppBundle
import AsyncDisplayKit
import GGCore

/// An opaque lock sheet: a lock, a title, «Открыть» to ask again and, where there is something to
/// leave, «Закрыть». Used over a locked chat (it covers the chat's own navigation, so without
/// «Закрыть» a refused check would leave no way out), over a peek of a locked chat (no buttons) and
/// over an account the app switched to without the switch check.
final class GGLockCoverView: UIView {
    var unlock: (() -> Void)?
    var close: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let unlockButton: UIButton?
    private let closeButton: UIButton?
    /// nil — the content is centred; otherwise it starts this far from the top (an area taller than
    /// what is on screen, e.g. a profile's media).
    private let contentTopInset: CGFloat?

    init(theme: PresentationTheme, title: String, unlockTitle: String?, closeTitle: String?, contentTopInset: CGFloat? = nil) {
        self.contentTopInset = contentTopInset
        self.unlockButton = unlockTitle != nil ? UIButton(type: .system) : nil
        self.closeButton = closeTitle != nil ? UIButton(type: .system) : nil
        super.init(frame: .zero)

        self.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.backgroundColor = theme.list.plainBackgroundColor
        // The chat screen keeps adding nodes after the cover (panels, inputs): stay drawn above them.
        self.layer.zPosition = 1000.0

        self.iconView.image = UIImage(bundleImageName: "Chat/Context Menu/Lock")?.withRenderingMode(.alwaysTemplate)
        self.iconView.tintColor = theme.list.itemSecondaryTextColor
        self.iconView.contentMode = .scaleAspectFit
        self.addSubview(self.iconView)

        self.titleLabel.text = title
        self.titleLabel.font = Font.semibold(17.0)
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.titleLabel.textAlignment = .center
        self.titleLabel.numberOfLines = 0
        self.addSubview(self.titleLabel)

        if let unlockButton = self.unlockButton, let unlockTitle {
            unlockButton.setTitle(unlockTitle, for: .normal)
            unlockButton.titleLabel?.font = Font.semibold(17.0)
            unlockButton.setTitleColor(theme.list.itemAccentColor, for: .normal)
            unlockButton.addTarget(self, action: #selector(self.unlockPressed), for: .touchUpInside)
            self.addSubview(unlockButton)
        }
        if let closeButton = self.closeButton, let closeTitle {
            closeButton.setTitle(closeTitle, for: .normal)
            closeButton.titleLabel?.font = Font.regular(17.0)
            closeButton.setTitleColor(theme.list.itemSecondaryTextColor, for: .normal)
            closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
            self.addSubview(closeButton)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        let iconSize = CGSize(width: 44.0, height: 44.0)
        let width = max(1.0, size.width - 64.0)
        let titleSize = self.titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let buttonHeight: CGFloat = 44.0
        let buttons: [UIButton] = [self.unlockButton, self.closeButton].compactMap { $0 }
        let buttonsHeight = buttons.isEmpty ? 0.0 : 24.0 + buttonHeight * CGFloat(buttons.count)
        var y = self.contentTopInset ?? floor((size.height - (iconSize.height + 16.0 + titleSize.height + buttonsHeight)) / 2.0)
        self.iconView.frame = CGRect(origin: CGPoint(x: floor((size.width - iconSize.width) / 2.0), y: y), size: iconSize)
        y += iconSize.height + 16.0
        self.titleLabel.frame = CGRect(origin: CGPoint(x: floor((size.width - titleSize.width) / 2.0), y: y), size: titleSize)
        y += titleSize.height + 24.0
        for button in buttons {
            button.frame = CGRect(x: 32.0, y: y, width: width, height: buttonHeight)
            y += buttonHeight
        }
    }

    @objc private func unlockPressed() {
        self.unlock?()
    }

    @objc private func closePressed() {
        self.close?()
    }
}

/// A full-screen controller carrying a lock sheet, presented above everything
/// (`presentGlobalController`).
final class GGLockCoverController: ViewController {
    private let theme: PresentationTheme
    private let coverTitle: String
    var unlock: (() -> Void)?

    init(theme: PresentationTheme, title: String) {
        self.theme = theme
        self.coverTitle = title
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = theme.rootController.statusBarStyle.style
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNodeDidLoad()
        let cover = GGLockCoverView(theme: self.theme, title: self.coverTitle, unlockTitle: GGStrings.Security.ChatLock.coverUnlock, closeTitle: nil)
        cover.unlock = { [weak self] in
            self?.unlock?()
        }
        cover.frame = self.displayNode.view.bounds
        self.displayNode.view.addSubview(cover)
    }
}
