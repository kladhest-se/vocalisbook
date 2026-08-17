import Foundation

/// One syncable row, in a shape that knows nothing about CloudKit.
///
/// The seam is the same one `HTTPClient` draws: this package decides *what*
/// syncs and how conflicts resolve, and a platform package turns these into
/// `CKRecord`s and back. `Core` importing CloudKit would put an Apple framework
/// under the layer whose whole point is that its tests run with nothing
/// installed.
///
/// Plex is not involved. It has no third-party user-data API, so bookmarks,
/// listening history, per-book speed and hand-made collections have nowhere to
/// live but the device and iCloud. That is also why the Apple TV treats its
/// database as a cache: on that platform this is the only thing that makes the
/// data survive.
public struct CloudRecord: Sendable, Hashable, Identifiable {

    /// What a record is. The raw value is the CloudKit record type, so renaming
    /// a case orphans every record already in the container — these are wire
    /// values, not names.
    public enum Kind: String, Sendable, CaseIterable {
        /// Where somebody is in a book.
        ///
        /// Plex owns this too, and remains the authority: other Plex clients
        /// read it from there, and an arriving cloud position is pushed on to
        /// the server rather than kept private. This case exists because the
        /// Plex path is pull-based and per-book — it cannot say "this book is
        /// now in progress" to a device that has never opened it — and that is
        /// exactly what a Continue listening list needs to know.
        case progress = "Progress"
        case bookmark = "Bookmark"
        case bookSettings = "BookSettings"
        case listeningSession = "ListeningSession"
    }

    public let kind: Kind
    public let id: String
    /// Bumped by the store on every local edit. The whole conflict rule.
    public let revision: Int
    /// A tombstone still has to travel: deleting locally and going quiet leaves
    /// the row alive on every other device, which then pushes it back.
    public let isDeleted: Bool
    public let fields: [String: CloudValue]

    public init(
        kind: Kind,
        id: String,
        revision: Int,
        isDeleted: Bool = false,
        fields: [String: CloudValue]
    ) {
        self.kind = kind
        self.id = id
        self.revision = revision
        self.isDeleted = isDeleted
        self.fields = fields
    }

    /// Unique across kinds, because CloudKit record names are one namespace and
    /// a bookmark id could otherwise collide with a book's rating key.
    public var recordName: String { "\(kind.rawValue)-\(id)" }
}

/// The value types a syncable field can hold.
///
/// Deliberately small. Everything stored here is a string, a number, a date or a
/// flag, and an enum with four cases is a thing a platform mapper can switch over
/// exhaustively — where `Any` is a thing it can get wrong at runtime.
public enum CloudValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case date(Date)

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let value) = self { return value }
        return nil
    }

    public var dateValue: Date? {
        if case .date(let value) = self { return value }
        return nil
    }
}
