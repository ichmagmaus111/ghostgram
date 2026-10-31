import Foundation

// A small little-endian binary format for the anti-delete index entries: they are rewritten on
// every capture batch, so they must be cheap to decode and encode (no JSON, no keyed coding).
// Pure Foundation: compiled into GGFeaturesShared and into the host tests.

struct GGBinaryWriter {
    private(set) var data = Data()

    init() {
    }

    mutating func writeUInt8(_ value: UInt8) {
        self.data.append(value)
    }

    mutating func writeUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            self.data.append(contentsOf: bytes)
        }
    }

    mutating func writeInt32(_ value: Int32) {
        self.writeUInt32(UInt32(bitPattern: value))
    }

    mutating func writeInt64(_ value: Int64) {
        var littleEndian = UInt64(bitPattern: value).littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            self.data.append(contentsOf: bytes)
        }
    }

    mutating func writeBool(_ value: Bool) {
        self.writeUInt8(value ? 1 : 0)
    }

    /// UTF-8 bytes with a 32-bit length.
    mutating func writeString(_ value: String) {
        let bytes = Data(value.utf8)
        self.writeUInt32(UInt32(clamping: bytes.count))
        self.data.append(bytes)
    }

    mutating func writeOptionalString(_ value: String?) {
        if let value {
            self.writeBool(true)
            self.writeString(value)
        } else {
            self.writeBool(false)
        }
    }
}

struct GGBinaryReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool {
        return self.offset >= self.data.endIndex
    }

    private mutating func take(_ count: Int) -> Data? {
        if count < 0 || self.data.endIndex - self.offset < count {
            return nil
        }
        let slice = self.data[self.offset ..< self.offset + count]
        self.offset += count
        return slice
    }

    mutating func readUInt8() -> UInt8? {
        guard let bytes = self.take(1) else {
            return nil
        }
        return bytes[bytes.startIndex]
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = self.take(4) else {
            return nil
        }
        var value: UInt32 = 0
        for (index, byte) in bytes.enumerated() {
            value |= UInt32(byte) << UInt32(index * 8)
        }
        return value
    }

    mutating func readInt32() -> Int32? {
        return self.readUInt32().map { Int32(bitPattern: $0) }
    }

    mutating func readInt64() -> Int64? {
        guard let bytes = self.take(8) else {
            return nil
        }
        var value: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            value |= UInt64(byte) << UInt64(index * 8)
        }
        return Int64(bitPattern: value)
    }

    mutating func readBool() -> Bool? {
        return self.readUInt8().map { $0 != 0 }
    }

    mutating func readString() -> String? {
        guard let length = self.readUInt32(), let bytes = self.take(Int(length)) else {
            return nil
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func readOptionalString() -> String?? {
        guard let hasValue = self.readBool() else {
            return nil
        }
        if !hasValue {
            return .some(nil)
        }
        guard let value = self.readString() else {
            return nil
        }
        return .some(value)
    }
}
