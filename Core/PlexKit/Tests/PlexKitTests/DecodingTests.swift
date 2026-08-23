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
    /// VocalisMeta's mapping, which is the reason these fields are read at all.
    ///
    /// Plex's music schema has nowhere to put a narrator or a co-author, so the
    /// agent documents where it puts them instead: Style is narrators, Mood is
    /// authors, and a Mood beginning `Series: ` is a series. Decoding them means
    /// a matched library shows what the agent went and fetched.
    @Test("Style becomes narrators and Mood splits into authors and series")
    func decodesVocalisMetaTags() throws {
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

    /// The shape a real server actually sends, which no other fixture here
    /// had.
    ///
    /// Every tag fixture in this file was written as `{"tag": "..."}` and
    /// nothing else, and they all passed against a decoder that could not read
    /// a single tag off a live server. Plex sends an `id` and a `filter`
    /// alongside the name on every Genre, Mood and Style child, and the `id`
    /// is a **number**. `Tag.id` is a `String?` — it has to be, because a
    /// `Guid` child carries its value there as a string — and the synthesised
    /// decoder's `decodeIfPresent(String.self)` throws on a number rather than
    /// returning nil. `plexArray` skipped every element that threw, which was
    /// all of them, so a fully tagged book decoded to empty narrators, empty
    /// genres and empty moods with no error anywhere.
    ///
    /// The symptom was a Narrators screen that stayed empty on a library where
    /// the server plainly had twelve of them for one book.
    @Test("Tags decode with the numeric id and filter Plex really sends")
    func decodesTagsWithNumericIDs() throws {
        let json = """
        {"ratingKey":"154912","title":"Dune","parentTitle":"Frank Herbert",
         "Genre":[{"id":91,"filter":"genre=91","tag":"Science Fiction"}],
         "Style":[{"id":1201,"filter":"style=1201","tag":"Scott Brick"},
                  {"id":1202,"filter":"style=1202","tag":"Orlagh Cassidy"},
                  {"id":1203,"filter":"style=1203","tag":"Euan Morton"},
                  {"id":1204,"filter":"style=1204","tag":"Simon Vance"}],
         "Mood":[{"id":2001,"filter":"mood=2001","tag":"Frank Herbert"},
                 {"id":2002,"filter":"mood=2002","tag":"Series: Dune"},
                 {"id":2003,"filter":"mood=2003","tag":"Language: English"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.narrators == [
            "Scott Brick", "Orlagh Cassidy", "Euan Morton", "Simon Vance",
        ])

        // The numeric id is read; a numeric *tag* would not be. Asserted here
        // beside the case that needs the leniency, because the two fields
        // are one line apart in the decoder and the difference between them
        // is the entire fix.
        let numericTag = try JSONDecoder().decode(PlexBook.self, from: Data("""
        {"ratingKey":"1","title":"T","Style":[{"id":1,"tag":12345}]}
        """.utf8))
        #expect(numericTag.narrators.isEmpty)
        #expect(book.genres == ["Science Fiction"])
        #expect(book.authors == ["Frank Herbert"])
        #expect(book.series == ["Dune"])
        #expect(book.language == "English")
    }

    /// A dozen readers on one recording is normal, not an edge case.
    ///
    /// Every one of them is a display name in its own right — there is no
    /// primary narrator field to fall back to and no reason to pick one.
    @Test("Every Style value becomes a narrator")
    func decodesManyNarrators() throws {
        let names = [
            "Scott Brick", "Orlagh Cassidy", "Euan Morton", "Simon Vance",
            "Ilyana Kadushin", "Byron Jennings", "David R. Gordon", "Jason Culp",
            "Kent Broadhurst", "Oliver Wyman", "Patricia Kilgarriff", "Scott Sowers",
        ]
        // Escaped rather than a raw string, matching every other fixture in
        // this file and the seed helpers in the store's own tests.
        let styles = names.enumerated()
            .map { "{\"id\":\($0.offset + 1),\"tag\":\"\($0.element)\"}" }
            .joined(separator: ",")
        let json = "{\"ratingKey\":\"154912\",\"title\":\"Dune\",\"Style\":[\(styles)]}"

        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))
        #expect(book.narrators == names)
    }

    /// A narrator needs nothing but a Style value.
    ///
    /// `Contributor-ID:` gives a narrator a stable identity where the agent
    /// matched one, and most narrators on most libraries have no such match.
    /// Requiring one before showing a name would empty the screen for exactly
    /// the libraries that need it most, so Style alone is enough — the
    /// contributor identity is an addition to a narrator, never a condition
    /// for being one.
    @Test("A narrator with no Contributor-ID is still a narrator")
    func styleOnlyNarrators() throws {
        let json = """
        {"ratingKey":"900","title":"Dune",
         "Style":[{"id":1,"tag":"Scott Brick"},{"id":2,"tag":"Simon Vance"}],
         "Mood":[{"id":3,"tag":"Contributor-ID: narrator:audible:B002SQ5DR4 = Scott Brick"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        // Both are narrators; only one of them has an identity.
        #expect(book.narrators == ["Scott Brick", "Simon Vance"])
        #expect(book.contributors.count == 1)
        #expect(book.contributors.first?.displayName == "Scott Brick")
    }

    /// The `Guid` child is why `Tag.id` is a string in the first place.
    ///
    /// One type reads both lists, so making the numeric case work must not
    /// break the case it was originally written for.
    @Test("A Guid child still decodes with its string id")
    func guidChildStillDecodes() throws {
        let json = """
        {"ratingKey":"900","title":"Dune",
         "Guid":[{"id":"com.plexapp.agents.spokenmeta://work/OL893415W"},
                 {"id":"com.plexapp.agents.plexmusic://album/12345"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.guid == "com.plexapp.agents.spokenmeta://work/OL893415W")
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

    /// The ten namespaces the contract reserves.
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
                 {"tag":"Edition: Unabridged"},{"tag":"Work-ID: openlibrary:OL12345W"},
                 {"tag":"Contributor-ID: author:openlibrary:OL2162289A = Andy Weir"},
                 {"tag":"Work-Published: 1950"},{"tag":"Production: Full cast"},
                 {"tag":"Rating-Source: Audible"},{"tag":"Rating-Count: 48217"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.authors == ["Terry Pratchett"])
        #expect(book.series == ["Discworld"])
        #expect(book.language == "English")
        #expect(book.edition == "Unabridged")
        #expect(book.sequences == [BookSequence(series: "Discworld", position: "6")])
        #expect(book.workIdentity?.key == "spokenmeta:work:openlibrary:OL12345W")
        #expect(book.contributors.map(\.key) == ["spokenmeta:contributor:author:openlibrary:OL2162289A"])
        #expect(book.workPublishedYear == 1950)
        #expect(book.productionType == "Full cast")
        #expect(book.ratingSource == "Audible")
        #expect(book.ratingCount == 48217)
    }

    /// Everything the v2/v3 contract adds is optional. A library still on the
    /// v1 contract, or one where the agent simply had no evidence for these,
    /// must decode exactly as it did before any of this existed.
    @Test("The app works when v2/v3 metadata is absent")
    func v2AndV3MetadataIsOptional() throws {
        let json = """
        {"ratingKey":"900","title":"Wyrd Sisters",
         "Mood":[{"tag":"Terry Pratchett"},{"tag":"Series: Discworld"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.workIdentity == nil)
        #expect(book.contributors.isEmpty)
        #expect(book.workPublishedYear == nil)
        #expect(book.productionType == nil)
        #expect(book.ratingSource == nil)
        #expect(book.ratingCount == nil)
        // v1 fields are unaffected by v2/v3's total absence.
        #expect(book.authors == ["Terry Pratchett"])
        #expect(book.series == ["Discworld"])
    }

    /// Mirrors VocalisMeta's own published test vector
    /// (`malformed_reserved_values_are_ignored_not_authors` in
    /// `test-vectors-v3.json`) as directly as possible — same Moods, same
    /// expected result — rather than a version invented independently.
    /// Every malformed value here looks superficially plausible; the point
    /// is that each is rejected anyway, not silently displayed as though it
    /// were real.
    @Test("Malformed v3 values are ignored, matching VocalisMeta's own published test vector")
    func malformedV3ValuesAreIgnored() throws {
        let json = """
        {"ratingKey":"900","title":"A Book",
         "Mood":[{"tag":"Andy Weir"},
                 {"tag":"Contributor-ID: translator:audible:B00G0WYW92 = Someone"},
                 {"tag":"Contributor-ID: author:openlibrary:OL123W = Someone"},
                 {"tag":"Work-Published: unknown"},
                 {"tag":"Production: Probably full cast"},
                 {"tag":"Rating-Source: Unknown"},
                 {"tag":"Rating-Count: many"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.authors == ["Andy Weir"])
        #expect(book.contributors.isEmpty)
        #expect(book.workPublishedYear == nil)
        #expect(book.productionType == nil)
        #expect(book.ratingSource == nil)
        #expect(book.ratingCount == nil)
    }

    /// Reproduces the theorized cause of a real discrepancy: a live
    /// diagnostics fetch showing no series for a book whose cache had one.
    /// Before this test existed, `Mood` decoding was one `try?` around the
    /// whole array — a single malformed element anywhere in the list threw
    /// for the entire array, and the `try?` converted that into "every tag
    /// on this book is gone," not just the bad one. A book with a perfectly
    /// good `Series: Discworld` tag sharing a list with something this
    /// decoder chokes on — a tag object with a number where a string was
    /// expected, say — would have silently lost the series along with
    /// everything else in Mood, purely because of what it shared a list
    /// with, not anything wrong with the series tag itself.
    @Test("One malformed Mood entry does not wipe out the rest of the array")
    func oneMalformedMoodEntryDoesNotLoseTheRest() throws {
        let json = """
        {"ratingKey":"900","title":"Wyrd Sisters",
         "Mood":[{"tag":"Terry Pratchett"},
                 {"tag":12345},
                 {"tag":"Series: Discworld"},
                 {"tag":"Sequence: Discworld #6"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.authors == ["Terry Pratchett"])
        #expect(book.series == ["Discworld"])
        #expect(book.sequences.map(\.position) == ["6"])
    }

    /// The same failure mode, but the malformed element is the wrong shape
    /// entirely — a bare string rather than a tag object — rather than an
    /// object with one field of the wrong type.
    @Test("A Mood entry that is not an object at all is skipped, not fatal to the array")
    func moodEntryWithWrongShapeIsSkipped() throws {
        let json = """
        {"ratingKey":"900","title":"Wyrd Sisters",
         "Mood":["not an object", {"tag":"Series: Discworld"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.series == ["Discworld"])
    }

    /// `Ljudboksarkivet`, added alongside `Audible` for Swedish-language
    /// libraries. Placed right beside `malformedV3ValuesAreIgnored` above,
    /// which covers the same field with an invalid value — together they
    /// pin both edges of the same set membership check.
    @Test("Ljudboksarkivet is an accepted rating source alongside Audible")
    func ljudboksarkivetIsAcceptedRatingSource() throws {
        let json = """
        {"ratingKey":"900","title":"En Svensk Bok",
         "Mood":[{"tag":"Language: Swedish"},
                 {"tag":"Rating-Source: Ljudboksarkivet"},{"tag":"Rating-Count: 42"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.ratingSource == "Ljudboksarkivet")
        #expect(book.ratingCount == 42)
    }

    /// A book can have several credited contributors, each with its own
    /// `Contributor-ID:` Mood — not only one, the way `Work-ID:` is only one.
    @Test("Multiple contributors are all kept, by role")
    func multipleContributors() throws {
        let json = """
        {"ratingKey":"900","title":"A Book",
         "Mood":[{"tag":"Contributor-ID: author:openlibrary:OL2162289A = Andy Weir"},
                 {"tag":"Contributor-ID: narrator:librivox:20 = Ray Example"}]}
        """
        let book = try JSONDecoder().decode(PlexBook.self, from: Data(json.utf8))

        #expect(book.contributors.count == 2)
        #expect(book.contributors[0].role == "author")
        #expect(book.contributors[0].displayName == "Andy Weir")
        #expect(book.contributors[0].key == "spokenmeta:contributor:author:openlibrary:OL2162289A")
        #expect(book.contributors[1].role == "narrator")
        #expect(book.contributors[1].displayName == "Ray Example")
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
    @Test("A Guid child is read, and VocalisMeta's is preferred")
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

