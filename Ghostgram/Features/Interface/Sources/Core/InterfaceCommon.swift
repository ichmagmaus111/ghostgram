import Foundation
import UIKit
import SwiftSignalKit
import GGCore

/// "RRGGBB" colors stored in settings.
enum GGColorHex {
    /// "#3390ec", "3390EC", "0x3390ec" → "3390EC"; nil when it is not a 6-digit hex color.
    static func normalized(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") {
            value.removeFirst()
        } else if value.hasPrefix("0X") {
            value.removeFirst(2)
        }
        guard value.count == 6, value.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return value
    }

    static func color(_ text: String) -> UIColor? {
        guard let normalized = GGColorHex.normalized(text), let rgb = UInt32(normalized, radix: 16) else {
            return nil
        }
        return UIColor(red: CGFloat((rgb >> 16) & 0xff) / 255.0, green: CGFloat((rgb >> 8) & 0xff) / 255.0, blue: CGFloat(rgb & 0xff) / 255.0, alpha: 1.0)
    }

    /// "RRGGBB" of a color (alpha ignored).
    static func hex(_ color: UIColor) -> String {
        var red: CGFloat = 0.0
        var green: CGFloat = 0.0
        var blue: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        if !color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0.0
            color.getWhite(&white, alpha: &alpha)
            red = white
            green = white
            blue = white
        }
        func component(_ value: CGFloat) -> Int {
            return Int((max(0.0, min(1.0, value)) * 255.0).rounded())
        }
        return String(format: "%02X%02X%02X", component(red), component(green), component(blue))
    }
}

/// An immutable value published for hot paths: one uncontended lock and a copy per read.
final class GGSnapshotBox<T> {
    private let storage: Atomic<T>

    init(_ value: T) {
        self.storage = Atomic(value: value)
    }

    var value: T {
        return self.storage.with { $0 }
    }

    /// Returns the previous value.
    @discardableResult
    func swap(_ value: T) -> T {
        return self.storage.swap(value)
    }
}

/// Files of this zone live under `<appGroup>/ghostgram/interface/` — the `ghostgram` directory is
/// the one upstream's App Group clean-up keeps (HOOKS.md §0.4).
func ggInterfaceDirectory(_ name: String) -> String? {
    guard let appGroupPath = GGCore.environment?.appGroupPath else {
        return nil
    }
    let path = ((appGroupPath as NSString).appendingPathComponent("ghostgram") as NSString).appendingPathComponent("interface")
    let directory = (path as NSString).appendingPathComponent(name)
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
    return directory
}

/// Work of this zone that must not run on the main thread (files, decoding, rendering).
let ggInterfaceQueue = Queue(name: "org.ghostgram.interface")
