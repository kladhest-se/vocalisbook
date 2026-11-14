import Foundation
import CryptoKit
import zlib

public indirect enum MetadataJSON: Codable, Sendable, Hashable {
    case null, bool(Bool), int(Int), string(String), array([MetadataJSON]), object([String: MetadataJSON])
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([MetadataJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: MetadataJSON].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var object: [String: MetadataJSON]? { if case .object(let v) = self { v } else { nil } }
    public var array: [MetadataJSON]? { if case .array(let v) = self { v } else { nil } }
    public var strings: [String]? {
        guard let array else { return nil }
        let result = array.compactMap(\.string)
        return result.count == array.count ? result : nil
    }
    var canonical: String {
        switch self {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .string(let v): return Self.quote(v.precomposedStringWithCanonicalMapping)
        case .array(let v): return "[" + v.map(\.canonical).joined(separator: ",") + "]"
        case .object(let v): return "{" + v.keys.sorted().map { Self.quote($0) + ":" + v[$0]!.canonical }.joined(separator: ",") + "}"
        }
    }
    private static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: out += "\\\""
            case 92: out += "\\\\"
            case 8: out += "\\b"
            case 9: out += "\\t"
            case 10: out += "\\n"
            case 12: out += "\\f"
            case 13: out += "\\r"
            case 32...126: out.unicodeScalars.append(scalar)
            case 0...0xffff: out += String(format: "\\u%04x", scalar.value)
            default:
                let n = scalar.value - 0x10000
                out += String(format: "\\u%04x\\u%04x", 0xd800 + (n >> 10), 0xdc00 + (n & 1023))
            }
        }
        return out + "\""
    }
}

public struct VocalisMetaV4: Sendable, Hashable {
    public static let prefix = "VocalisMeta-v4: "
    public enum Invalid: Error { case packet }
    public struct Field: Codable, Sendable, Hashable {
        public enum State: String, Codable, Sendable { case known, unknown, unavailable, cleared }
        public let state: State
        public let value: MetadataJSON
        public let stale: Bool
        public let provenance: Provenance
        public let reason: String?
        public let identityEvidence: String?
        enum CodingKeys: String, CodingKey { case state, value, stale, provenance, reason; case identityEvidence = "identity_evidence" }
    }
    public struct Provenance: Codable, Sendable, Hashable {
        public let source: String
        public let evidence: String
        public let dateKind: String?
        enum CodingKeys: String, CodingKey { case source, evidence; case dateKind = "date_kind" }
        public var label: String {
            switch evidence {
            case "manual_override": return "Manual override"
            case "embedded_tags": return "From local tags"
            case "isbn_match": return "Matched by ISBN"
            case "name_only": return "Name-based credit"
            default:
                switch source {
                case "audible": return "From Audible"
                case "librivox": return "From LibriVox"
                case "ljudboksarkivet": return "From Ljudboksarkivet"
                case "openlibrary": return "From Open Library"
                case "googlebooks": return "From Google Books"
                case "local_artwork", "embedded_artwork": return "From local artwork"
                default: return "Source unknown"
                }
            }
        }
    }
    public struct Match: Codable, Sendable, Hashable {
        public let source: String
        public let evidence: String
        public let method: String
    }
    public struct Series: Codable, Sendable, Hashable {
        public let primaryRef: String?
        public let memberships: [Membership]
        enum CodingKeys: String, CodingKey { case primaryRef = "primary_ref"; case memberships }
    }
    public struct Membership: Codable, Sendable, Hashable {
        public let ref: String
        public let title: String
        public let sequence: String
        public let providerID: ProviderID?
        enum CodingKeys: String, CodingKey { case ref, title, sequence; case providerID = "provider_id" }
    }
    public struct ProviderID: Codable, Sendable, Hashable { public let source: String; public let scope: String; public let id: String }
    public struct Upgrade: Codable, Sendable, Hashable, Identifiable {
        public let previous: String
        public let current: String
        public let status: String
        public let evidence: [String]
        public let reasons: [String]
        public let requiresClientConfirmation: Bool
        public var id: String { previous + "->" + current }
        enum CodingKeys: String, CodingKey { case previous, current, status, evidence, reasons; case requiresClientConfirmation = "requires_client_confirmation" }
    }
    public let match: Match
    public let recordingKey: String?
    public let metadataRevision: String
    public let artworkRevision: String?
    public let fields: [String: Field]
    public let clearedNamespaces: [String]
    public let identityUpgrades: [Upgrade]
    public let series: Series
    public let payloadData: Data

    public static func decode(moods: [String], guid: String?) throws -> VocalisMetaV4? {
        let tags = moods.filter { $0.hasPrefix(prefix) }
        guard !tags.isEmpty else { return nil }
        guard tags.count <= 64 else { throw Invalid.packet }
        var pieces: [Int: String] = [:], digest: String?, count: Int?
        for tag in tags {
            let text = String(tag.dropFirst(prefix.count))
            guard text.range(of: #"^[0-9a-f]{64}:[1-9][0-9]?/[1-9][0-9]?:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw Invalid.packet }
            let components = text.split(separator: ":", omittingEmptySubsequences: false)
            let indexes = components[1].split(separator: "/")
            guard let index = Int(indexes[0]), let total = Int(indexes[1]), total <= 64, index <= total,
                  components[2].count <= 384, pieces[index] == nil,
                  digest == nil || digest == String(components[0]), count == nil || count == total else { throw Invalid.packet }
            digest = String(components[0]); count = total; pieces[index] = String(components[2])
        }
        guard let count, let digest, pieces.count == count else { throw Invalid.packet }
        let encoded = (1...count).map { pieces[$0]! }.joined().replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let compressed = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)) else { throw Invalid.packet }
        let raw = try inflateBounded(compressed)
        guard sha(raw) == digest else { throw Invalid.packet }
        return try decodePayload(raw, recordingKey: BookIdentity.provider(from: guid)?.key)
    }

    /// Stored packets are validated again and bound to the current recording.
    public static func decodePayload(_ raw: Data, recordingKey: String?) throws -> VocalisMetaV4 {
        guard raw.count <= 16384, raw.allSatisfy({ $0 < 128 }) else { throw Invalid.packet }
        let value = try JSONDecoder().decode(MetadataJSON.self, from: raw)
        guard Data(value.canonical.utf8) == raw else { throw Invalid.packet }
        try validate(value)
        let root = value.object!
        guard root["recording_key"]?.string == recordingKey else { throw Invalid.packet }
        let revisions = root["revisions"]!.object!
        let fields = try JSONDecoder().decode([String: Field].self, from: Data(root["fields"]!.canonical.utf8))
        let series = try JSONDecoder().decode(Series.self, from: Data(fields["series"]!.value.canonical.utf8))
        let upgrades = try JSONDecoder().decode([Upgrade].self, from: Data(root["identity_upgrades"]!.canonical.utf8))
        let match = try JSONDecoder().decode(Match.self, from: Data(root["match"]!.canonical.utf8))
        return VocalisMetaV4(match: match, recordingKey: recordingKey, metadataRevision: revisions["metadata"]!.string!,
            artworkRevision: revisions["artwork"]?.string, fields: fields,
            clearedNamespaces: root["cleared_namespaces"]!.strings!, identityUpgrades: upgrades, series: series, payloadData: raw)
    }

    private static func inflateBounded(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Invalid.packet }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 16385)
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.avail_in == 0, stream.total_out <= 16384 else { throw Invalid.packet }
        return Data(output.prefix(Int(stream.total_out)))
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func matches(_ s: String?, _ pattern: String) -> Bool {
        guard let s else { return false }
        return s.range(of: pattern, options: .regularExpression) != nil
    }
    private static func validKey(_ value: MetadataJSON?) -> Bool {
        guard let value else { return false }
        if value == .null { return true }
        guard let key = value.string else { return false }
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.first == "spokenmeta" else { return false }
        let identifier: String
        if parts.count == 4, parts[1] == "audible" { identifier = "\(parts[3])_\(parts[2])" }
        else if parts.count == 3 { identifier = "\(parts[1]):\(parts[2])" }
        else { return false }
        return BookIdentity.provider(from: "com.plexapp.agents.spokenmeta://" + identifier)?.key == key
    }
    private static func exact(_ value: MetadataJSON?, _ keys: Set<String>) throws -> [String: MetadataJSON] {
        guard let object = value?.object, Set(object.keys) == keys,
              object.keys.allSatisfy({ $0.unicodeScalars.allSatisfy { $0.value < 128 } }) else { throw Invalid.packet }
        return object
    }
    private static func validate(_ value: MetadataJSON) throws {
        let root = try exact(value, ["contract_version", "recording_key", "revisions", "match", "fields", "cleared_namespaces", "identity_upgrades"])
        guard root["contract_version"] == .int(4), validKey(root["recording_key"]) else { throw Invalid.packet }
        let rev = try exact(root["revisions"], ["metadata", "artwork"])
        guard matches(rev["metadata"]?.string, #"^sha256:[0-9a-f]{64}$"#), rev["artwork"] == .null || matches(rev["artwork"]?.string, #"^sha256:[0-9a-f]{64}$"#) else { throw Invalid.packet }
        let sources: Set<String> = ["audible", "librivox", "ljudboksarkivet", "openlibrary", "googlebooks", "embedded_tags", "embedded_artwork", "local_artwork", "remote_provider", "manual", "plex", "unknown"]
        let evidence: Set<String> = ["explicit_identifier", "provider_match", "isbn_match", "embedded_tags", "manual_override", "name_only", "provider_identifier", "local_file", "unknown"]
        let match = try exact(root["match"], ["source", "evidence", "method"])
        guard sources.contains(match["source"]?.string ?? ""), evidence.contains(match["evidence"]?.string ?? ""),
              ["unknown", "manual_override", "explicit_identifier", "provider_match", "local_fallback"].contains(match["method"]?.string ?? "") else { throw Invalid.packet }
        let names: Set<String> = ["title", "authors", "narrators", "series", "recording_date", "language", "edition", "work", "work_publication", "contributors", "artwork"]
        let fields = try exact(root["fields"], names)
        for (name, raw) in fields {
            guard let f = raw.object, Set(f.keys).isSuperset(of: ["state", "value", "stale", "provenance"]),
                  Set(f.keys).isSubset(of: ["state", "value", "stale", "provenance", "reason", "identity_evidence"]),
                  Field.State(rawValue: f["state"]?.string ?? "") != nil,
                  f["stale"] == .bool(true) || f["stale"] == .bool(false) else { throw Invalid.packet }
            guard let p = f["provenance"]?.object, Set(p.keys).isSuperset(of: ["source", "evidence"]),
                  Set(p.keys).isSubset(of: ["source", "evidence", "date_kind"]),
                  sources.contains(p["source"]?.string ?? ""), evidence.contains(p["evidence"]?.string ?? "") else { throw Invalid.packet }
            if let kind = p["date_kind"], kind != .null, !["recording_release", "copyright_year_fallback", "work_year_fallback", "book_edition_date_fallback", "user_supplied_recording_date"].contains(kind.string ?? "") { throw Invalid.packet }
            if let e = f["identity_evidence"], e != .null, !["unknown", "name_only", "provider_identifier"].contains(e.string ?? "") { throw Invalid.packet }
            if let reason = f["reason"], reason != .null, reason.string == nil { throw Invalid.packet }
            let v = f["value"]!
            if ["authors", "narrators", "contributors"].contains(name) {
                guard let strings = v.strings else { throw Invalid.packet }
                if name == "contributors", !strings.allSatisfy({ $0.hasPrefix("Contributor-ID: ") && ContributorIdentity(mood: String($0.dropFirst(16))) != nil }) { throw Invalid.packet }
            } else if name != "series", v != .null, v.string == nil { throw Invalid.packet }
            if f["state"] == .string("cleared") {
                guard v == .null || v == .string("") || v == .array([]) || (name == "series" && v.object?["memberships"] == .array([]) && v.object?["primary_ref"] == .null) else { throw Invalid.packet }
            }
        }
        if let work = fields["work"]?.object?["value"]?.string, !work.isEmpty, WorkIdentity(mood: work) == nil { throw Invalid.packet }
        if let year = fields["work_publication"]?.object?["value"]?.string, !year.isEmpty, !matches(year, #"^[1-9][0-9]{0,3}$"#) { throw Invalid.packet }
        if let edition = fields["edition"]?.object?["value"]?.string, !edition.isEmpty, !["Abridged", "Unabridged"].contains(edition) { throw Invalid.packet }
        guard fields["artwork"]?.object?["value"] == rev["artwork"] else { throw Invalid.packet }
        let series = try exact(fields["series"]?.object?["value"], ["primary_ref", "memberships"])
        guard let members = series["memberships"]?.array else { throw Invalid.packet }
        var refs = Set<String>()
        for value in members {
            guard var m = value.object, Set(m.keys).isSuperset(of: ["ref", "title", "sequence"]), Set(m.keys).isSubset(of: ["ref", "title", "sequence", "provider_id"]),
                  let ref = m.removeValue(forKey: "ref")?.string, let title = m["title"]?.string, !title.isEmpty, m["sequence"]?.string != nil,
                  ref == "relationship:" + sha(Data(MetadataJSON.object(m).canonical.utf8)), refs.insert(ref).inserted else { throw Invalid.packet }
            if let provider = m["provider_id"] {
                let p = try exact(provider, ["source", "scope", "id"])
                let audible = p["source"] == .string("audible") && ["au","ca","de","es","fr","in","it","jp","uk","us"].contains(p["scope"]?.string ?? "") && matches(p["id"]?.string, #"^[A-Z0-9]{10}$"#)
                let swedish = p["source"] == .string("ljudboksarkivet") && p["scope"] == .string("") && matches(p["id"]?.string, #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#)
                guard audible || swedish else { throw Invalid.packet }
            }
        }
        guard series["primary_ref"] == .null || refs.contains(series["primary_ref"]?.string ?? ""),
              let cleared = root["cleared_namespaces"]?.strings, Set(cleared).isSubset(of: ["work_identity", "work_publication", "openlibrary_author_ids", "extended_metadata"]),
              let upgrades = root["identity_upgrades"]?.array, upgrades.count <= 8 else { throw Invalid.packet }
        for value in upgrades {
            let u = try exact(value, ["previous", "current", "status", "evidence", "reasons", "requires_client_confirmation"])
            guard validKey(u["previous"]), let previous = u["previous"]?.string, u["current"] == root["recording_key"],
                  let current = u["current"]?.string, previous != current, u["requires_client_confirmation"] == .bool(true),
                  let reasons = u["reasons"]?.strings, let proof = u["evidence"]?.strings,
                  ["review_required", "verified_same_recording"].contains(u["status"]?.string ?? "") else { throw Invalid.packet }
            if u["status"] == .string("verified_same_recording") {
                guard previous.hasPrefix("spokenmeta:local:"), reasons.isEmpty,
                      (proof == ["same_explicit_asin_and_region"] && current.hasPrefix("spokenmeta:audible:")) || (proof == ["same_explicit_librivox_project"] && current.hasPrefix("spokenmeta:librivox:")) else { throw Invalid.packet }
            }
        }
    }
}
