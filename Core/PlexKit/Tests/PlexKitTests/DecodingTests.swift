import Foundation
import Testing
@testable import PlexKit

@Suite("Plex response decoding")
struct DecodingTests {

    @Test("Numeric fields decode whether Plex sends them as numbers or strings")
    func lenientNumerics() throws {
        let asNumbers = """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":1234,"title":"A Book","duration":3600000,"year":2019,"index":1}
        ]}}
        """
        let asStrings = """
        {"MediaContainer":{"size":"1","Metadata":[
          {"ratingKey":"1234","title":"A Book","duration":"3600000","year":"2019","index":"1"}
        ]}}
        """
        for payload in [asNumbers, asStrings] {
            let decoded = try PlexTransport.decoder.decode(
                MediaContainerResponse<MetadataContainer<PlexBook>>.self,
                from: Data(payload.utf8)
            )
            let book = try #require(decoded.mediaContainer.metadata.first)
            #expect(book.ratingKey == "1234")
            #expect(book.approximateDurationMs == 3_600_000)
            #expect(book.year == 2019)
        }
    }

    @Test("An empty section omits Metadata entirely rather than sending []")
    func missingArrayIsNotAnError() throws {
        let payload = #"{"MediaContainer":{"size":0}}"#
        let decoded = try PlexTransport.decoder.decode(
            MediaContainerResponse<MetadataContainer<PlexBook>>.self,
            from: Data(payload.utf8)
        )
        #expect(decoded.mediaContainer.metadata.isEmpty)
    }

    @Test("Part cache key changes when the file is retagged")
    func partCacheKeyTracksUpdatedAt() throws {
        func part(updatedAt: Int) throws -> PlexPart {
            let json = #"{"id":"55","key":"/library/parts/55/\#(updatedAt)/file.m4b","updatedAt":\#(updatedAt)}"#
            return try PlexTransport.decoder.decode(PlexPart.self, from: Data(json.utf8))
        }
        let before = try part(updatedAt: 1_700_000_000)
        let after = try part(updatedAt: 1_800_000_000)
        #expect(before.cacheKey != after.cacheKey)
    }

    @Test("Only music-shaped sections are offered as audiobook libraries")
    func sectionFiltering() throws {
        let payload = """
        {"MediaContainer":{"size":3,"Directory":[
          {"key":"1","title":"Movies","type":"movie"},
          {"key":"2","title":"Audiobooks","type":"artist"},
          {"key":"3","title":"Photos","type":"photo"}
        ]}}
        """
        let decoded = try PlexTransport.decoder.decode(
            MediaContainerResponse<DirectoryContainer<PlexLibrarySection>>.self,
            from: Data(payload.utf8)
        )
        let candidates = decoded.mediaContainer.directory.filter(\.canContainAudiobooks)
        #expect(candidates.map(\.title) == ["Audiobooks"])
    }

    /// Plex puts collections under `Metadata`, and sections under `Directory`.
    ///
    /// Asking for the wrong one is not an error — a missing array is the
    /// ordinary case in these responses and decodes as empty. So the Collections
    /// screen was empty on all three clients with no failure anywhere: request
    /// fine, decode fine, answer nothing.
    @Test("A collections response under Metadata decodes")
    func collectionsUnderMetadata() throws {
        let json = """
        {"MediaContainer":{"size":2,"Metadata":[
          {"ratingKey":"11","title":"Discworld","childCount":41},
          {"ratingKey":"12","title":"Dune","childCount":6}
        ]}}
        """
        let response = try JSONDecoder().decode(
            MediaContainerResponse<ItemContainer<PlexCollection>>.self,
            from: Data(json.utf8)
        )
        #expect(response.mediaContainer.items.map(\.title) == ["Discworld", "Dune"])
    }

    /// And the other spelling still works, because these endpoints differ
    /// between server versions and a client insisting on one is making a bet it
    /// cannot check.
    @Test("A response under Directory decodes the same way")
    func collectionsUnderDirectory() throws {
        let json = """
        {"MediaContainer":{"size":1,"Directory":[
          {"ratingKey":"11","title":"Discworld","childCount":41}
        ]}}
        """
        let response = try JSONDecoder().decode(
            MediaContainerResponse<ItemContainer<PlexCollection>>.self,
            from: Data(json.utf8)
        )
        #expect(response.mediaContainer.items.map(\.title) == ["Discworld"])
    }

    @Test("Neither key present is an empty list, not a failure")
    func neitherKey() throws {
        let json = """
        {"MediaContainer":{"size":0}}
        """
        let response = try JSONDecoder().decode(
            MediaContainerResponse<ItemContainer<PlexCollection>>.self,
            from: Data(json.utf8)
        )
        #expect(response.mediaContainer.items.isEmpty)
    }

    /// The server picker used to claim "On this network" from a connection's
    /// `local` flag, which Plex sets on any private address — every server has
    /// one, so it was true for all of them. What it can honestly say is whose
    /// server it is.
    @Test("A shared server names its owner")
    func sharedServerOwnership() throws {
        let json = """
        {"clientIdentifier":"abc","name":"kak-sv-nas001","provides":"server",
         "owned":false,"sourceTitle":"Anna","connections":[]}
        """
        let resource = try JSONDecoder().decode(PlexResource.self, from: Data(json.utf8))
        #expect(resource.ownership == "Shared by Anna")
    }

    @Test("Your own server says so")
    func ownedServerOwnership() throws {
        let json = """
        {"clientIdentifier":"abc","name":"sth-ts-pms001","provides":"server",
         "owned":true,"connections":[]}
        """
        let resource = try JSONDecoder().decode(PlexResource.self, from: Data(json.utf8))
        #expect(resource.ownership == "Yours")
    }

    /// Plex does not always send `sourceTitle`. Naming nobody beats naming the
    /// wrong person.
    @Test("A shared server with no owner name still says it is shared")
    func sharedWithoutSourceTitle() throws {
        let json = """
        {"clientIdentifier":"abc","name":"someones-server","provides":"server",
         "owned":false,"connections":[]}
        """
        let resource = try JSONDecoder().decode(PlexResource.self, from: Data(json.utf8))
        #expect(resource.ownership == "Shared with you")
    }

    /// A real server was found whose parts carry no `updatedAt` at all.
    ///
    /// The old key fell back to a constant, so every part on that server had the
    /// same stamp for ever and a replaced file kept its key — the downloaded copy
    /// would never be invalidated and the old audio would go on playing.
    @Test("A part with no updatedAt falls back to its size")
    func cacheKeyFallsBackToSize() throws {
        let json = """
        {"id":"p1","key":"/p1","size":123456}
        """
        let part = try JSONDecoder().decode(PlexPart.self, from: Data(json.utf8))
        #expect(part.cacheKey == "p1-s123456")
    }

    @Test("Re-encoding a file changes the key even with no updatedAt")
    func sizeChangeInvalidates() throws {
        let before = try JSONDecoder().decode(PlexPart.self, from: Data("""
        {"id":"p1","key":"/p1","size":123456}
        """.utf8))
        let after = try JSONDecoder().decode(PlexPart.self, from: Data("""
        {"id":"p1","key":"/p1","size":123999}
        """.utf8))
        #expect(before.cacheKey != after.cacheKey)
    }

    @Test("Duration is the last resort before giving up")
    func cacheKeyFallsBackToDuration() throws {
        let json = """
        {"id":"p1","key":"/p1","duration":3600000}
        """
        let part = try JSONDecoder().decode(PlexPart.self, from: Data(json.utf8))
        #expect(part.cacheKey == "p1-d3600000")
    }

    /// The prefix letters are not decoration: without them a part updated at
    /// epoch 1700 and a part of 1700 bytes would produce one key for two files.
    @Test("The fallbacks cannot collide with each other")
    func fallbacksDoNotCollide() throws {
        let stamped = try JSONDecoder().decode(PlexPart.self, from: Data("""
        {"id":"p1","key":"/p1","updatedAt":1700}
        """.utf8))
        let sized = try JSONDecoder().decode(PlexPart.self, from: Data("""
        {"id":"p1","key":"/p1","size":1700}
        """.utf8))
        let timed = try JSONDecoder().decode(PlexPart.self, from: Data("""
        {"id":"p1","key":"/p1","duration":1700}
        """.utf8))

        #expect(Set([stamped.cacheKey, sized.cacheKey, timed.cacheKey]).count == 3)
    }

    /// A server that sends none of the three still has to produce a usable key —
    /// the download must work, it simply cannot notice the file changing.
    @Test("A part with nothing to go on still has a stable key")
    func cacheKeyWithNothing() throws {
        let json = """
        {"id":"p1","key":"/p1"}
        """
        let part = try JSONDecoder().decode(PlexPart.self, from: Data(json.utf8))
        #expect(part.cacheKey == "p1-x")
    }
    /// SpokenMeta's mapping, which is the reason these fields are read at all.
    ///
    /// Plex's music schema has nowhere to put a narrator or a co-author, so the
    /// agent documents where it puts them instead: Style is narrators, Mood is
    /// authors, and a Mood beginning `Series: ` is a series. Decoding them means
    /// a matched library shows what the agent went and fetched.
    @Test("Style becomes narrators and Mood splits into authors and series")
    func decodesSpokenMetaTags() throws {
        let json = """
        {"ratingKey":"900","title":"Wyrd Sisters","parentTitle":"Terry Pratchett",
         "Genre":[{"tag":"Fantasy"}],
         "Style":[{"tag":"Stephen Briggs"},{"tag":"Celia Imrie"}],
         "Mood":[{"tag":"Terry Pratchett"},{"tag":"Series: Discworld"},
                 {"tag":"Series: Witches"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.narrators == ["Stephen Briggs", "Celia Imrie"])
        #expect(book.authors == ["Terry Pratchett"])
        #expect(book.series == ["Discworld", "Witches"])
        #expect(book.genres == ["Fantasy"])
    }

    /// The prefix is matched exactly, as the agent specifies.
    ///
    /// Anything looser turns an author whose name mentions the word into a
    /// phantom series — and a series that is not one is worse than none, because
    /// it appears in a list somebody browses by.
    @Test("Only an exact Series prefix makes a series")
    func onlyExactPrefixIsSeries() throws {
        let json = """
        {"ratingKey":"900","title":"A Book",
         "Mood":[{"tag":"Anna Series"},{"tag":"series: lowercase"},
                 {"tag":"Series:NoSpace"},{"tag":"Series: Real"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.series == ["Real"])
        #expect(book.authors == ["Anna Series", "series: lowercase", "Series:NoSpace"])
    }

    /// A library no agent has matched carries no tags at all, which is a
    /// metadata problem and not a decoding one.
    @Test("A book with no tags decodes to empty lists")
    func untaggedBookIsEmpty() throws {
        let json = """
        {"ratingKey":"900","title":"A Book"}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.narrators.isEmpty)
        #expect(book.authors.isEmpty)
        #expect(book.series.isEmpty)
    }

    /// The four namespaces the contract reserves.
    ///
    /// Missing one means it shows up as a person: a library listing "English"
    /// and "Unabridged" among its authors, which reads as a scanning fault
    /// rather than a parsing one.
    @Test("Reserved Mood namespaces are kept out of the author list")
    func reservedMoodsAreNotAuthors() throws {
        let json = """
        {"ratingKey":"900","title":"Wyrd Sisters",
         "Mood":[{"tag":"Terry Pratchett"},{"tag":"Series: Discworld"},
                 {"tag":"Sequence: Discworld #6"},{"tag":"Language: English"},
                 {"tag":"Edition: Unabridged"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.authors == ["Terry Pratchett"])
        #expect(book.series == ["Discworld"])
        #expect(book.language == "English")
        #expect(book.edition == "Unabridged")
        #expect(book.sequences == [BookSequence(series: "Discworld", position: "6")])
    }

    /// A novella between two books is `3.5`, and it is a real thing in most long
    /// series. Parsing the position to an integer would drop it.
    @Test("A decimal position survives")
    func decimalPosition() throws {
        let json = """
        {"ratingKey":"900","title":"A Novella",
         "Mood":[{"tag":"Sequence: Some Series #3.5"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.sequences.first?.position == "3.5")
        #expect(book.sequences.first?.numericPosition == 3.5)
    }

    /// Split at the final ` #`, because a series name may contain one.
    @Test("A series name containing a hash still parses")
    func hashInSeriesName() throws {
        let sequence = BookSequence(mood: "Hitchhiker's #1 Guide #2")
        #expect(sequence?.series == "Hitchhiker's #1 Guide")
        #expect(sequence?.position == "2")
    }

    /// One book, several series, each with its own position.
    @Test("Multiple series and sequences are all kept")
    func multipleSeries() throws {
        let json = """
        {"ratingKey":"900","title":"Wyrd Sisters",
         "Mood":[{"tag":"Series: Discworld"},{"tag":"Series: Witches"},
                 {"tag":"Sequence: Discworld #6"},{"tag":"Sequence: Witches #2"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.series == ["Discworld", "Witches"])
        #expect(book.sequences.count == 2)
        #expect(book.sequences.contains(BookSequence(series: "Witches", position: "2")))
    }

    /// Absence means unknown. The contract is explicit that an edition must not
    /// be inferred from a missing tag.
    @Test("No language or edition Mood means nil, not a default")
    func absentMeansUnknown() throws {
        let json = """
        {"ratingKey":"900","title":"A Book","Mood":[{"tag":"An Author"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.language == nil)
        #expect(book.edition == nil)
    }

    /// Plex builds differ, and an album may carry several GUIDs.
    @Test("A Guid child is read, and SpokenMeta's is preferred")
    func guidFromChild() throws {
        let json = """
        {"ratingKey":"900","title":"A Book",
         "Guid":[{"id":"com.plexapp.agents.plexmusic://x"},
                 {"id":"com.plexapp.agents.spokenmeta://B08G9PRS1K_us?lang=en"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        let identity = BookIdentity.from(
            guid: book.guid, serverIdentifier: "srv", ratingKey: "900"
        )
        #expect(identity.key == "spokenmeta:audible:us:B08G9PRS1K")
    }

}

