// Compiled into Display (filegroup //Ghostgram/GGHooks:DisplayHookSources).
// The glass behind a navigation bar's buttons is a capsule (NavigationBarComponent). A button that is
// not round — the chat's avatar or the account button with square avatars — answers its own corner
// radius, so the glass stays concentric with it. Display has no Ghostgram settings: the button decides.
//
// The shape holds everywhere the bar draws that glass: its layout, its in-place animations (the shape is
// kept on the capsule's glass container), push and pop (the transition draws copies of the glass, shaped
// from the items they carry) and the expansion into a profile (the chat avatar's glass circle).

import Foundation
import UIKit
import AsyncDisplayKit

public protocol GGNavigationButtonGlassShape: AnyObject {
    /// Corner radius of the glass of the given height around this button alone, or nil for
    /// Telegram's capsule.
    func ggGlassCornerRadius(height: CGFloat) -> CGFloat?
}

private var ggNavigationGlassShapeKey: UInt8 = 0

/// Corner radius of the capsule holding the buttons under `view`: Telegram's half height, or the
/// smallest answer of a visible shaped button inside (a view or a node's view, a few levels deep).
/// `view` itself counts whatever its alpha (a transition fades it in).
public func ggNavigationButtonGlassCornerRadius(in view: UIView, height: CGFloat) -> CGFloat {
    var result = height * 0.5
    func visit(_ view: UIView, depth: Int) {
        if view.isHidden || (depth > 0 && view.alpha.isZero) {
            return
        }
        if let shape = (view as? GGNavigationButtonGlassShape) ?? (view.asyncdisplaykit_node as? GGNavigationButtonGlassShape), let radius = shape.ggGlassCornerRadius(height: height) {
            result = min(result, radius)
        }
        if depth < 4 {
            for subview in view.subviews {
                visit(subview, depth: depth + 1)
            }
        }
    }
    visit(view, depth: 0)
    return max(0.0, result)
}

/// Lays out the shape of a capsule's glass `container` from the buttons under `items`, keeps it on the
/// container for its animations (`ggNavigationGlassCornerRadius`) and returns the radius at `height`.
public func ggUpdateNavigationGlassShape(_ container: UIView, items: UIView, height: CGFloat) -> CGFloat {
    let radius = ggNavigationButtonGlassCornerRadius(in: items, height: height)
    let fraction: NSNumber? = (height > 0.0 && radius < height * 0.5 - 0.01) ? NSNumber(value: Double(radius / height)) : nil
    objc_setAssociatedObject(container, &ggNavigationGlassShapeKey, fraction, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return radius
}

/// The corner radius of the capsule glass `container` at `size`: the shape it keeps (its radius over its
/// height, applied to the shorter side), or `upstream` when it has none.
public func ggNavigationGlassCornerRadius(_ container: UIView?, size: CGSize, upstream: CGFloat) -> CGFloat {
    guard let container, let fraction = objc_getAssociatedObject(container, &ggNavigationGlassShapeKey) as? NSNumber else {
        return upstream
    }
    return min(upstream, max(0.0, min(size.width, size.height)) * CGFloat(fraction.doubleValue))
}

/// The corner radii of a capsule copy morphing through `sizes` (push / pop): the shape of each set of
/// items it carries (`ggNavigationButtonGlassCornerRadius` over the items' height), weighted at every
/// sample by how present they are (1 = shown, 0 = gone). nil when none is shaped: Telegram's capsule.
public func ggNavigationGlassCornerRadii(sizes: [CGSize], items: [(view: UIView, height: CGFloat, presence: [CGFloat])]) -> [CGFloat]? {
    var fractions: [CGFloat] = []
    var isShaped = false
    for item in items {
        let fraction: CGFloat
        if item.height > 0.0 {
            fraction = min(0.5, ggNavigationButtonGlassCornerRadius(in: item.view, height: item.height) / item.height)
        } else {
            fraction = 0.5
        }
        if fraction < 0.5 - 0.001 {
            isShaped = true
        }
        fractions.append(fraction)
    }
    if !isShaped {
        return nil
    }
    return sizes.indices.map { index -> CGFloat in
        var weighted: CGFloat = 0.0
        var total: CGFloat = 0.0
        for (itemIndex, item) in items.enumerated() where index < item.presence.count {
            let weight = max(0.0, min(1.0, item.presence[index]))
            weighted += fractions[itemIndex] * weight
            total += weight
        }
        let fraction = total > 0.001 ? weighted / total : (fractions.min() ?? 0.5)
        let size = sizes[index]
        return max(0.0, min(size.width, size.height)) * fraction
    }
}

/// The shape of the glass circle around a shaped button that `view` belongs to (the chat's avatar riding
/// into a profile): its radius over its side, looked up in `view` and a few of its superviews; nil = a circle.
public func ggNavigationGlassCornerFraction(around view: UIView?, side: CGFloat) -> CGFloat? {
    guard side > 0.0 else {
        return nil
    }
    var current = view
    var depth = 0
    while let candidate = current, depth < 5 {
        if let shape = (candidate as? GGNavigationButtonGlassShape) ?? (candidate.asyncdisplaykit_node as? GGNavigationButtonGlassShape) {
            guard let radius = shape.ggGlassCornerRadius(height: side), radius < side * 0.5 - 0.01 else {
                return nil
            }
            return max(0.0, radius / side)
        }
        current = candidate.superview
        depth += 1
    }
    return nil
}
