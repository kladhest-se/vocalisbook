import Foundation
import Testing
@testable import PlexKit

/// Direct tests of `plexArray` itself, isolated from `PlexBook`'s own
/// complexity, after two wrong implementations of it in a row — the first
/// assumed a failed `decode(_:)` still advances the container's cursor,
/// the second assumed `superDecoder()` did. Both were checked only by
/// reasoning, not a compiler, and the first one was actually wrong: a real
/// build showed elements *after* a malformed one going missing too. This
/// file exists so the next version has a test that would have caught both
/// mistakes, run against `plexArray` directly rather than only inferred
/// through `PlexBook`'s much larger decode path.
private struct SimpleItem: Decodable, Equatable {
    let value: Int
}

private struct ItemList: Decodable {
    let items: [SimpleItem]

    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.plexArray([SimpleItem].self, .items)
    }
}

@Suite("plexArray leniency")
struct LenientScalarsTests {

    @Test("A fully valid array decodes every element in order")
    func fullyValidArray() throws {
        let json = """
        {"items":[{"value":1},{"value":2},{"value":3}]}
        """
        let list = try JSONDecoder().decode(ItemList.self, from: Data(json.utf8))
        #expect(list.items == [SimpleItem(value: 1), SimpleItem(value: 2), SimpleItem(value: 3)])
    }

    @Test("A wrong-type element in the middle is skipped, and elements after it survive")
    func wrongTypeElementInTheMiddle() throws {
        let json = """
        {"items":[{"value":1},{"value":"not a number"},{"value":3}]}
        """
        let list = try JSONDecoder().decode(ItemList.self, from: Data(json.utf8))
        #expect(list.items == [SimpleItem(value: 1), SimpleItem(value: 3)])
    }

    @Test("An explicit JSON null in the middle is skipped, and elements after it survive")
    func explicitNullElementInTheMiddle() throws {
        let json = """
        {"items":[{"value":1},null,{"value":3}]}
        """
        let list = try JSONDecoder().decode(ItemList.self, from: Data(json.utf8))
        #expect(list.items == [SimpleItem(value: 1), SimpleItem(value: 3)])
    }

    @Test("An element that is not an object at all is skipped, and elements after it survive")
    func wrongShapeElementInTheMiddle() throws {
        let json = """
        {"items":[{"value":1},"not an object",42,{"value":3}]}
        """
        let list = try JSONDecoder().decode(ItemList.self, from: Data(json.utf8))
        #expect(list.items == [SimpleItem(value: 1), SimpleItem(value: 3)])
    }

    @Test("Multiple consecutive malformed elements are all skipped without losing what follows")
    func multipleConsecutiveMalformedElements() throws {
        let json = """
        {"items":[{"value":1},null,"bad",{"value":"bad"},{"value":2}]}
        """
        let list = try JSONDecoder().decode(ItemList.self, from: Data(json.utf8))
        #expect(list.items == [SimpleItem(value: 1), SimpleItem(value: 2)])
    }

    @Test("A malformed last element does not affect anything before it")
    func malformedLastElement() throws {
        let json = """
        {"items":[{"value":1},{"value":2},null]}
        """
        let list = try JSONDecoder().decode(ItemList.self, from: Data(json.utf8))
        #expect(list.items == [SimpleItem(value: 1), SimpleItem(value: 2)])
    }

    @Test("A missing key decodes to an empty array, not an error")
    func missingKeyIsEmpty() throws {
        let json = """
        {}
        """
        let list = try JSONDecoder().decode(ItemList.self, from: Data(json.utf8))
        #expect(list.items.isEmpty)
    }
}
