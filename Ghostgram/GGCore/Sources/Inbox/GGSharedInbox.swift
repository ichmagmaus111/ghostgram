import Darwin
import Foundation

/// An append-only inbox in the App Group: an extension appends records, the app drains them.
/// File: `<appGroup>/ghostgram/inbox/<name>`. Each record is a 4-byte big-endian length and the
/// bytes. Both sides hold `flock(LOCK_EX)` on the file, so an append and a drain never interleave.
/// The file is capped (8 MB by default): when the app does not drain for a long time, new records
/// are dropped instead of growing the container without bound.
///
/// Do the I/O off the main thread: `drain()` reads the whole file synchronously.
public final class GGSharedInbox {
    public static let defaultMaximumSize = 8 * 1024 * 1024

    public let name: String
    private let directoryPath: String?
    private let maximumSize: Int

    /// `name`: letters, digits, ".", "-", "_".
    public convenience init(name: String) {
        self.init(name: name, directoryPath: nil, maximumSize: GGSharedInbox.defaultMaximumSize)
    }

    /// `directoryPath` nil: `<appGroup>/ghostgram/inbox` of the bootstrapped environment.
    init(name: String, directoryPath: String?, maximumSize: Int) {
        assert(GGSharedInbox.isValidName(name), "Invalid inbox name \(name)")
        self.name = name
        self.directoryPath = directoryPath
        self.maximumSize = maximumSize
    }

    /// Extension side. Adds one record; drops it (with a warning) when the file is full.
    public func append(_ record: Data) {
        guard let path = self.filePath(createDirectory: true) else {
            GGLog.warning("inbox", "\(self.name): no App Group, record dropped")
            return
        }
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        if descriptor < 0 {
            GGLog.warning("inbox", "\(self.name): open failed (\(errno))")
            return
        }
        defer {
            Darwin.close(descriptor)
        }
        if flock(descriptor, LOCK_EX) != 0 {
            GGLog.warning("inbox", "\(self.name): lock failed (\(errno))")
            return
        }
        defer {
            flock(descriptor, LOCK_UN)
        }

        var status = stat()
        if fstat(descriptor, &status) != 0 {
            return
        }
        let recordSize = 4 + record.count
        if Int(status.st_size) + recordSize > self.maximumSize {
            GGLog.warning("inbox", "\(self.name): inbox is full, record dropped")
            return
        }

        var buffer = Data(capacity: recordSize)
        let length = UInt32(truncatingIfNeeded: record.count)
        buffer.append(UInt8(truncatingIfNeeded: length >> 24))
        buffer.append(UInt8(truncatingIfNeeded: length >> 16))
        buffer.append(UInt8(truncatingIfNeeded: length >> 8))
        buffer.append(UInt8(truncatingIfNeeded: length))
        buffer.append(record)
        if !GGSharedInbox.writeAll(descriptor, buffer) {
            GGLog.warning("inbox", "\(self.name): write failed (\(errno))")
        }
    }

    /// App side. Takes every complete record and empties the file atomically with respect to
    /// appenders. A torn tail (an extension killed mid-write) is discarded.
    public func drain() -> [Data] {
        guard let path = self.filePath(createDirectory: false) else {
            return []
        }
        let descriptor = Darwin.open(path, O_RDWR | O_CLOEXEC)
        if descriptor < 0 {
            return []
        }
        defer {
            Darwin.close(descriptor)
        }
        if flock(descriptor, LOCK_EX) != 0 {
            return []
        }
        defer {
            flock(descriptor, LOCK_UN)
        }

        var status = stat()
        if fstat(descriptor, &status) != 0 {
            return []
        }
        let size = Int(status.st_size)
        if size <= 0 {
            return []
        }
        guard let contents = GGSharedInbox.readAll(descriptor, size: min(size, self.maximumSize + 4)) else {
            return []
        }
        if ftruncate(descriptor, 0) != 0 {
            GGLog.warning("inbox", "\(self.name): truncate failed (\(errno))")
        }
        return GGSharedInbox.parseRecords(contents, maximumSize: self.maximumSize)
    }

    // MARK: - Internal

    static func isValidName(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." {
            return false
        }
        for scalar in name.unicodeScalars {
            let value = scalar.value
            let isLetter = (value >= 97 && value <= 122) || (value >= 65 && value <= 90)
            let isDigit = value >= 48 && value <= 57
            let isMark = value == 46 || value == 45 || value == 95
            if !isLetter && !isDigit && !isMark {
                return false
            }
        }
        return true
    }

    static func parseRecords(_ data: Data, maximumSize: Int) -> [Data] {
        var records: [Data] = []
        let bytes = [UInt8](data)
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            if length > maximumSize {
                break
            }
            let start = offset + 4
            let end = start + length
            if end > bytes.count {
                break
            }
            records.append(Data(bytes[start ..< end]))
            offset = end
        }
        return records
    }

    private func filePath(createDirectory: Bool) -> String? {
        var directory = self.directoryPath
        if directory == nil {
            directory = GGCore.environment?.inboxDirectoryPath
        }
        guard let directoryPath = directory else {
            return nil
        }
        if createDirectory && !FileManager.default.fileExists(atPath: directoryPath) {
            do {
                try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true, attributes: nil)
            } catch {
                return nil
            }
        }
        return (directoryPath as NSString).appendingPathComponent(self.name)
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress else {
                return true
            }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    private static func readAll(_ descriptor: Int32, size: Int) -> Data? {
        if lseek(descriptor, 0, SEEK_SET) < 0 {
            return nil
        }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Int in
            guard let base = buffer.baseAddress else {
                return 0
            }
            var offset = 0
            while offset < buffer.count {
                let readCount = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
                if readCount < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return -1
                }
                if readCount == 0 {
                    break
                }
                offset += readCount
            }
            return offset
        }
        if count < 0 {
            return nil
        }
        if count < size {
            data.count = count
        }
        return data
    }
}
