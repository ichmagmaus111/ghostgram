import Foundation
import ZipArchive

/// Archives from outside (`.icons` packs, the zipped `.ggbadge` of earlier builds) are unpacked only
/// into a fresh directory and never through a symbolic link. SSZipArchive creates an entry that is a
/// link (`a` → `../../Library/Preferences`) without checking its target and then writes the next
/// entries THROUGH it (`a/x.plist`), out of the directory. So:
/// - an entry marked as a link stops the unpacking before anything is written for it (the delegate is
///   asked before each entry is touched);
/// - the unpacked tree is checked afterwards: every item a plain file or a directory, inside it.
/// A failed unpacking or check removes the directory. Any thread except the main one.
enum GGSafeUnzip {
    /// `destination` must not exist yet.
    static func unzip(archive path: String, to destination: String) -> Bool {
        if FileManager.default.fileExists(atPath: destination) {
            return false
        }
        let delegate = GGSafeUnzipDelegate()
        let unpacked = SSZipArchive.unzipFile(atPath: path, toDestination: destination, delegate: delegate)
        if !unpacked || delegate.foundLink || !GGSafeUnzip.isSafeTree(destination) {
            try? FileManager.default.removeItem(atPath: destination)
            return false
        }
        return true
    }

    /// Every item under `directory` is a regular file or a directory (no link, nothing else) and its
    /// path stays inside `directory`.
    static func isSafeTree(_ directory: String) -> Bool {
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else {
            return false
        }
        while let relative = enumerator.nextObject() as? String {
            if relative.isEmpty || relative.hasPrefix("/") || relative.split(separator: "/").contains("..") {
                return false
            }
            guard let type = enumerator.fileAttributes?[.type] as? FileAttributeType else {
                return false
            }
            if type != .typeRegular && type != .typeDirectory {
                return false
            }
            let resolved = URL(fileURLWithPath: (directory as NSString).appendingPathComponent(relative)).resolvingSymlinksInPath().standardizedFileURL.path
            if !resolved.hasPrefix(root + "/") {
                return false
            }
        }
        return true
    }

    /// Removes the symbolic links under `directory` (the links themselves, never their targets).
    /// For directories that may come from before this check (a pack installed or migrated by an
    /// older build): a link there must not let «Share» pack files from outside.
    static func removeSymbolicLinks(in directory: String) {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else {
            return
        }
        var links: [String] = []
        while let relative = enumerator.nextObject() as? String {
            if let type = enumerator.fileAttributes?[.type] as? FileAttributeType, type == .typeSymbolicLink {
                links.append((directory as NSString).appendingPathComponent(relative))
            }
        }
        for link in links {
            try? FileManager.default.removeItem(atPath: link)
        }
    }
}

private final class GGSafeUnzipDelegate: NSObject, SSZipArchiveDelegate {
    private(set) var foundLink = false

    /// Asked before an entry is written: `false` stops the whole unpacking.
    func zipArchiveShouldUnzipFile(at fileIndex: Int, totalFiles: Int, archivePath: String, fileInfo: unz_file_info) -> Bool {
        // The entry's st_mode is in the upper 16 bits of the external attributes (Unix archives);
        // S_IFLNK whatever system the archive says it was made on.
        let mode = (fileInfo.external_fa >> 16) & 0o170000
        if mode == 0o120000 {
            self.foundLink = true
            return false
        }
        return true
    }
}
