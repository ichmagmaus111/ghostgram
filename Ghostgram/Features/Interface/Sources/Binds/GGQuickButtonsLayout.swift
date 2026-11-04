import Foundation
import UIKit
import Display
import TelegramPresentationData
import AppBundle
import GGFeaturesShared

/// Where the quick buttons stand and how big they are — one set of rules for the chat
/// (`GGQuickButtonsOverlay`) and for the editor's full chat preview, so a button stands in the chat
/// where it was dropped in the editor.
///
/// The free area is the history's area (under the navigation bar, above the input panels, inside
/// the safe area) minus `margin`. A stored position is the button's centre in that area, 0…1 over
/// the range the centre can take: every size stays inside, and the area may change (another
/// phone, the keyboard, the input editor's lift) without losing the arrangement.
enum GGQuickButtonsLayout {
    static let defaultSide: Double = 40.0
    static let sideRange: ClosedRange<Double> = 28.0 ... 80.0
    static let spacing: CGFloat = 8.0
    static let margin: CGFloat = 8.0
    /// The default column stands this far inside the area's right edge (10 pt from the safe edge).
    static let columnInset: CGFloat = 2.0

    static func clampedSide(_ value: Double) -> CGFloat {
        let value = value.isFinite ? value : GGQuickButtonsLayout.defaultSide
        return CGFloat(min(GGQuickButtonsLayout.sideRange.upperBound, max(GGQuickButtonsLayout.sideRange.lowerBound, value)).rounded())
    }

    /// The size from the settings (an imported file may hold anything).
    static func size(width: Double = InterfaceSettings.bindButtonsWidth.value, height: Double = InterfaceSettings.bindButtonsHeight.value) -> CGSize {
        return CGSize(width: GGQuickButtonsLayout.clampedSide(width), height: GGQuickButtonsLayout.clampedSide(height))
    }

    static func area(bounds: CGSize, insets: UIEdgeInsets) -> CGRect {
        let margin = GGQuickButtonsLayout.margin
        return CGRect(x: insets.left + margin, y: insets.top + margin, width: max(0.0, bounds.width - insets.left - insets.right - margin * 2.0), height: max(0.0, bounds.height - insets.top - insets.bottom - margin * 2.0))
    }

    /// A stored position, or nil for a malformed entry (it then stands in the column).
    static func position(_ value: [Double]?) -> CGPoint? {
        guard let value, value.count == 2, value[0].isFinite, value[1].isFinite else {
            return nil
        }
        return CGPoint(x: min(1.0, max(0.0, value[0])), y: min(1.0, max(0.0, value[1])))
    }

    static func center(normalized: CGPoint, area: CGRect, size: CGSize) -> CGPoint {
        let rangeX = max(0.0, area.width - size.width)
        let rangeY = max(0.0, area.height - size.height)
        return CGPoint(x: area.minX + size.width * 0.5 + min(1.0, max(0.0, normalized.x)) * rangeX, y: area.minY + size.height * 0.5 + min(1.0, max(0.0, normalized.y)) * rangeY)
    }

    static func normalized(center: CGPoint, area: CGRect, size: CGSize) -> CGPoint {
        let rangeX = area.width - size.width
        let rangeY = area.height - size.height
        let x = rangeX > 0.0 ? (center.x - area.minX - size.width * 0.5) / rangeX : 1.0
        let y = rangeY > 0.0 ? (center.y - area.minY - size.height * 0.5) / rangeY : 0.5
        return CGPoint(x: min(1.0, max(0.0, x)), y: min(1.0, max(0.0, y)))
    }

    /// The closest centre that keeps the button inside the area.
    static func clampedCenter(_ center: CGPoint, area: CGRect, size: CGSize) -> CGPoint {
        return GGQuickButtonsLayout.center(normalized: GGQuickButtonsLayout.normalized(center: center, area: area, size: size), area: area, size: size)
    }

    /// Frames of `ids` (in their order) in the bounds' coordinates: stored positions first, the rest
    /// stacked in a column on the right, centred vertically (the chat's own layout before positions).
    static func frames(ids: [String], positions: [String: [Double]], size: CGSize, bounds: CGSize, insets: UIEdgeInsets) -> [String: CGRect] {
        let area = GGQuickButtonsLayout.area(bounds: bounds, insets: insets)
        var result: [String: CGRect] = [:]
        var columnIds: [String] = []
        for id in ids {
            if let position = GGQuickButtonsLayout.position(positions[id]) {
                let center = GGQuickButtonsLayout.center(normalized: position, area: area, size: size)
                result[id] = CGRect(x: floorToScreenPixels(center.x - size.width * 0.5), y: floorToScreenPixels(center.y - size.height * 0.5), width: size.width, height: size.height)
            } else {
                columnIds.append(id)
            }
        }
        if !columnIds.isEmpty {
            let spacing = GGQuickButtonsLayout.spacing
            let totalHeight = CGFloat(columnIds.count) * size.height + CGFloat(columnIds.count - 1) * spacing
            let originY = max(area.minY, floor((area.minY + area.maxY - totalHeight) * 0.5))
            let originX = area.maxX - size.width - GGQuickButtonsLayout.columnInset
            for (index, id) in columnIds.enumerated() {
                result[id] = CGRect(x: originX, y: originY + CGFloat(index) * (size.height + spacing), width: size.width, height: size.height)
            }
        }
        GGQuickButtonsLayout.separate(&result, ids: ids, area: area)
        return result
    }

    /// Moves overlapping buttons apart vertically, keeping their order from the top: placed buttons
    /// overlap when the area got smaller (the keyboard) or the buttons bigger than when they were
    /// placed. A lower one goes down; with no room below, the upper one goes up. What still
    /// overlaps after a few passes (no room at all) stays as it is.
    private static func separate(_ frames: inout [String: CGRect], ids: [String], area: CGRect) {
        let gap: CGFloat = 4.0
        for _ in 0 ..< 4 {
            var moved = false
            let ordered = ids.filter { frames[$0] != nil }.sorted(by: { lhs, rhs in
                let lhsY = frames[lhs]?.minY ?? 0.0
                let rhsY = frames[rhs]?.minY ?? 0.0
                if lhsY != rhsY {
                    return lhsY < rhsY
                }
                return lhs < rhs
            })
            for i in 0 ..< ordered.count {
                for j in (i + 1) ..< ordered.count {
                    guard let upper = frames[ordered[i]], let lower = frames[ordered[j]], upper.intersects(lower) else {
                        continue
                    }
                    if upper.maxY + gap + lower.height <= area.maxY {
                        frames[ordered[j]] = CGRect(x: lower.minX, y: upper.maxY + gap, width: lower.width, height: lower.height)
                        moved = true
                    } else if lower.minY - gap - upper.height >= area.minY {
                        frames[ordered[i]] = CGRect(x: upper.minX, y: lower.minY - gap - upper.height, width: upper.width, height: upper.height)
                        moved = true
                    }
                }
            }
            if !moved {
                break
            }
        }
    }
}

/// One quick button as the chat draws it: a solid capsule (a circle at equal sides) with the
/// action's glyph. No blur on purpose — seven blurred backgrounds under a fill cost a frame.
final class GGQuickButtonView: UIControl {
    let actionId: String
    private let iconView = UIImageView()

    init(actionId: String) {
        self.actionId = actionId
        super.init(frame: CGRect())
        self.accessibilityIdentifier = actionId
        self.accessibilityTraits = .button
        self.isAccessibilityElement = true
        self.iconView.contentMode = .scaleAspectFit
        self.iconView.isUserInteractionEnabled = false
        self.addSubview(self.iconView)
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    func update(action: GGQuickAction, isOn: Bool, theme: PresentationTheme) {
        let background = isOn ? theme.list.itemAccentColor : theme.chat.inputPanel.panelBackgroundColor.withAlphaComponent(1.0)
        let foreground = isOn ? theme.list.itemCheckColors.foregroundColor : theme.chat.inputPanel.panelControlColor
        self.backgroundColor = background
        self.layer.borderColor = theme.chat.inputPanel.panelSeparatorColor.cgColor
        self.layer.borderWidth = UIScreenPixel
        self.iconView.image = GGQuickButtonImages.glyph(action.iconName, color: foreground)
        self.accessibilityLabel = action.title()
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        self.layer.cornerRadius = min(size.width, size.height) * 0.5
        guard let image = self.iconView.image else {
            return
        }
        // The glyph follows the smaller side: its own size at 40 pt.
        let scale = min(1.5, max(0.7, min(size.width, size.height) / CGFloat(GGQuickButtonsLayout.defaultSide)))
        let iconSize = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        self.iconView.frame = CGRect(x: floorToScreenPixels((size.width - iconSize.width) * 0.5), y: floorToScreenPixels((size.height - iconSize.height) * 0.5), width: iconSize.width, height: iconSize.height)
    }

    override var isHighlighted: Bool {
        didSet {
            self.alpha = self.isHighlighted ? 0.6 : 1.0
        }
    }
}

/// Tinted glyphs, generated once per (name, color) and shared by every chat and the editor.
enum GGQuickButtonImages {
    private static var glyphs: [String: UIImage] = [:]

    static func glyph(_ name: String, color: UIColor) -> UIImage? {
        let key = "\(name)|\(color.hashValue)"
        if let image = GGQuickButtonImages.glyphs[key] {
            return image
        }
        guard let image = generateTintedImage(image: UIImage(bundleImageName: name), color: color) else {
            return nil
        }
        GGQuickButtonImages.glyphs[key] = image
        return image
    }
}
