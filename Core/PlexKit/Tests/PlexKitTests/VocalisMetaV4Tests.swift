import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
import zlib
@testable import PlexKit

@Suite("VocalisMeta v4 packet validation")
struct VocalisMetaV4Tests {
    func vectors() throws -> [[String: Any]] {
        let url = try #require(Bundle.module.url(forResource: "test-vectors-v4", withExtension: "json", subdirectory: "Fixtures/VocalisMeta"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(root["vectors"] as? [[String: Any]])
    }
    func guid(_ key: String?) -> String? {
        guard let key else { return nil }
        let parts = key.split(separator: ":")
        let body = parts[1] == "audible" ? "\(parts[3])_\(parts[2])" : "\(parts[1]):\(parts[2])"
        return "com.plexapp.agents.spokenmeta://" + body
    }
    func tags(_ raw: Data, trailing: Bool = false) throws -> [String] {
        var output = [UInt8](repeating: 0, count: Int(compressBound(uLong(raw.count))))
        var size = uLongf(output.count)
        let status = raw.withUnsafeBytes { bytes in
            compress2(&output, &size, bytes.bindMemory(to: UInt8.self).baseAddress, uLong(raw.count), Z_DEFAULT_COMPRESSION)
        }
        #expect(status == Z_OK)
        var data = Data(output.prefix(Int(size)))
        if trailing { data.append(0) }
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let chunks = stride(from: 0, to: encoded.count, by: 384).map { offset in
            String(encoded.dropFirst(offset).prefix(384))
        }
        return chunks.enumerated().map { VocalisMetaV4.prefix + VocalisMetaV4.sha(raw) + ":\($0.offset + 1)/\(chunks.count):\($0.element)" }
    }
    @Test("All twenty published v4 packets decode exactly, independent of chunk order")
    func publishedPackets() throws {
        let vectors = try vectors()
        #expect(vectors.count == 20)
        for vector in vectors {
            let moods = try #require(vector["moods"] as? [String])
            let expected = try #require(vector["expected"] as? [String: Any])
            let expectedValue = try JSONDecoder().decode(MetadataJSON.self, from: JSONSerialization.data(withJSONObject: expected))
            let packet = try #require(try VocalisMetaV4.decode(moods: moods.reversed(), guid: guid(expected["recording_key"] as? String)))
            #expect(packet.payloadData == Data(expectedValue.canonical.utf8), "\(vector["name"] as? String ?? "fixture")")
            #expect(packet.fields.count == 11)
        }
    }
    @Test("Every published invalid transport mutation is rejected")
    func invalidMutations() throws {
        let vector = try #require(try vectors().first { $0["name"] as? String == "fresh_recording" })
        let moods = try #require(vector["moods"] as? [String])
        let expected = try #require(vector["expected"] as? [String: Any])
        let key = expected["recording_key"] as? String
        #expect(throws: (any Error).self) { try VocalisMetaV4.decode(moods: Array(moods.dropLast()), guid: guid(key)) }
        #expect(throws: (any Error).self) { try VocalisMetaV4.decode(moods: moods + [moods[0]], guid: guid(key)) }
        #expect(throws: (any Error).self) { try VocalisMetaV4.decode(moods: [moods[0] + "!"] + moods.dropFirst(), guid: guid(key)) }
        let other = try #require(try vectors().first { $0["name"] as? String == "same_key_artwork_replacement" }?["moods"] as? [String])
        #expect(throws: (any Error).self) { try VocalisMetaV4.decode(moods: moods + [other[0]], guid: guid(key)) }
        var badPrimary = expected
        var fields = try #require(badPrimary["fields"] as? [String: Any])
        var series = try #require(fields["series"] as? [String: Any])
        var value = try #require(series["value"] as? [String: Any])
        value["primary_ref"] = "relationship:" + String(repeating: "0", count: 64)
        series["value"] = value; fields["series"] = series; badPrimary["fields"] = fields
        let badValue = try JSONDecoder().decode(MetadataJSON.self, from: JSONSerialization.data(withJSONObject: badPrimary))
        #expect(throws: (any Error).self) { try VocalisMetaV4.decode(moods: tags(Data(badValue.canonical.utf8)), guid: guid(key)) }
        var unsafe = expected
        unsafe["identity_upgrades"] = [["previous": "spokenmeta:audible:uk:B000000001", "current": key!,
            "status": "verified_same_recording", "evidence": ["same_explicit_asin_and_region"], "reasons": [], "requires_client_confirmation": true]]
        let unsafeValue = try JSONDecoder().decode(MetadataJSON.self, from: JSONSerialization.data(withJSONObject: unsafe))
        #expect(throws: (any Error).self) { try VocalisMetaV4.decode(moods: tags(Data(unsafeValue.canonical.utf8)), guid: guid(key)) }
    }
    @Test("Corrupt, oversized and noncanonical JSON never become author credits or partial packets")
    func adversarialPackets() throws {
        let vector = try #require(try vectors().first)
        let moods = try #require(vector["moods"] as? [String])
        let expected = try #require(vector["expected"] as? [String: Any])
        let value = try JSONDecoder().decode(MetadataJSON.self, from: JSONSerialization.data(withJSONObject: expected))
        let raw = Data(value.canonical.utf8), key = expected["recording_key"] as? String
        #expect(throws: (any Error).self) { try VocalisMetaV4.decode(moods: tags(raw, trailing: true), guid: guid(key)) }
        #expect(throws: (any Error).self) { try VocalisMetaV4.decode(moods: tags(Data(repeating: 65, count: 16385)), guid: guid(key)) }
        let duplicates = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\"contract_version\":4", with: "\"contract_version\":4,\"contract_version\":4")
        #expect(throws: (any Error).self) { try VocalisMetaV4.decode(moods: tags(Data(duplicates.utf8)), guid: guid(key)) }
        let float = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\"contract_version\":4", with: "\"contract_version\":4.0")
        #expect(throws: (any Error).self) { try VocalisMetaV4.decode(moods: tags(Data(float.utf8)), guid: guid(key)) }
        #expect(throws: (any Error).self) { try VocalisMetaV4.decode(moods: moods, guid: guid("spokenmeta:audible:uk:B000000001")) }
        let json: [String: Any] = ["ratingKey": "101", "title": "Book", "Mood": ["Author", "VocalisMeta-v4: invalid"].map { ["tag": $0] }]
        let book = try JSONDecoder().decode(PlexBook.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(book.authors == ["Author"] && book.metadataV4 == nil && book.metadataV4Present)
    }
    @Test("Published native JSON and XML fixtures carry equivalent validated envelopes")
    func nativeFixtures() throws {
        for name in ["fresh_recording", "provider_unavailable_preserves_revisions", "verified_local_to_audible"] {
            let jsonURL = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/VocalisMeta/v4"))
            let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
            let container = try #require(root["MediaContainer"] as? [String: Any])
            let native = try #require((container["Metadata"] as? [[String: Any]])?.first)
            let book = try JSONDecoder().decode(PlexBook.self, from: JSONSerialization.data(withJSONObject: native))
            let packet = try #require(book.metadataV4)
            #expect(!book.authors.contains { $0.hasPrefix(VocalisMetaV4.prefix) })
            let xmlURL = try #require(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures/VocalisMeta/v4"))
            let collector = V4XMLCollector(), parser = XMLParser(data: try Data(contentsOf: xmlURL))
            parser.delegate = collector
            #expect(parser.parse())
            #expect(try VocalisMetaV4.decode(moods: collector.moods, guid: collector.guid)?.payloadData == packet.payloadData)
        }
    }
}
private final class V4XMLCollector: NSObject, XMLParserDelegate {
    var moods: [String] = []
    var guid: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "Directory" { guid = attributes["guid"] }
        if elementName == "Mood", let tag = attributes["tag"] { moods.append(tag) }
    }
}
