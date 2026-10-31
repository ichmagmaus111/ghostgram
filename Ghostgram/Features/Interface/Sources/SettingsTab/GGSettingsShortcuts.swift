import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import AvatarNode
import GGCore

/// Website shortcuts: URL normalization.
enum GGSiteShortcut {
    /// "example.com/path" → "https://example.com/path"; only http(s) with a dotted host.
    static func normalizedURL(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return nil
        }
        let lowercased = text.lowercased()
        if !lowercased.hasPrefix("http://") && !lowercased.hasPrefix("https://") {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = components.host?.lowercased(), host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else {
            return nil
        }
        var result = "\(scheme)://\(host)"
        if let port = components.port {
            result += ":\(port)"
        }
        if components.path != "/" {
            result += components.path
        }
        if let query = components.query, !query.isEmpty {
            result += "?\(query)"
        }
        return result
    }

    static func host(of url: String) -> String? {
        return URLComponents(string: url)?.host?.lowercased()
    }

    /// The host without `www.` (default title, monogram letter).
    static func displayHost(of url: String) -> String {
        guard let host = GGSiteShortcut.host(of: url) else {
            return url
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Site icons for shortcuts: fetched from the site itself (`/favicon.ico`, then
/// `/apple-touch-icon.png`) through GGNetwork — the user's proxy, no cookies, no third party.
/// A monogram is shown until (or instead of) the icon. Successes are kept on disk; failures are
/// remembered for a week so a site without an icon is not asked again on every rebuild.
final class GGFaviconStore {
    static let shared = GGFaviconStore()

    private static let failureLifetime: Double = 7.0 * 24.0 * 60.0 * 60.0
    private let images = Atomic<[String: UIImage]>(value: [:])
    private let inFlight = Atomic<[String: Promise<UIImage?>]>(value: [:])

    private init() {
    }

    private var directory: String? {
        return ggInterfaceDirectory("favicons")
    }

    /// The icon of a site: the monogram first, then the real icon if it can be had.
    func icon(url: String, size: CGFloat) -> Signal<UIImage?, NoError> {
        guard let host = GGSiteShortcut.host(of: url) else {
            return .single(nil)
        }
        let monogram = GGFaviconStore.monogram(for: GGSiteShortcut.displayHost(of: url), size: size)
        if let cached = self.images.with({ $0[host] }) {
            return .single(GGFaviconStore.tile(cached, size: size))
        }
        var created = false
        let promise = self.inFlight.modify { current -> [String: Promise<UIImage?>] in
            if current[host] != nil {
                return current
            }
            created = true
            var updated = current
            updated[host] = Promise<UIImage?>()
            return updated
        }[host]!
        if created {
            self.start(host: host, promise: promise)
        }
        return .single(monogram)
        |> then(promise.get()
        |> take(1)
        |> map { image -> UIImage? in
            guard let image else {
                return monogram
            }
            return GGFaviconStore.tile(image, size: size)
        })
    }

    private func start(host: String, promise: Promise<UIImage?>) {
        let directory = self.directory
        let images = self.images
        promise.set(Signal<UIImage?, NoError> { subscriber in
            // Disk first.
            if let directory {
                let path = (directory as NSString).appendingPathComponent(host + ".png")
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let image = UIImage(data: data) {
                    let _ = images.modify { current in
                        var updated = current
                        updated[host] = image
                        return updated
                    }
                    subscriber.putNext(image)
                    subscriber.putCompletion()
                    return EmptyDisposable
                }
                let failurePath = (directory as NSString).appendingPathComponent(host + ".none")
                if let attributes = try? FileManager.default.attributesOfItem(atPath: failurePath), let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < GGFaviconStore.failureLifetime {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return EmptyDisposable
                }
            }
            let candidates = ["https://\(host)/favicon.ico", "https://\(host)/apple-touch-icon.png"].compactMap(URL.init(string:))
            let disposable = MetaDisposable()
            func attempt(_ index: Int) {
                if index >= candidates.count {
                    if let directory {
                        let failurePath = (directory as NSString).appendingPathComponent(host + ".none")
                        FileManager.default.createFile(atPath: failurePath, contents: Data(), attributes: nil)
                    }
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                disposable.set((GGNetwork.shared.fetch(GGNetworkRequest(url: candidates[index], maxBytes: 512 * 1024))
                |> deliverOn(ggInterfaceQueue)).start(next: { response in
                    if let data = response.data, let image = UIImage(data: data), image.size.width >= 8.0 {
                        let normalized = GGFaviconStore.normalized(image)
                        if let directory, let png = normalized.pngData() {
                            try? png.write(to: URL(fileURLWithPath: (directory as NSString).appendingPathComponent(host + ".png")), options: .atomic)
                        }
                        let _ = images.modify { current in
                            var updated = current
                            updated[host] = normalized
                            return updated
                        }
                        subscriber.putNext(normalized)
                        subscriber.putCompletion()
                    } else {
                        attempt(index + 1)
                    }
                }, error: { _ in
                    attempt(index + 1)
                }))
            }
            attempt(0)
            return disposable
        }
        |> runOn(ggInterfaceQueue))
    }

    /// 64 px square, so the disk copy stays small whatever the site serves.
    private static func normalized(_ image: UIImage) -> UIImage {
        let side: CGFloat = 64.0
        return generateImage(CGSize(width: side, height: side), scale: 1.0, rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            UIGraphicsPushContext(context)
            let scale = min(size.width / image.size.width, size.height / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(origin: CGPoint(x: (size.width - drawSize.width) * 0.5, y: (size.height - drawSize.height) * 0.5), size: drawSize))
            UIGraphicsPopContext()
        }) ?? image
    }

    /// The Settings rows' tile: white rounded square with the icon inside.
    private static func tile(_ image: UIImage, size: CGFloat) -> UIImage? {
        return generateImage(CGSize(width: size, height: size), rotatedContext: { contextSize, context in
            context.clear(CGRect(origin: CGPoint(), size: contextSize))
            let rect = CGRect(origin: CGPoint(), size: contextSize)
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: floor(size * 0.235)).cgPath)
            context.setFillColor(UIColor.white.cgColor)
            context.fillPath()
            UIGraphicsPushContext(context)
            image.draw(in: rect.insetBy(dx: floor(size * 0.14), dy: floor(size * 0.14)))
            UIGraphicsPopContext()
        })
    }

    private static let monogramColors: [UIColor] = [
        UIColor(rgb: 0xff516a), UIColor(rgb: 0xffa85c), UIColor(rgb: 0x665fff),
        UIColor(rgb: 0x54cb68), UIColor(rgb: 0x2a9ef1), UIColor(rgb: 0xd669ed)
    ]

    private static let monogramCache = Atomic<[String: UIImage]>(value: [:])

    /// A letter tile, cached per (host, size).
    static func monogram(for host: String, size: CGFloat) -> UIImage? {
        let key = "\(host)|\(size)"
        if let cached = GGFaviconStore.monogramCache.with({ $0[key] }) {
            return cached
        }
        let letter = host.first.map { String($0).uppercased() } ?? "?"
        var hash: UInt32 = 0
        for scalar in host.unicodeScalars {
            hash = hash &* 31 &+ scalar.value
        }
        let color = GGFaviconStore.monogramColors[Int(hash % UInt32(GGFaviconStore.monogramColors.count))]
        let image = generateImage(CGSize(width: size, height: size), rotatedContext: { contextSize, context in
            context.clear(CGRect(origin: CGPoint(), size: contextSize))
            let rect = CGRect(origin: CGPoint(), size: contextSize)
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: floor(size * 0.235)).cgPath)
            context.setFillColor(color.cgColor)
            context.fillPath()
            UIGraphicsPushContext(context)
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: floor(size * 0.55), weight: .semibold), .foregroundColor: UIColor.white]
            let text = NSAttributedString(string: letter, attributes: attributes)
            let textSize = text.size()
            text.draw(at: CGPoint(x: (contextSize.width - textSize.width) * 0.5, y: (contextSize.height - textSize.height) * 0.5))
            UIGraphicsPopContext()
        })
        if let image {
            let _ = GGFaviconStore.monogramCache.modify { current in
                var updated = current
                updated[key] = image
                return updated
            }
        }
        return image
    }
}

/// Opening a shortcut.
enum GGShortcutActions {
    static func open(_ shortcut: GGSettingsShortcut, context: AccountContext, navigationController: NavigationController?) {
        switch shortcut.kind {
        case .site:
            guard let url = shortcut.url else {
                return
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: url, forceExternal: false, presentationData: presentationData, navigationController: navigationController, dismissInput: {})
        case .chat, .miniApp:
            guard let peerKey = shortcut.peer else {
                return
            }
            let peerId = EnginePeer.Id(ggKey: peerKey)
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> deliverOnMainQueue).start(next: { peer in
                guard let peer, let navigationController else {
                    return
                }
                if shortcut.kind == .miniApp, let parentController = navigationController.topViewController as? ViewController {
                    // The bot's terms are shown when it asks for them (the old client skipped them).
                    context.sharedContext.openWebApp(context: context, parentController: parentController, updatedPresentationData: nil, botPeer: peer, chatPeer: nil, threadId: nil, buttonText: "", url: "", simple: true, source: .generic, skipTermsOfService: false, payload: nil, verifyAgeCompletion: nil)
                } else {
                    context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
                }
            })
        }
    }
}
