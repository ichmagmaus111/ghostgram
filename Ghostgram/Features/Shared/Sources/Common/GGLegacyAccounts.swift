import Foundation
import GGCore
import TelegramCore

/// How many Telegram accounts this device has, for the migrations of the old Ghostgram: its global
/// keys (a folder id, the ids of messages in private chats) belong to one account only when there is
/// one account. Counted as the account directories `telegram-data/account-<id>` of the App Group, which
/// carry over from the old app (same container). Not cached: an account added later changes the
/// answer. Reads a directory: never call it inside a Postbox transaction.
public enum GGLegacyAccounts {
    /// nil when the container is not known yet or can not be read.
    public static var deviceAccountCount: Int? {
        guard let appGroupPath = GGCore.environment?.appGroupPath else {
            return nil
        }
        let rootPath = rootPathForBasePath(appGroupPath)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: rootPath) else {
            return nil
        }
        let prefix = "account-"
        var count = 0
        for name in names where name.hasPrefix(prefix) {
            if UInt64(name.dropFirst(prefix.count)) == nil {
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: (rootPath as NSString).appendingPathComponent(name), isDirectory: &isDirectory), isDirectory.boolValue {
                count += 1
            }
        }
        return count
    }

    /// Exactly one account on the device: a global key of the old client can only be this account's.
    public static var isSingleAccount: Bool {
        return GGLegacyAccounts.deviceAccountCount == 1
    }
}
