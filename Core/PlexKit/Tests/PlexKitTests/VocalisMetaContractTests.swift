import Foundation
import Testing
@testable import PlexKit

@Suite("Published VocalisMeta client contracts")
struct VocalisMetaContractTests {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/VocalisMeta"))
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func book(moods: [String], styles: [String] = []) throws -> PlexBook {
        let json: [String: Any] = ["ratingKey": "900", "title": "Fixture", "Mood": moods.map { ["tag": $0] }, "Style": styles.map { ["tag": $0] }]
        return try JSONDecoder().decode(PlexBook.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("Every published v1 recording identity vector preserves its canonical key")
    func identities() throws {
        let vectors = try #require(try fixture("test-vectors-v1")["identity_vectors"] as? [[String: Any]])
        for vector in vectors {
            let input = try #require(vector["input"] as? String)
            #expect(BookIdentity.provider(from: input)?.key == vector["expected_canonical_key"] as? String,
                    "\(vector["name"] as? String ?? "identity")")
        }
    }

    @Test("Every published v1 relationship vector retains exact memberships and narrator credits")
    func relationships() throws {
        let vectors = try #require(try fixture("test-vectors-v1")["relationship_vectors"] as? [[String: Any]])
        for vector in vectors {
            let expected = try #require(vector["expected"] as? [String: Any])
            let book = try book(moods: vector["moods"] as? [String] ?? [], styles: vector["styles"] as? [String] ?? [])
            #expect(book.authors == expected["additional_authors"] as? [String])
            #expect(book.narrators == expected["narrators"] as? [String])
            let series = expected["series"] as? [[String: Any]] ?? []
            #expect(book.series == series.compactMap { $0["name"] as? String })
            for item in series {
                let name = try #require(item["name"] as? String)
                #expect(book.sequences.first { $0.series == name }?.position == item["position"] as? String)
            }
            #expect(book.language == (expected["languages"] as? [String])?.first)
            #expect(book.edition == (expected["editions"] as? [String])?.first)
        }
    }

    @Test("Every v2 work vector remains separate from the recording identity")
    func works() throws {
        let vectors = try #require(try fixture("test-vectors-v2")["work_identity_vectors"] as? [[String: Any]])
        for vector in vectors {
            let book = try book(moods: vector["moods"] as? [String] ?? [])
            #expect(book.authors == vector["expected_additional_authors"] as? [String])
            #expect(book.workIdentity?.key == vector["expected_canonical_work_key"] as? String)
        }
    }

    @Test("Every v3 contributor, production and rating vector matches the current agent")
    func extendedMetadata() throws {
        let vectors = try #require(try fixture("test-vectors-v3")["extended_metadata_vectors"] as? [[String: Any]])
        for vector in vectors {
            let expected = try #require(vector["expected"] as? [String: Any])
            let book = try book(moods: vector["moods"] as? [String] ?? [])
            #expect(book.authors == expected["additional_authors"] as? [String])
            #expect(book.workPublishedYear == expected["work_published"] as? Int)
            #expect(book.productionType == expected["production"] as? String)
            #expect(book.ratingSource == expected["rating_source"] as? String)
            #expect(book.ratingCount == expected["rating_count"] as? Int)
            let contributors = expected["contributors"] as? [[String: Any]] ?? []
            #expect(book.contributors.map(\.key) == contributors.compactMap { $0["key"] as? String })
            #expect(book.contributors.map(\.displayName) == contributors.compactMap { $0["name"] as? String })
        }
    }

    @Test("Published Unicode narrator and local identities are consumed without recomputing them")
    func unicodeIdentityConsumption() throws {
        let vectors = try fixture("unicode-identity-vectors-v1")
        for vector in vectors["contributor_vectors"] as? [[String: String]] ?? [] {
            let name = try #require(vector["name"]), hash = try #require(vector["expected"])
            let contributor = try #require(ContributorIdentity(mood: "narrator:name:\(hash) = \(name)"))
            #expect(!contributor.isProviderBacked)
            #expect(contributor.displayName.unicodeScalars.elementsEqual(name.unicodeScalars))
            #expect(contributor.key == "spokenmeta:contributor:narrator:name:\(hash)")
        }
        for vector in vectors["local_vectors"] as? [[String: Any]] ?? [] {
            let id = try #require(vector["expected"] as? String)
            #expect(BookIdentity.provider(from: "com.plexapp.agents.spokenmeta://\(id)")?.key == "spokenmeta:\(id)")
        }
    }

    @Test("Recording dates and score values reject malformed data without inventing missing metadata")
    func recordingFacets() throws {
        for (date, expected) in [("2008-02-29", "2008-02-29" as String?), ("2008-02-30", nil), ("2008-13-01", nil), ("unknown", nil)] {
            let json: [String: Any] = ["ratingKey": "900", "title": "Book", "originallyAvailableAt": date, "rating": "9.4"]
            let book = try JSONDecoder().decode(PlexBook.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(book.recordingReleaseDate == expected)
            #expect(book.rating == 9.4)
        }
        let unknown = try book(moods: ["Rating-Source: Unknown", "Rating-Count: 123"])
        #expect(unknown.ratingSource == nil && unknown.ratingCount == nil && unknown.rating == nil)
    }
}
