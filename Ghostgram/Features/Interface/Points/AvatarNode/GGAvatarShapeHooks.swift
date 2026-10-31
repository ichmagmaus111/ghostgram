// Compiled into AvatarNode (filegroup //Ghostgram/Features/Interface:AvatarNodePointSources).
// Owner: W2-5 (square avatars). One shape for every avatar the app draws: the clip style is
// resolved once where an avatar is set, the rounded-rect radius comes from one function.

import Foundation
import UIKit
import GGCore

/// How avatars are clipped. `.upstream` = Telegram's circles and 25 % forum corners.
public struct GGAvatarShape: Equatable {
    /// Avatars Telegram draws as circles become rounded squares.
    public var squareAvatars: Bool
    /// Corner radius of a rounded square as a fraction of its side (0.12 … 0.5).
    public var cornerFraction: CGFloat
    /// Forums (Telegram's rounded rects) are drawn as circles, whatever shape the other avatars have.
    public var roundForums: Bool

    public init(squareAvatars: Bool, cornerFraction: CGFloat, roundForums: Bool) {
        self.squareAvatars = squareAvatars
        self.cornerFraction = cornerFraction
        self.roundForums = roundForums
    }

    public static let upstream = GGAvatarShape(squareAvatars: false, cornerFraction: 0.25, roundForums: false)
}

public enum GGAvatarHooks {
    /// Provider of the shape (first registered wins). Asked for every avatar that is set or
    /// drawn: answer from a snapshot, never compute.
    public static let shape = GGHookPoint<() -> GGAvatarShape>("avatar.shape")

    public static func currentShape() -> GGAvatarShape {
        if GGAvatarHooks.shape.isEmpty {
            return .upstream
        }
        return GGAvatarHooks.shape.handlers[0]()
    }
}

/// The clip style an avatar is actually drawn with. Public for avatars drawn outside AvatarNode
/// (the «Настройки» tab icon, the photo being uploaded in «Изменить»); apply it once per draw.
public func ggAvatarClipStyle(_ clipStyle: AvatarNodeClipStyle) -> AvatarNodeClipStyle {
    if GGAvatarHooks.shape.isEmpty {
        return clipStyle
    }
    let shape = GGAvatarHooks.currentShape()
    switch clipStyle {
    case .round:
        return shape.squareAvatars ? .roundedRect : .round
    case .roundedRect:
        // «Круглые в форумах»: circles instead of the rounded square, with round and with square
        // avatars alike (the old client's meaning; before, the switch did nothing while it was shown
        // and acted while it was hidden).
        return shape.roundForums ? .round : .roundedRect
    case .none, .bubble:
        return clipStyle
    }
}

/// What a drawn avatar depends on besides its clip style: the corner of a rounded square (only
/// while square avatars are on; 0 otherwise). The avatar node compares it with what it drew, so a
/// change of «Скругление углов» between two square levels (the clip style stays `.roundedRect`)
/// redraws the avatars already on screen.
func ggAvatarShapeRevision() -> CGFloat {
    if GGAvatarHooks.shape.isEmpty {
        return 0.0
    }
    let shape = GGAvatarHooks.currentShape()
    return shape.squareAvatars ? shape.cornerFraction : 0.0
}

/// Corner radius of a `.roundedRect` avatar of the given side; `upstream` is what Telegram
/// computes at the call site (kept exactly when square avatars are off).
public func ggAvatarRoundedRectRadius(_ side: CGFloat, upstream: CGFloat) -> CGFloat {
    if GGAvatarHooks.shape.isEmpty {
        return upstream
    }
    let shape = GGAvatarHooks.currentShape()
    if shape.squareAvatars {
        return min(floor(side * 0.5), ceil(side * shape.cornerFraction))
    }
    return upstream
}

/// Corner radius fraction of a rounded-rect story ring around an avatar (Telegram: 0.27).
public func ggAvatarRingCornerFraction() -> CGFloat {
    if GGAvatarHooks.shape.isEmpty {
        return 0.27
    }
    let shape = GGAvatarHooks.currentShape()
    if shape.squareAvatars {
        // The ring sits a few points outside the image: a slightly larger fraction keeps the
        // gap even along the corners.
        return min(0.5, shape.cornerFraction + 0.02)
    }
    return 0.27
}

/// The ring around an avatar as a rounded square with the avatar's corner fraction, or nil when
/// avatars are round (callers then draw Telegram's circles). One path for every story ring.
public func ggAvatarRingPath(center: CGPoint, radius: CGFloat) -> CGPath? {
    if GGAvatarHooks.shape.isEmpty {
        return nil
    }
    let shape = GGAvatarHooks.currentShape()
    if !shape.squareAvatars {
        return nil
    }
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2.0, height: radius * 2.0)
    let cornerRadius = min(radius, ceil(radius * 2.0 * ggAvatarRingCornerFraction()))
    return CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
}

/// The ring of `ggAvatarRingPath` drawn from the top centre clockwise, with its length and corner —
/// for progress rings (upload, story loading): they fill and dash along a rounded square instead of
/// rotating a circle. nil while avatars are round.
public func ggAvatarRingPathFromTop(center: CGPoint, radius: CGFloat) -> (path: CGPath, length: CGFloat, cornerRadius: CGFloat)? {
    if GGAvatarHooks.shape.isEmpty || !GGAvatarHooks.currentShape().squareAvatars {
        return nil
    }
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2.0, height: radius * 2.0)
    let cornerRadius = min(radius, ceil(radius * 2.0 * ggAvatarRingCornerFraction()))
    return (ggRoundedSquarePathFromTop(rect, cornerRadius: cornerRadius), ggRoundedSquareLength(side: rect.width, cornerRadius: cornerRadius), cornerRadius)
}

/// A rounded square that starts at the middle of its top edge and goes clockwise on screen.
public func ggRoundedSquarePathFromTop(_ rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
    path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: cornerRadius)
    path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: cornerRadius)
    path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: cornerRadius)
    path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.midX, y: rect.minY), radius: cornerRadius)
    path.closeSubpath()
    return path
}

/// Perimeter of a rounded square: four straight runs and one full circle of the corners.
public func ggRoundedSquareLength(side: CGFloat, cornerRadius: CGFloat) -> CGFloat {
    return 4.0 * max(0.0, side - cornerRadius * 2.0) + 2.0 * CGFloat.pi * cornerRadius
}

/// The avatar's own clip as a path (masks around avatars), or nil for circles.
public func ggAvatarClipPath(in rect: CGRect) -> CGPath? {
    if GGAvatarHooks.shape.isEmpty {
        return nil
    }
    let shape = GGAvatarHooks.currentShape()
    if !shape.squareAvatars {
        return nil
    }
    let cornerRadius = min(floor(min(rect.width, rect.height) * 0.5), ceil(rect.width * shape.cornerFraction))
    return CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
}

/// Corner radius of an avatar whose clipping is drawn outside AvatarNode (the profile header):
/// `upstream` is Telegram's value (a circle, or 25 % for forums).
public func ggAvatarCornerRadius(side: CGFloat, isForum: Bool, upstream: CGFloat) -> CGFloat {
    if GGAvatarHooks.shape.isEmpty {
        return upstream
    }
    switch ggAvatarClipStyle(isForum ? .roundedRect : .round) {
    case .round:
        return side * 0.5
    case .roundedRect:
        return ggAvatarRoundedRectRadius(side, upstream: floor(side * 0.25))
    case .none, .bubble:
        return upstream
    }
}

/// Fills an avatar-shaped area: Telegram's circle, or the rounded square of square avatars.
public func ggAvatarFillShape(_ context: CGContext, in rect: CGRect) {
    if let path = ggAvatarClipPath(in: rect) {
        context.addPath(path)
        context.fillPath()
    } else {
        context.fillEllipse(in: rect)
    }
}
