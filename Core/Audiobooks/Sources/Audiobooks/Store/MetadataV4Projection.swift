import Foundation
import GRDB
import PlexKit

/// Native Plex values win over a mismatched agent snapshot. V4 supplies field
/// availability, deliberate clears and relationship primacy, never listening IDs.
struct MetadataV4Projection {
    let packet: VocalisMetaV4?
    let payload: Data?
    let available: Bool
    var mismatches = Set<String>()
    var authors: [String]
    var narrators: [String]
    var series: [String]
    var sequences: [BookSequence]
    var contributors: [ContributorIdentity]
    var language: String?
    var edition: String?
    var work: String?
    var workPublication: Int?
    var recordingDate: String?

    init(book: PlexBook, previous: BookRecord?, db: Database) throws {
        let old = previous.flatMap { record in record.v4Payload.flatMap {
            try? VocalisMetaV4.decodePayload($0, recordingKey: record.identityKey?.hasPrefix("spokenmeta:") == true ? record.identityKey : nil)
        } }
        let incoming = book.metadataV4
        packet = incoming
        payload = incoming?.payloadData ?? old?.payloadData
        available = incoming != nil
        authors = book.authors; narrators = book.narrators; series = book.series
        sequences = book.sequences; contributors = book.contributors
        language = book.language; edition = book.edition; work = book.workIdentity?.key
        workPublication = book.workPublishedYear; recordingDate = book.recordingReleaseDate
        func retain(_ field: String) -> Bool {
            guard let incoming else { return old != nil }
            let state = incoming.fields[field]?.state
            return state == .unknown || state == .unavailable
        }
        func names(_ table: String) throws -> [String] {
            guard let previous else { return [] }
            return try String.fetchAll(db, sql: "SELECT name FROM \(table) WHERE book_rating_key = ? ORDER BY \(table == "book_series" ? "display_order, " : "")name", arguments: [previous.ratingKey])
        }
        if authors.isEmpty && retain("authors") { authors = try names("book_author") }
        if narrators.isEmpty && retain("narrators") { narrators = try names("book_narrator") }
        if series.isEmpty && retain("series") {
            series = try names("book_series")
            if let previous {
                sequences = try Row.fetchAll(db, sql: "SELECT series, position FROM book_sequence WHERE book_rating_key = ?", arguments: [previous.ratingKey]).compactMap {
                    guard let name: String = $0["series"], let position: String = $0["position"] else { return nil }
                    return BookSequence(mood: "\(name) #\(position)")
                }
            }
        }
        if contributors.isEmpty && retain("contributors"), let previous {
            contributors = try ContributorRecord.filter(Column("book_rating_key") == previous.ratingKey).fetchAll(db).compactMap {
                let key = String($0.contributorKey.dropFirst("spokenmeta:contributor:".count))
                return ContributorIdentity(mood: "\(key) = \($0.displayName)")
            }
        }
        if language == nil && retain("language") { language = previous?.language }
        if edition == nil && retain("edition") { edition = previous?.edition }
        if work == nil && retain("work") { work = previous?.workIdentity }
        if workPublication == nil && retain("work_publication") { workPublication = previous?.workPublishedYear }
        if recordingDate == nil && retain("recording_date") { recordingDate = previous?.recordingReleaseDate }
        guard let packet = incoming else { return }
        func compare(_ field: String, native: MetadataJSON) -> Bool {
            guard let data = packet.fields[field] else { return false }
            if let a = native.strings, let b = data.value.strings { return Set(a) == Set(b) }
            return native == data.value
        }
        let native: [String: MetadataJSON] = [
            "title": .string(book.title), "authors": .array(book.authors.map(MetadataJSON.string)),
            "narrators": .array(book.narrators.map(MetadataJSON.string)),
            "recording_date": book.recordingReleaseDate.map(MetadataJSON.string) ?? .null,
            "language": book.language.map(MetadataJSON.string) ?? .null,
            "edition": book.edition.map(MetadataJSON.string) ?? .null,
            "work": book.workIdentity.map { .string(String($0.key.dropFirst("spokenmeta:work:".count))) } ?? .null,
            "work_publication": book.workPublishedYear.map { .string(String($0)) } ?? .null
        ]
        for (name, value) in native {
            guard let field = packet.fields[name] else { continue }
            let nonemptyNative = value != .null && value != .array([]) && value != .string("")
            if (field.state == .known || field.state == .cleared || nonemptyNative) && !compare(name, native: value) { mismatches.insert(name) }
        }
        let parsed = packet.fields["contributors"]?.value.strings?.compactMap { ContributorIdentity(mood: String($0.dropFirst(16))) } ?? []
        if (!book.contributors.isEmpty || packet.fields["contributors"]?.state == .known || packet.fields["contributors"]?.state == .cleared), Set(parsed) != Set(book.contributors) { mismatches.insert("contributors") }
        let nativeSeries = Set(book.series)
        let packetSeries = Set(packet.series.memberships.map(\.title))
        let positionsMatch = packet.series.memberships.allSatisfy { m in
            (book.sequences.first { $0.series == m.title }?.position ?? "") == m.sequence
        }
        if nativeSeries == packetSeries && positionsMatch {
            if let primary = packet.series.primaryRef, let first = packet.series.memberships.first(where: { $0.ref == primary }) {
                series = [first.title] + series.filter { $0 != first.title }.sorted()
            } else { series.sort() } // no declared primacy; don't invent it from Mood order
        } else if !book.series.isEmpty || packet.fields["series"]?.state == .known || packet.fields["series"]?.state == .cleared {
            mismatches.insert("series")
        }
    }
}

public struct BookMetadataInfo: Sendable {
    public let packet: VocalisMetaV4?
    public let available: Bool
    public let mismatches: Set<String>
    public let needsRefresh: Bool
    public var status: String {
        if packet == nil { return "VocalisMeta v4 is not available for this book." }
        if !available { return "Showing retained metadata; a current valid v4 packet is unavailable." }
        if needsRefresh { return "A metadata detail refresh is pending." }
        return "Validated VocalisMeta v4 metadata"
    }
}
