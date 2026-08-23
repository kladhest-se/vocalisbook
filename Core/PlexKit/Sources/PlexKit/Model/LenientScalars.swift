import Foundation

/// A type with no stored properties, used only to advance an unkeyed
/// container's cursor past an element whose real decode already failed.
/// Its synthesized `init(from:)` has nothing to read and so cannot itself
/// fail on a mismatched type — decoding one succeeds regardless of whether
/// the underlying JSON value is a number, string, array, or object, which
/// is precisely what makes it work as a forced "skip this element" rather
/// than an actual decode of anything.
private struct EmptyDecodableSink: Decodable {}

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
    ///
    /// Decoded one element at a time rather than
    /// `try? decodeIfPresent([T].self, forKey: key)`, which looks
    /// equivalent but is not: Swift's array decoding is all-or-nothing, so
    /// one element with an unexpected shape throws for the *entire* array,
    /// and a `try?` around that call converts "one malformed element" into
    /// "everything in this list is gone." This function is the one path
    /// every array decode in the package goes through — `Metadata` (the
    /// actual page of books a library listing returns), a track's parts,
    /// its chapters, a server's connections — so that failure mode was not
    /// specific to any one of them: a single bad book entry could have
    /// silently emptied an entire page of otherwise-good ones, the same way
    /// one bad chapter marker could empty a track's whole chapter list.
    ///
    /// Two earlier versions of this were both wrong, in the same direction:
    /// each assumed some call — `unkeyed.decode(T.self)` failing, then
    /// `unkeyed.superDecoder()` succeeding — would advance the container's
    /// cursor past a malformed element on its own. Neither claim was
    /// checkable without a compiler, and the first one was wrong: a real
    /// build showed elements *after* the malformed one going missing too,
    /// not just the malformed one, meaning nothing was advancing and the
    /// loop was re-reading the same element until its safety bound gave up.
    /// Confirmed against Swift's own tracked issue for this exact problem
    /// (SR-5953 / apple/swift-corelibs-foundation#4414): "the currentIndex
    /// is not incremented unless a decode succeeds" — stated as the reason
    /// lossy array decoding doesn't fall out of the standard API for free.
    ///
    /// The fix used here is the community's own documented workaround from
    /// that same issue: on a failed real decode, decode a zero-field dummy
    /// type instead. A type with no stored properties has nothing for its
    /// synthesized `init(from:)` to fail on, so it succeeds — and therefore
    /// advances the cursor — regardless of the actual element's shape.
    /// `decodeNil()` is tried first for the one case a value with no
    /// fields still can't absorb: an explicit JSON `null`, which
    /// `decodeNil()` is specifically documented to consume when it
    /// returns `true`.
    func plexArray<T: Decodable>(_ type: [T].Type, _ key: Key) -> [T] {
        guard var unkeyed = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var results: [T] = []
        // `count` is known up front for a JSON array; bounding the loop on
        // it in addition to `isAtEnd` is a last-resort safety net in case
        // even the dummy-decode fallback below somehow fails to advance —
        // worst case, this stops reading the list early rather than
        // looping forever.
        let bound = unkeyed.count ?? 10_000
        var iterations = 0
        while !unkeyed.isAtEnd, iterations < bound {
            iterations += 1
            if let element = try? unkeyed.decode(T.self) {
                results.append(element)
            } else if (try? unkeyed.decodeNil()) == true {
                // An explicit JSON null: already consumed by decodeNil()
                // itself succeeding, nothing further to do.
            } else {
                _ = try? unkeyed.decode(EmptyDecodableSink.self)
            }
        }
        return results
    }

    /// Plex epoch fields are seconds since 1970.
    func plexDate(_ key: Key) -> Date? {
        guard let seconds = plexInt(key) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
