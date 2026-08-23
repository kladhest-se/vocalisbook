import Foundation
import Testing
@testable import PlexKit

/// `MetadataContainer<Item>` and `DirectoryContainer<Item>` are generic over
/// `plexArray`, the one shared decoding path every array in this package
/// goes through — including `Metadata`, the actual page of books a library
/// listing returns. Tested here with `Item = PlexBook` specifically because
/// this is the highest-stakes case: a malformed entry surviving here means
/// one bad book in a page of two hundred no longer silently empties the
/// other one hundred and ninety-nine.
@Suite("MediaContainer leniency")
struct MediaContainerTests {

    @Test("One malformed book in a listing does not lose the rest of the page")
    func oneMalformedBookDoesNotLoseTheRest() throws {
        let json = """
        {"size":3,"Metadata":[
            {"ratingKey":"900","title":"Wyrd Sisters"},
            {"title":"Missing Its Rating Key"},
            {"ratingKey":"901","title":"Mort"}
        ]}
        """
        let container = try JSONDecoder().decode(
            MetadataContainer<PlexBook>.self, from: Data(json.utf8)
        )
        #expect(container.metadata.map(\.ratingKey) == ["900", "901"])
    }

    @Test("An empty or missing Metadata key decodes to an empty array, not an error")
    func missingMetadataIsEmpty() throws {
        let json = """
        {"size":0}
        """
        let container = try JSONDecoder().decode(
            MetadataContainer<PlexBook>.self, from: Data(json.utf8)
        )
        #expect(container.metadata.isEmpty)
    }

    @Test("A fully valid page decodes every entry, unaffected by the leniency added around it")
    func fullyValidPageIsUnaffected() throws {
        let json = """
        {"size":2,"Metadata":[
            {"ratingKey":"900","title":"Wyrd Sisters"},
            {"ratingKey":"901","title":"Mort"}
        ]}
        """
        let container = try JSONDecoder().decode(
            MetadataContainer<PlexBook>.self, from: Data(json.utf8)
        )
        #expect(container.metadata.map(\.ratingKey) == ["900", "901"])
    }
}
