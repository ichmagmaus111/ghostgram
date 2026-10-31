import Foundation
import UIKit
import Display
import TelegramCore
import AccountContext
import GGCore

// The slot next to a name where the nick badge goes. One line per place that shows a name
// (chat header, contacts, peer lists; the chat list and the profile header use the same view from
// their decoration points): `GGNickBadgeSlot.update(&self.ggNickBadgeView, ...)`.
//
// This target knows nothing about the badges themselves: the feature (GGProfileExport) registers a
// provider that answers from memory. Without a provider every call is one `isEmpty` load and the
// slot stays empty, so the places that host it behave exactly as upstream.

/// What a provider is asked: whose badge, for which account, at which line height.
public struct GGNickBadgeRequest {
    public let peerId: EnginePeer.Id
    public let context: AccountContext
    /// Height of the line the badge sits on, in points.
    public let height: CGFloat

    public init(peerId: EnginePeer.Id, context: AccountContext, height: CGFloat) {
        self.peerId = peerId
        self.context = context
        self.height = height
    }
}

/// A badge ready to draw: the picture at the requested height and what a tap does.
public struct GGNickBadgeContent {
    public let image: UIImage
    /// Called on the main thread with the badge view (the anchor for a bulletin or a tooltip).
    public let tap: ((UIView) -> Void)?

    public init(image: UIImage, tap: ((UIView) -> Void)?) {
        self.image = image
        self.tap = tap
    }
}

public enum GGNickBadgeSlot {
    /// Policy (first non-nil wins). Called on any thread, also from layout passes: answer from
    /// memory only — no disk, no network, no `UserDefaults`.
    public static let provider = GGHookPoint<(GGNickBadgeRequest) -> GGNickBadgeContent?>("nickBadge.provider")

    /// The badge of `peerId`, if it has one.
    public static func content(peerId: EnginePeer.Id?, context: AccountContext, height: CGFloat) -> GGNickBadgeContent? {
        if GGNickBadgeSlot.provider.isEmpty {
            return nil
        }
        guard let peerId = peerId else {
            return nil
        }
        let request = GGNickBadgeRequest(peerId: peerId, context: context, height: height)
        for handler in GGNickBadgeSlot.provider.handlers {
            if let content = handler(request) {
                return content
            }
        }
        return nil
    }

    /// Room a layout pass must leave after the name: the badge width plus `spacing`, or 0.
    public static func reservedWidth(peerId: EnginePeer.Id?, context: AccountContext, height: CGFloat, spacing: CGFloat = 4.0) -> CGFloat {
        guard let content = GGNickBadgeSlot.content(peerId: peerId, context: context, height: height) else {
            return 0.0
        }
        return content.image.size.width + spacing
    }

    /// Set by the feature (main thread) while badges are shown at all. While it is set, a user's slot
    /// keeps an empty hidden view even without a badge, so a badge that arrives later (the table is
    /// read after the first rows are laid out) appears in place without waiting for a relayout.
    public static var isActive: Bool = false

    /// Places (or removes) the badge view of `peerId` in `container`, `spacing` after `originX`,
    /// vertically centred on `centerY`. Returns the x after the badge (`originX` when there is none).
    /// `maxX`: the badge must end before it (the date of a chat list row) — one that does not fit is
    /// hidden, also when it is redrawn later by `refreshVisibleSlots`. Main thread.
    @discardableResult
    public static func update(_ view: inout GGNickBadgeView?, peerId: EnginePeer.Id?, context: AccountContext, container: UIView, originX: CGFloat, centerY: CGFloat, height: CGFloat, spacing: CGFloat = 4.0, maxX: CGFloat? = nil) -> CGFloat {
        guard let peerId = peerId, GGNickBadgeSlot.isActive, peerId.namespace == Namespaces.Peer.CloudUser else {
            if let current = view {
                current.removeFromSuperview()
                view = nil
            }
            return originX
        }
        let badgeView: GGNickBadgeView
        if let current = view {
            badgeView = current
        } else {
            badgeView = GGNickBadgeView(frame: CGRect())
            view = badgeView
        }
        if badgeView.superview !== container {
            container.addSubview(badgeView)
        }
        let content = GGNickBadgeSlot.content(peerId: peerId, context: context, height: height)
        badgeView.configure(peerId: peerId, context: context, height: height, anchor: CGPoint(x: originX + spacing, y: centerY), maxX: maxX, content: content)
        if content == nil || badgeView.isHidden {
            return originX
        }
        return badgeView.frame.maxX
    }

    /// The tappable badge under `point` (in `root`'s coordinates) among the badges shown inside `root`,
    /// for hosts whose own hit test never reaches the badge view: the profile header keeps its name in
    /// a zero-size container (UIKit does not descend into it), list rows test their own parts first.
    /// The host returns the view from its `hitTest`; the badge's own recognizer then takes the tap.
    public static func tappableBadgeView(at point: CGPoint, in root: UIView) -> UIView? {
        if !GGNickBadgeSlot.isActive || GGNickBadgeViewRegistry.views.count == 0 {
            return nil
        }
        for view in GGNickBadgeViewRegistry.views.allObjects {
            guard view.canTakeTap, view.window != nil, view.isDescendant(of: root) else {
                continue
            }
            // Visible as drawn: the profile header fades one of its two name states out.
            var current: UIView? = view
            var isVisible = true
            while let candidate = current, candidate !== root {
                if candidate.isHidden || candidate.alpha <= 0.01 {
                    isVisible = false
                    break
                }
                current = candidate.superview
            }
            if !isVisible {
                continue
            }
            if view.point(inside: root.convert(point, to: view), with: nil) {
                return view
            }
        }
        return nil
    }

    /// The badges changed (a new table, a picture arrived, the feature was turned on or off): every
    /// badge view on screen asks again and redraws in place. Main thread.
    public static func refreshVisibleSlots() {
        assert(Thread.isMainThread)
        for view in GGNickBadgeViewRegistry.views.allObjects {
            view.refresh()
        }
    }
}

enum GGNickBadgeViewRegistry {
    /// Main thread only.
    static let views = NSHashTable<GGNickBadgeView>.weakObjects()
}

/// The badge next to a name. Sized to its picture; the tap target is a little larger than it.
public final class GGNickBadgeView: UIView {
    private let imageView: UIImageView
    private var tapRecognizer: UITapGestureRecognizer?

    public private(set) var peerId: EnginePeer.Id?
    private weak var context: AccountContext?
    private var height: CGFloat = 0.0
    /// Leading x and vertical centre the badge keeps when it redraws itself.
    private var anchor = CGPoint()
    /// The x the badge must end before (nil = no limit); kept for redraws too, so a badge that arrives
    /// after its row was laid out does not cover the date.
    private var maxX: CGFloat?
    private var tap: ((UIView) -> Void)?

    /// Sites whose own gesture recognizer would swallow the tap (the chat header) turn this off and
    /// forward taps with `handleTap(at:)`.
    public var usesOwnTapRecognizer: Bool = true {
        didSet {
            self.tapRecognizer?.isEnabled = self.usesOwnTapRecognizer
        }
    }

    override public init(frame: CGRect) {
        self.imageView = UIImageView()
        self.imageView.isUserInteractionEnabled = false
        super.init(frame: frame)
        self.addSubview(self.imageView)
        self.isAccessibilityElement = false
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        self.addGestureRecognizer(recognizer)
        self.tapRecognizer = recognizer
        GGNickBadgeViewRegistry.views.add(self)
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(peerId: EnginePeer.Id, context: AccountContext, height: CGFloat, anchor: CGPoint, maxX: CGFloat?, content: GGNickBadgeContent?) {
        self.peerId = peerId
        self.context = context
        self.height = height
        self.anchor = anchor
        self.maxX = maxX
        if let content = content {
            self.apply(content)
        } else {
            self.tap = nil
            self.isHidden = true
        }
    }

    private func apply(_ content: GGNickBadgeContent) {
        self.tap = content.tap
        if self.imageView.image !== content.image {
            self.imageView.image = content.image
        }
        let size = content.image.size
        self.frame = CGRect(origin: CGPoint(x: self.anchor.x, y: floorToScreenPixels(self.anchor.y - size.height / 2.0)), size: size)
        self.imageView.frame = CGRect(origin: CGPoint(), size: size)
        self.isUserInteractionEnabled = content.tap != nil
        if let maxX = self.maxX, self.frame.maxX > maxX {
            // Does not fit before the limit: hidden until the row is laid out again with room for it.
            self.isHidden = true
            return
        }
        self.isHidden = false
    }

    func refresh() {
        guard let peerId = self.peerId, let context = self.context, self.superview != nil else {
            return
        }
        if let content = GGNickBadgeSlot.content(peerId: peerId, context: context, height: self.height) {
            self.apply(content)
        } else {
            self.tap = nil
            self.isHidden = true
        }
    }

    /// Shown, with a tap, and taking touches with its own recognizer.
    var canTakeTap: Bool {
        return !self.isHidden && self.tap != nil && self.isUserInteractionEnabled && self.usesOwnTapRecognizer
    }

    /// For sites that forward taps: `point` in this view's coordinates. `true` = the badge took it.
    public func handleTap(at point: CGPoint) -> Bool {
        guard !self.isHidden, self.point(inside: point, with: nil), let tap = self.tap else {
            return false
        }
        tap(self)
        return true
    }

    @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended, let tap = self.tap {
            tap(self)
        }
    }

    override public func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return self.bounds.insetBy(dx: -6.0, dy: -6.0).contains(point)
    }
}
