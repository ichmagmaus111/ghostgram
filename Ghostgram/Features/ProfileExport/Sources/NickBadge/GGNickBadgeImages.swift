import Foundation
import UIKit
import CryptoKit
import SwiftSignalKit
import GGCore

// Pictures of custom badges (`GET v1/img/<id>.png`). A picture is accepted only when the first 16 hex
// of its sha256 equal its id — and the id came in the signed table, so it can not be swapped on the
// way. Rules that keep it off the hot path:
//   - only pictures a slot on screen asked for are fetched (no prefetch of the whole table);
//   - the disk is read on this class's queue, never in a layout pass: until the picture is in
//     memory the slot draws the supporter ghost and is refreshed when it arrives;
//   - a failed download is not retried on every redraw: it backs off (1 min, doubling, ≤ 6 h).

final class GGNickBadgeImages {
    static let shared = GGNickBadgeImages()

    private static let maxBytes = 2 * 1024 * 1024
    private static let maxSourceCount = 64

    private let queue = Queue(name: "org.ghostgram.nickBadge.images", qos: .utility)
    private let lock = GGProfileExportLock()
    /// Decoded, downscaled pictures. Read from any thread.
    private var sources: [String: UIImage] = [:]
    /// Pictures being loaded from disk or the network (queue only).
    private var pending = Set<String>()
    /// Failed downloads: id → (failures, next attempt). Queue only.
    private var failures: [String: (count: Int, retryAt: Double)] = [:]
    private var downloads: [String: Disposable] = [:]

    var onPictureLoaded: (() -> Void)?

    private init() {
    }

    private var directory: URL? {
        return GGProfileExportPaths.cachesDirectory("nickBadge")?.appendingPathComponent("img", isDirectory: true)
    }

    /// The picture if it is in memory; otherwise nil, and it is loaded (disk, then network).
    func source(for imageId: String) -> UIImage? {
        if let image = self.lock.withLock({ self.sources[imageId] }) {
            return image
        }
        self.queue.async {
            self.load(imageId)
        }
        return nil
    }

    /// Forgets pictures the current table no longer refers to.
    func retain(only imageIds: Set<String>) {
        self.lock.withLock {
            self.sources = self.sources.filter { imageIds.contains($0.key) }
        }
    }

    /// The feature was turned off: nothing in flight.
    func cancelAll() {
        self.queue.async {
            for (_, disposable) in self.downloads {
                disposable.dispose()
            }
            self.downloads.removeAll()
            self.pending.removeAll()
        }
    }

    private func load(_ imageId: String) {
        if self.pending.contains(imageId) || !GGNickBadgeParser.isImageId(imageId) {
            return
        }
        if self.lock.withLock({ self.sources[imageId] != nil }) {
            return
        }
        if let failure = self.failures[imageId], CFAbsoluteTimeGetCurrent() < failure.retryAt {
            return
        }
        self.pending.insert(imageId)
        if let directory = self.directory, let data = try? Data(contentsOf: directory.appendingPathComponent(imageId + ".png")), GGNickBadgeImages.hexPrefix(data) == imageId, let image = GGNickBadgeImages.decode(data) {
            self.pending.remove(imageId)
            self.install(image, for: imageId)
            return
        }
        guard let url = URL(string: GGNickBadgeService.baseURL + "v1/img/" + imageId + ".png") else {
            self.pending.remove(imageId)
            return
        }
        let request = GGNetworkRequest(url: url, etag: nil, signingKeys: [], maxBytes: GGNickBadgeImages.maxBytes)
        self.downloads[imageId] = (GGNetwork.shared.fetch(request)
        |> deliverOn(self.queue)).start(next: { [weak self] response in
            self?.finishDownload(imageId, data: response.data)
        }, error: { [weak self] _ in
            self?.finishDownload(imageId, data: nil)
        })
    }

    private func finishDownload(_ imageId: String, data: Data?) {
        self.downloads.removeValue(forKey: imageId)
        self.pending.remove(imageId)
        guard let data = data, GGNickBadgeImages.hexPrefix(data) == imageId, let image = GGNickBadgeImages.decode(data) else {
            let count = (self.failures[imageId]?.count ?? 0) + 1
            let delay = min(6.0 * 60.0 * 60.0, 60.0 * pow(2.0, Double(count - 1)))
            self.failures[imageId] = (count, CFAbsoluteTimeGetCurrent() + delay)
            GGLog.info("nickBadge", "picture download failed, retry in \(Int(delay)) s")
            return
        }
        self.failures.removeValue(forKey: imageId)
        if let directory = self.directory, GGProfileExportPaths.ensureDirectory(directory, excludeFromBackup: true) {
            try? data.write(to: directory.appendingPathComponent(imageId + ".png"), options: .atomic)
        }
        self.install(image, for: imageId)
    }

    private func install(_ image: UIImage, for imageId: String) {
        self.lock.withLock {
            if self.sources.count >= GGNickBadgeImages.maxSourceCount {
                self.sources.removeAll(keepingCapacity: true)
            }
            self.sources[imageId] = image
        }
        GGNickBadgeArt.purgeCustom()
        let onPictureLoaded = self.onPictureLoaded
        Queue.mainQueue().async {
            onPictureLoaded?()
        }
    }

    private static func hexPrefix(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        var result = ""
        result.reserveCapacity(16)
        let digits: [Character] = Array("0123456789abcdef")
        for byte in digest.prefix(8) {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0F)])
        }
        return result
    }

    /// Uploads are not resized by the server (up to 4096 px); a badge is one line high, so the
    /// picture is kept at most 96 px tall.
    private static func decode(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data), image.size.width > 0.0, image.size.height > 0.0 else {
            return nil
        }
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let targetHeight = min(96.0, pixelHeight)
        let targetWidth = max(1.0, (pixelWidth * targetHeight / pixelHeight).rounded())
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 3.0
        format.opaque = false
        let size = CGSize(width: targetWidth / 3.0, height: targetHeight / 3.0)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: CGPoint(), size: size))
        }
    }
}
