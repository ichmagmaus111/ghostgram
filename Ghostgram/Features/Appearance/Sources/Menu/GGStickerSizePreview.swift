import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramCore
import TelegramPresentationData
import TextFormat
import LocalizedPeerData
import WallpaperBackgroundNode
import GGCore
import GGSettingsUI
import GGAppearanceSettings

/// Preview of «Размер стикеров» (2026-11-02, the owner: like exteraGram's sticker-size cell, but our
/// own). The chat's wallpaper with an incoming big emoji and an outgoing «Призрак» sticker (drawn in
/// code, `GGGhostStickerArt`): both follow the slider while it is dragged, with the chat's cap — a
/// sticker never wider than the chat leaves room for (`GGStickerLayout.scaledSize`). Their time
/// lozenges go with «Без времени на стикерах». Under them an incoming reply to the sticker, with
/// the account's own name in its header and the chat's own bubble image (`messageBubbleImage`),
/// so the bubble editor's radii and tails apply to it too.
final class GGStickerSizePreviewView: UIView, GGMenuPreviewView {
    static let height: CGFloat = 300.0

    private static let sidePadding: CGFloat = 12.0
    private static let stickerGap: CGFloat = 8.0
    /// The sticker's side at 100 %, of the preview's width (180 pt of a 393 pt chat, scaled down).
    private static let stickerWidthFraction: CGFloat = 0.34
    /// A big emoji is drawn smaller than a sticker of the same scale, as in the chat.
    private static let emojiFraction: CGFloat = 0.62
    private static let emoji = "😂"

    private let wallpaperContainer = UIView()
    private var wallpaperNode: WallpaperBackgroundNode?
    private let emojiView = UIImageView()
    private let stickerView = UIImageView()
    private let emojiTimeView = UIImageView()
    private let stickerTimeView = UIImageView()
    private let bubbleView = UIImageView()
    private let replyBackgroundView = UIView()
    private let replyBarView = UIView()
    private let replyNameLabel = UILabel()
    private let replySnippetLabel = UILabel()
    private let textLabel = UILabel()
    private let timeLabel = UILabel()

    private var scale: CGFloat = 1.0
    private var hidesTime = false
    private var presentationData: PresentationData?
    private var accountName: String?
    private var stickerImageSide: CGFloat = 0.0
    private var lastLayoutSize: CGSize?

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.clipsToBounds = true
        self.isUserInteractionEnabled = false

        self.wallpaperContainer.clipsToBounds = true
        self.addSubview(self.wallpaperContainer)

        for imageView in [self.emojiView, self.stickerView] {
            imageView.contentMode = .scaleAspectFit
            // One image drawn at the largest size, shrunk by the view: mipmaps keep it smooth.
            imageView.layer.minificationFilter = .trilinear
            self.addSubview(imageView)
        }
        self.addSubview(self.emojiTimeView)
        self.addSubview(self.stickerTimeView)

        self.addSubview(self.bubbleView)
        self.replyBackgroundView.layer.cornerRadius = 4.0
        self.replyBackgroundView.clipsToBounds = true
        self.addSubview(self.replyBackgroundView)
        self.replyBarView.layer.cornerRadius = 1.5
        self.replyBackgroundView.addSubview(self.replyBarView)
        for label in [self.replyNameLabel, self.replySnippetLabel, self.timeLabel] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        self.textLabel.numberOfLines = 2
        self.replyBackgroundView.addSubview(self.replyNameLabel)
        self.replyBackgroundView.addSubview(self.replySnippetLabel)
        self.addSubview(self.textLabel)
        self.addSubview(self.timeLabel)

        self.emojiView.image = GGStickerSizePreviewView.renderEmoji(GGStickerSizePreviewView.emoji)
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    func update(context: GGMenuContext) {
        let value = context.displayValue(.global(GGAppearanceSettings.stickerSize))
        self.scale = CGFloat(min(2.0, max(0.5, value / 100.0)))
        self.hidesTime = GGAppearanceSettings.stickerHideTime.value
        self.accountName = context.accountPeer?.compactDisplayTitle

        let presentationData = context.presentationData
        let themeChanged = self.presentationData?.theme !== presentationData.theme || self.presentationData?.chatWallpaper != presentationData.chatWallpaper || self.presentationData?.chatBubbleCorners != presentationData.chatBubbleCorners
        self.presentationData = presentationData

        if self.wallpaperNode == nil {
            let wallpaperNode = createWallpaperBackgroundNode(context: context.context, forChatDisplay: false)
            self.wallpaperContainer.addSubview(wallpaperNode.view)
            self.wallpaperNode = wallpaperNode
        }
        if themeChanged {
            self.wallpaperNode?.update(wallpaper: presentationData.chatWallpaper, animated: false)
            self.wallpaperNode?.updateBubbleTheme(bubbleTheme: presentationData.theme, bubbleCorners: presentationData.chatBubbleCorners)
            self.lastLayoutSize = nil
        }

        self.applyContent(presentationData: presentationData)
        self.setNeedsLayout()
        // Slider ticks: the stickers follow the finger in the same frame.
        self.layoutIfNeeded()
    }

    /// Texts, colors and the theme's images. Cheap enough to redo on every tick: the bubble image is
    /// the chat's 43×37 template, and the bubble editor's sliders change it without a theme change.
    private func applyContent(presentationData: PresentationData) {
        let theme = presentationData.theme
        let incoming = theme.chat.message.incoming
        let fontSize = presentationData.chatFontSize.baseDisplaySize
        let smallFontSize = floor(fontSize * 14.0 / 17.0)
        let timeFontSize = floor(fontSize * 11.0 / 17.0)
        let now = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)

        self.bubbleView.image = messageBubbleImage(maxCornerRadius: presentationData.chatBubbleCorners.mainRadius, minCornerRadius: presentationData.chatBubbleCorners.auxiliaryRadius, incoming: true, fillColor: incoming.bubble.withWallpaper.fill.first ?? .white, strokeColor: incoming.bubble.withWallpaper.stroke, neighbors: .none, theme: theme.chat, wallpaper: presentationData.chatWallpaper, knockout: false)

        self.replyBackgroundView.backgroundColor = incoming.accentTextColor.withAlphaComponent(0.1)
        self.replyBarView.backgroundColor = incoming.accentTextColor
        self.replyNameLabel.font = Font.semibold(smallFontSize)
        self.replyNameLabel.textColor = incoming.accentTextColor
        self.replyNameLabel.text = self.accountName ?? presentationData.strings.DialogList_You
        self.replySnippetLabel.font = Font.regular(smallFontSize)
        self.replySnippetLabel.textColor = incoming.primaryTextColor
        self.replySnippetLabel.text = "👻 " + presentationData.strings.Message_Sticker
        self.textLabel.font = Font.regular(fontSize)
        self.textLabel.textColor = incoming.primaryTextColor
        self.textLabel.text = GGStrings.Appearance.Stickers.previewReply
        self.timeLabel.font = Font.regular(timeFontSize)
        self.timeLabel.textColor = incoming.secondaryTextColor
        self.timeLabel.text = GGStickerSizePreviewView.timeString(timestamp: now - 60, presentationData: presentationData)

        let serviceColors = serviceMessageColorComponents(theme: theme, wallpaper: presentationData.chatWallpaper)
        let fillColor = selectDateFillStaticColor(theme: theme, wallpaper: presentationData.chatWallpaper)
        self.emojiTimeView.image = GGStickerSizePreviewView.timeLozenge(text: GGStickerSizePreviewView.timeString(timestamp: now - 180, presentationData: presentationData), fontSize: timeFontSize, textColor: serviceColors.primaryText, fillColor: fillColor, outgoing: false)
        self.stickerTimeView.image = GGStickerSizePreviewView.timeLozenge(text: GGStickerSizePreviewView.timeString(timestamp: now - 120, presentationData: presentationData), fontSize: timeFontSize, textColor: serviceColors.primaryText, fillColor: fillColor, outgoing: true)
        self.emojiTimeView.isHidden = self.hidesTime
        self.stickerTimeView.isHidden = self.hidesTime
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let size = self.bounds.size
        guard size.width > 1.0, size.height > 1.0, self.presentationData != nil else {
            return
        }
        let padding = GGStickerSizePreviewView.sidePadding

        self.wallpaperContainer.frame = self.bounds
        if let wallpaperNode = self.wallpaperNode, self.lastLayoutSize != size {
            self.lastLayoutSize = size
            // Taller than the block, as the mini chat lays it out, so the pattern has the chat's scale.
            let wallpaperFrame = CGRect(x: 0.0, y: -100.0, width: size.width, height: size.height + 200.0)
            wallpaperNode.frame = wallpaperFrame
            wallpaperNode.updateLayout(size: wallpaperFrame.size, displayMode: .aspectFill, transition: .immediate)
        }

        // The reply bubble rests on the bottom edge.
        let tailWidth: CGFloat = 6.0
        let bubbleTextInset: CGFloat = 11.0
        let maxBubbleWidth = floor(min(size.width * 0.8, size.width - 2.0 * padding - tailWidth))
        let maxContentWidth = maxBubbleWidth - 2.0 * bubbleTextInset

        let replyInset: CGFloat = 10.0
        let nameSize = self.replyNameLabel.sizeThatFits(CGSize(width: maxContentWidth - replyInset - 6.0, height: .greatestFiniteMagnitude))
        let snippetSize = self.replySnippetLabel.sizeThatFits(CGSize(width: maxContentWidth - replyInset - 6.0, height: .greatestFiniteMagnitude))
        let replyWidth = min(maxContentWidth, ceil(max(nameSize.width, snippetSize.width)) + replyInset + 6.0)
        let replyHeight = ceil(nameSize.height + snippetSize.height) + 6.0

        let timeSize = self.timeLabel.sizeThatFits(CGSize(width: maxContentWidth, height: .greatestFiniteMagnitude))
        let timeSpacing: CGFloat = 8.0
        let lineHeight = self.textLabel.font.lineHeight
        // One line leaves the time beside the text, as in the chat; two put it under the text.
        var textSize = self.textLabel.sizeThatFits(CGSize(width: maxContentWidth - timeSpacing - timeSize.width, height: .greatestFiniteMagnitude))
        let timeInline = textSize.height < lineHeight * 1.5
        if !timeInline {
            textSize = self.textLabel.sizeThatFits(CGSize(width: maxContentWidth, height: .greatestFiniteMagnitude))
        }
        textSize = CGSize(width: min(maxContentWidth, ceil(textSize.width)), height: ceil(textSize.height))

        var contentWidth = max(replyWidth, textSize.width)
        var contentHeight = replyHeight + 5.0 + textSize.height
        if timeInline {
            contentWidth = max(contentWidth, textSize.width + timeSpacing + ceil(timeSize.width))
        } else {
            contentWidth = max(contentWidth, ceil(timeSize.width))
            contentHeight += ceil(timeSize.height)
        }
        let bubbleTopInset: CGFloat = 7.0
        let bubbleBottomInset: CGFloat = 6.0
        let bodySize = CGSize(width: contentWidth + 2.0 * bubbleTextInset, height: contentHeight + bubbleTopInset + bubbleBottomInset)
        let bodyFrame = CGRect(x: padding + tailWidth, y: size.height - padding - bodySize.height, width: bodySize.width, height: bodySize.height)
        // The image carries the tail on the left and a 2 pt edge for the stroke and the shadow.
        self.bubbleView.frame = CGRect(x: bodyFrame.minX - tailWidth - 2.0, y: bodyFrame.minY - 2.0, width: bodyFrame.width + tailWidth + 4.0, height: bodyFrame.height + 4.0)

        let replyFrame = CGRect(x: bodyFrame.minX + bubbleTextInset - 2.0, y: bodyFrame.minY + bubbleTopInset, width: replyWidth, height: replyHeight)
        self.replyBackgroundView.frame = replyFrame
        self.replyBarView.frame = CGRect(x: 0.0, y: 0.0, width: 3.0, height: replyHeight)
        self.replyNameLabel.frame = CGRect(x: replyInset, y: 3.0, width: replyWidth - replyInset - 6.0, height: ceil(nameSize.height))
        self.replySnippetLabel.frame = CGRect(x: replyInset, y: 3.0 + ceil(nameSize.height), width: replyWidth - replyInset - 6.0, height: ceil(snippetSize.height))

        let textFrame = CGRect(x: bodyFrame.minX + bubbleTextInset, y: replyFrame.maxY + 5.0, width: textSize.width, height: textSize.height)
        self.textLabel.frame = textFrame
        let timeY = timeInline ? textFrame.maxY - ceil(timeSize.height) : textFrame.maxY
        self.timeLabel.frame = CGRect(x: bodyFrame.maxX - bubbleTextInset - ceil(timeSize.width), y: timeY, width: ceil(timeSize.width), height: ceil(timeSize.height))

        // The stickers stand on the bubble, side by side: the emoji on the left (incoming), the
        // sticker on the right (outgoing). Capped by the width they share and by the height above
        // the bubble, so the largest setting stops where the chat's cap would.
        let stickersBottom = bodyFrame.minY - GGStickerSizePreviewView.stickerGap
        let widthCap = (size.width - 3.0 * padding) / (1.0 + GGStickerSizePreviewView.emojiFraction)
        let heightCap = stickersBottom - padding
        let stickerSide = floor(max(24.0, min(size.width * GGStickerSizePreviewView.stickerWidthFraction * self.scale, widthCap, heightCap)))
        let emojiSide = floor(stickerSide * GGStickerSizePreviewView.emojiFraction)

        let stickerFrame = CGRect(x: size.width - padding - stickerSide, y: stickersBottom - stickerSide, width: stickerSide, height: stickerSide)
        let emojiFrame = CGRect(x: padding, y: stickersBottom - emojiSide, width: emojiSide, height: emojiSide)

        // Drawn once at the largest side the preview can show, then only shrunk.
        let largestSide = ceil(max(widthCap, 24.0))
        if self.stickerView.image == nil || abs(self.stickerImageSide - largestSide) > 1.0 {
            self.stickerImageSide = largestSide
            self.stickerView.image = GGGhostStickerArt.image(side: largestSide)
        }
        self.stickerView.frame = stickerFrame
        self.emojiView.frame = emojiFrame

        if let image = self.stickerTimeView.image {
            self.stickerTimeView.frame = CGRect(x: stickerFrame.maxX - image.size.width, y: stickerFrame.maxY - image.size.height, width: image.size.width, height: image.size.height)
        }
        if let image = self.emojiTimeView.image {
            self.emojiTimeView.frame = CGRect(x: emojiFrame.maxX - image.size.width + 6.0, y: emojiFrame.maxY - image.size.height, width: image.size.width, height: image.size.height)
        }
    }

    private static func timeString(timestamp: Int32, presentationData: PresentationData) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(timestamp)))
        return stringForShortTimestamp(hours: Int32(components.hour ?? 0), minutes: Int32(components.minute ?? 0), dateTimeFormat: presentationData.dateTimeFormat)
    }

    /// The chat's free-floating date (stickers, big emoji): a capsule on the wallpaper's date fill,
    /// with the two read checks of an outgoing message.
    private static func timeLozenge(text: String, fontSize: CGFloat, textColor: UIColor, fillColor: UIColor, outgoing: Bool) -> UIImage? {
        let attributed = NSAttributedString(string: text, attributes: [.font: Font.regular(fontSize), .foregroundColor: textColor])
        let textSize = attributed.boundingRect(with: CGSize(width: 200.0, height: 40.0), options: .usesLineFragmentOrigin, context: nil).size
        let checksWidth: CGFloat = outgoing ? 15.0 : 0.0
        let size = CGSize(width: ceil(textSize.width) + checksWidth + 14.0, height: max(18.0, ceil(textSize.height) + 4.0))
        return generateImage(size, rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(fillColor.cgColor)
            context.addPath(UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: size), cornerRadius: size.height / 2.0).cgPath)
            context.fillPath()
            UIGraphicsPushContext(context)
            attributed.draw(at: CGPoint(x: 7.0, y: floorToScreenPixels((size.height - textSize.height) / 2.0)))
            UIGraphicsPopContext()
            if outgoing {
                context.setStrokeColor(textColor.cgColor)
                context.setLineWidth(1.2)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                let origin = CGPoint(x: 7.0 + ceil(textSize.width) + 3.0, y: size.height / 2.0)
                context.move(to: CGPoint(x: origin.x, y: origin.y + 0.5))
                context.addLine(to: CGPoint(x: origin.x + 2.0, y: origin.y + 2.5))
                context.addLine(to: CGPoint(x: origin.x + 6.5, y: origin.y - 2.5))
                context.strokePath()
                context.move(to: CGPoint(x: origin.x + 4.5, y: origin.y + 2.5))
                context.addLine(to: CGPoint(x: origin.x + 9.0, y: origin.y - 2.5))
                context.strokePath()
            }
        })
    }

    /// The emoji as a picture (the system's color glyph at a large size), trimmed to its glyph box.
    private static func renderEmoji(_ emoji: String) -> UIImage? {
        let attributed = NSAttributedString(string: emoji, attributes: [.font: UIFont.systemFont(ofSize: 160.0)])
        let textSize = attributed.size()
        guard textSize.width > 0.0, textSize.height > 0.0 else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: ceil(textSize.width), height: ceil(textSize.height)), format: format).image { _ in
            attributed.draw(at: CGPoint())
        }
    }
}

/// «Призрак» — the preview's own sticker: a waving ghost with a die-cut white edge and a soft shadow,
/// drawn in a 100×100 space so it stays sharp at any size.
enum GGGhostStickerArt {
    static func image(side: CGFloat) -> UIImage {
        // Drawn in pixels (scale 1): a shadow's offset and blur ignore the context's scale, so in a
        // points context they would come out a third as wide on a 3x screen.
        let screenScale = max(1.0, UIScreenScale)
        let pixelSide = ceil(side * screenScale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: pixelSide, height: pixelSide), format: format).image { rendererContext in
            let context = rendererContext.cgContext
            let unit = pixelSide / 100.0
            context.scaleBy(x: unit, y: unit)
            // A slight tilt, smaller than the square so the edge and the shadow stay inside.
            context.translateBy(x: 50.0, y: 52.0)
            context.rotate(by: -0.12)
            context.scaleBy(x: 0.9, y: 0.9)
            context.translateBy(x: -50.0, y: -52.0)

            let ink = UIColor(rgb: 0x2b2a3d)
            let body = GGGhostStickerArt.bodyPath()
            let rightArm = GGGhostStickerArt.ellipse(center: CGPoint(x: 87.0, y: 49.0), size: CGSize(width: 18.0, height: 11.0), angle: -0.6)
            let leftArm = GGGhostStickerArt.ellipse(center: CGPoint(x: 15.0, y: 61.0), size: CGSize(width: 13.0, height: 9.0), angle: 0.5)

            // 1. The die-cut edge with its shadow, one silhouette for the whole ghost.
            context.saveGState()
            // Base space is y-up: a negative height puts the shadow under the ghost (as in Telegram's bubbles).
            context.setShadow(offset: CGSize(width: 0.0, height: -1.5 * unit), blur: 3.5 * unit, color: UIColor(white: 0.0, alpha: 0.3).cgColor)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setFillColor(UIColor.white.cgColor)
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(9.0)
            context.setLineJoin(.round)
            for path in [leftArm, rightArm, body] {
                context.addPath(path)
                context.drawPath(using: .fillStroke)
            }
            context.endTransparencyLayer()
            context.restoreGState()

            context.setLineJoin(.round)
            context.setLineCap(.round)

            // 2. The arms behind the body.
            for arm in [leftArm, rightArm] {
                context.addPath(arm)
                context.setFillColor(UIColor(rgb: 0xf1f0ff).cgColor)
                context.fillPath()
                context.addPath(arm)
                context.setStrokeColor(ink.cgColor)
                context.setLineWidth(2.6)
                context.strokePath()
            }

            // 3. The body: white at the top, a cold lavender towards the hem.
            context.saveGState()
            context.addPath(body)
            context.clip()
            let colors = [UIColor.white.cgColor, UIColor(rgb: 0xe4e1ff).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.35, 1.0]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 50.0, y: 12.0), end: CGPoint(x: 50.0, y: 92.0), options: [])
            }
            context.restoreGState()
            context.addPath(body)
            context.setStrokeColor(ink.cgColor)
            context.setLineWidth(2.6)
            context.strokePath()

            // 4. The face: eyes with highlights, cheeks, an open smile.
            context.setFillColor(ink.cgColor)
            context.fillEllipse(in: CGRect(x: 35.0, y: 39.0, width: 9.0, height: 12.0))
            context.fillEllipse(in: CGRect(x: 56.0, y: 39.0, width: 9.0, height: 12.0))
            context.setFillColor(UIColor.white.cgColor)
            context.fillEllipse(in: CGRect(x: 36.2, y: 40.6, width: 3.6, height: 3.6))
            context.fillEllipse(in: CGRect(x: 57.2, y: 40.6, width: 3.6, height: 3.6))
            context.fillEllipse(in: CGRect(x: 40.4, y: 47.0, width: 1.8, height: 1.8))
            context.fillEllipse(in: CGRect(x: 61.4, y: 47.0, width: 1.8, height: 1.8))

            context.setFillColor(UIColor(rgb: 0xff7fa5).withAlphaComponent(0.55).cgColor)
            context.fillEllipse(in: CGRect(x: 25.5, y: 53.5, width: 9.0, height: 5.0))
            context.fillEllipse(in: CGRect(x: 65.5, y: 53.5, width: 9.0, height: 5.0))

            let mouth = CGMutablePath()
            mouth.move(to: CGPoint(x: 44.5, y: 55.0))
            mouth.addQuadCurve(to: CGPoint(x: 55.5, y: 55.0), control: CGPoint(x: 50.0, y: 66.0))
            mouth.closeSubpath()
            context.addPath(mouth)
            context.setFillColor(ink.cgColor)
            context.fillPath()
            context.saveGState()
            context.addPath(mouth)
            context.clip()
            context.setFillColor(UIColor(rgb: 0xff6b8e).cgColor)
            context.fillEllipse(in: CGRect(x: 46.5, y: 57.5, width: 7.0, height: 6.0))
            context.restoreGState()
        }
        guard let cgImage = image.cgImage else {
            return image
        }
        return UIImage(cgImage: cgImage, scale: screenScale, orientation: .up)
    }

    /// A dome, sides that widen a little, and a hem of four rounded lobes.
    private static func bodyPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 17.0, y: 84.0))
        path.addLine(to: CGPoint(x: 20.0, y: 42.0))
        path.addArc(center: CGPoint(x: 50.0, y: 42.0), radius: 30.0, startAngle: .pi, endAngle: 0.0, clockwise: false)
        path.addLine(to: CGPoint(x: 83.0, y: 84.0))
        var x: CGFloat = 83.0
        let lobeWidth: CGFloat = 16.5
        for _ in 0 ..< 4 {
            let next = x - lobeWidth
            path.addQuadCurve(to: CGPoint(x: next, y: 84.0), control: CGPoint(x: (x + next) / 2.0, y: 98.0))
            x = next
        }
        path.closeSubpath()
        return path
    }

    private static func ellipse(center: CGPoint, size: CGSize, angle: CGFloat) -> CGPath {
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
        return CGPath(ellipseIn: CGRect(x: -size.width / 2.0, y: -size.height / 2.0, width: size.width, height: size.height), transform: &transform)
    }
}
