import Foundation
import UIKit
import CoreText
import SwiftSignalKit
import GGCore
import GGHooks
import GGAppearanceSettings

/// A font the user added from Files (owner, 2026-10-27: «в выбор шрифтов добавить кастомный, чтобы
/// можно было заливать»). The file is copied into the app's container and registered for this
/// process only (CTFontManager, `.process` scope) at launch: nothing is installed system-wide and
/// nothing leaves the device.
struct GGCustomFont: Equatable {
    /// File name inside `GGCustomFonts.directory`.
    let fileName: String
    /// The family the file declares: what the menu shows and what CoreText resolves faces from.
    let familyName: String
}

enum GGCustomFontImportResult {
    case added(GGCustomFont)
    case notAFont
    case tooMany
}

enum GGCustomFonts {
    /// `appearance.font.family` of a custom font: the prefix and the file name.
    static let valuePrefix = "custom:"
    static let maximumCount = 10

    private static let queue = Queue(name: "org.ghostgram.appearance.fonts", qos: .utility)
    private static let fileExtensions: Set<String> = ["ttf", "otf", "ttc"]

    static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        // Not ".../fonts": the font.v2 migration deletes that directory of an earlier build.
        return base.appendingPathComponent("ghostgram/appearance/userFonts", isDirectory: true)
    }

    /// The fonts in the order they were added (an in-memory setting read: the menu asks per row).
    static var fonts: [GGCustomFont] {
        return GGAppearanceSettings.customFonts.value.compactMap { entry in
            let parts = entry.components(separatedBy: "\t")
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                return nil
            }
            return GGCustomFont(fileName: parts[0], familyName: parts[1])
        }
    }

    static func settingValue(_ font: GGCustomFont) -> String {
        return GGCustomFonts.valuePrefix + font.fileName
    }

    static func isCustomValue(_ value: String) -> Bool {
        return value.hasPrefix(GGCustomFonts.valuePrefix)
    }

    /// The font a stored `appearance.font.family` names, if it is a custom one still in the list.
    static func font(forSettingValue value: String) -> GGCustomFont? {
        guard GGCustomFonts.isCustomValue(value) else {
            return nil
        }
        let fileName = String(value.dropFirst(GGCustomFonts.valuePrefix.count))
        return GGCustomFonts.fonts.first(where: { $0.fileName == fileName })
    }

    /// The fonts the user added, for the other features that draw in them (GGUserFontsHooks: the island
    /// badge studio).
    static func registerProvider() {
        GGUserFontsHooks.fonts.register({
            return GGCustomFonts.fonts.compactMap { font -> GGUserFont? in
                guard let url = GGCustomFonts.fileURL(font) else {
                    return nil
                }
                return GGUserFont(familyName: font.familyName, fileURL: url)
            }
        })
    }

    private static func fileURL(_ font: GGCustomFont) -> URL? {
        return GGCustomFonts.directory?.appendingPathComponent(font.fileName)
    }

    // MARK: Import and removal (main thread; the file work runs on the fonts queue)

    /// Checks that CoreText reads the picked file as a font, copies it, adds it to the list and makes
    /// it the app font (applied after a restart, like every font).
    static func importFont(at sourceURL: URL, completion: @escaping (GGCustomFontImportResult) -> Void) {
        if GGCustomFonts.fonts.count >= GGCustomFonts.maximumCount {
            completion(.tooMany)
            return
        }
        GGCustomFonts.queue.async {
            let result = GGCustomFonts.copyFont(at: sourceURL)
            Queue.mainQueue().async {
                guard let font = result else {
                    completion(.notAFont)
                    return
                }
                var entries = GGAppearanceSettings.customFonts.value
                entries.append("\(font.fileName)\t\(font.familyName)")
                GGAppearanceSettings.customFonts.set(entries)
                GGAppearanceSettings.fontFamily.set(GGCustomFonts.settingValue(font))
                completion(.added(font))
            }
        }
    }

    private static func copyFont(at sourceURL: URL) -> GGCustomFont? {
        guard let directory = GGCustomFonts.directory else {
            return nil
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(sourceURL as CFURL) as? [CTFontDescriptor], let first = descriptors.first else {
            return nil
        }
        guard let familyName = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String, !familyName.isEmpty else {
            return nil
        }
        var fileExtension = sourceURL.pathExtension.lowercased()
        if !GGCustomFonts.fileExtensions.contains(fileExtension) {
            fileExtension = descriptors.count > 1 ? "ttc" : "ttf"
        }
        let fileName = "font-\(UInt32.random(in: 0 ... UInt32.max)).\(fileExtension)"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: directory.appendingPathComponent(fileName))
        } catch {
            GGLog.warning("appearance", "custom font copy failed")
            return nil
        }
        return GGCustomFont(fileName: fileName, familyName: familyName.replacingOccurrences(of: "\t", with: " "))
    }

    /// Drops the font from the list; the app font falls back to the system one if it was chosen. The
    /// file itself is deleted at the next launch (`cleanUp`): the running app may still draw with it.
    static func remove(_ font: GGCustomFont) {
        if GGAppearanceSettings.fontFamily.value == GGCustomFonts.settingValue(font) {
            GGAppearanceSettings.fontFamily.reset()
        }
        let entries = GGAppearanceSettings.customFonts.value.filter { !$0.hasPrefix(font.fileName + "\t") }
        GGAppearanceSettings.customFonts.set(entries)
    }

    // MARK: Launch

    /// Registers the chosen font's file for this process. Nil when the file is gone or unreadable.
    static func registerForLaunch(_ font: GGCustomFont) -> String? {
        guard let url = GGCustomFonts.fileURL(font), FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            // Already registered by this process is fine; anything else shows up as a missing family.
            error?.release()
        }
        if UIFont.fontNames(forFamilyName: font.familyName).isEmpty {
            return nil
        }
        return font.familyName
    }

    /// Deletes files no longer in the list (removed fonts), off the main thread, once per launch.
    static func cleanUp() {
        let kept = Set(GGCustomFonts.fonts.map(\.fileName))
        GGCustomFonts.queue.async {
            guard let directory = GGCustomFonts.directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
                return
            }
            for name in names where !kept.contains(name) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    // MARK: Menu (main thread)

    private static var menuFonts: [String: UIFont] = [:]

    /// The font's regular face for the menu sample, read straight from its file (not registered:
    /// a font added in this session is drawn before any restart). Cached per file.
    static func menuFont(_ font: GGCustomFont, size: CGFloat) -> UIFont? {
        let key = "\(font.fileName)_\(size)"
        if let cached = GGCustomFonts.menuFonts[key] {
            return cached
        }
        guard let url = GGCustomFonts.fileURL(font), let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let first = descriptors.first else {
            return nil
        }
        let result = CTFontCreateWithFontDescriptor(first, size, nil) as UIFont
        GGCustomFonts.menuFonts[key] = result
        return result
    }
}
