import Foundation

/// A value a setting can hold. Stored as JSON in the settings files.
public protocol GGSettingValue: Codable, Equatable {}

extension Bool: GGSettingValue {}
extension Int: GGSettingValue {}
extension Int32: GGSettingValue {}
extension Int64: GGSettingValue {}
extension Double: GGSettingValue {}
extension String: GGSettingValue {}
extension Data: GGSettingValue {}
extension Optional: GGSettingValue where Wrapped: GGSettingValue {}
extension Array: GGSettingValue where Element: GGSettingValue {}
extension Dictionary: GGSettingValue where Key == String, Value: GGSettingValue {}
extension Set: GGSettingValue where Element: GGSettingValue {}
extension GGAccountID: GGSettingValue {}
extension GGPeerKey: GGSettingValue {}
extension GGMessageKey: GGSettingValue {}

/// JSON fragments of single values. Top-level fragments (`true`, `"text"`, `12`) are supported by
/// Foundation's coders since iOS 13.
enum GGSettingCodec {
    static func encode<Value: Encodable>(_ value: Value) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) -> Value? {
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Compact JSON of an already parsed object (from `JSONSerialization`).
    static func fragment(fromJSONObject object: Any) -> Data? {
        if object is NSNull {
            return Data("null".utf8)
        }
        guard object is NSNumber || object is NSString || object is NSArray || object is NSDictionary else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
    }

    static func text(_ fragment: Data?) -> String {
        guard let fragment = fragment else {
            return "null"
        }
        return String(decoding: fragment, as: UTF8.self)
    }

    /// `"key"` with JSON escaping, for writing objects by hand from stored fragments.
    static func encodedKey(_ key: String) -> Data? {
        return GGSettingCodec.encode(key)
    }

    /// `{"a":<fragment>,"b":<fragment>}` with sorted keys, one entry per line.
    static func object(_ values: [String: Data]) -> Data {
        var result = Data()
        result.append(UInt8(ascii: "{"))
        var isFirst = true
        for key in values.keys.sorted() {
            guard let fragment = values[key], let encodedKey = GGSettingCodec.encodedKey(key) else {
                continue
            }
            if !isFirst {
                result.append(UInt8(ascii: ","))
            }
            isFirst = false
            result.append(UInt8(ascii: "\n"))
            result.append(encodedKey)
            result.append(UInt8(ascii: ":"))
            result.append(fragment)
        }
        if !isFirst {
            result.append(UInt8(ascii: "\n"))
        }
        result.append(UInt8(ascii: "}"))
        return result
    }

    /// Parses `{"key": <any JSON>}` into fragments; nil when the data is not a JSON object.
    static func fragments(ofObject object: Any?) -> [String: Data]? {
        guard let dictionary = object as? [String: Any] else {
            return nil
        }
        var result: [String: Data] = [:]
        for (key, value) in dictionary {
            if let fragment = GGSettingCodec.fragment(fromJSONObject: value) {
                result[key] = fragment
            }
        }
        return result
    }
}
