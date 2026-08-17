import Foundation

/// Plex serialises the same field as a JSON number in one endpoint and a quoted
/// string in another (and occasionally omits it entirely). Every model in this
/// package decodes numerics through these helpers instead of the synthesised
/// `Decodable` conformance, so a server upgrade that flips a type does not
/// break the client.
extension KeyedDecodingContainer {
    func plexInt(_ key: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return Int(v) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }

    func plexDouble(_ key: Key) -> Double? {
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }

    func plexBool(_ key: Key) -> Bool? {
        if let v = try? decodeIfPresent(Bool.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            switch s.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }

    func plexString(_ key: Key) -> String? {
        if let v = try? decodeIfPresent(String.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return String(v) }
        return nil
    }

    /// Missing arrays are far more common than empty ones in Plex responses
    /// (an empty section simply omits `Metadata`), so absence is not an error.
    func plexArray<T: Decodable>(_ type: [T].Type, _ key: Key) -> [T] {
        ((try? decodeIfPresent([T].self, forKey: key)) ?? nil) ?? []
    }

    /// Plex epoch fields are seconds since 1970.
    func plexDate(_ key: Key) -> Date? {
        guard let seconds = plexInt(key) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
