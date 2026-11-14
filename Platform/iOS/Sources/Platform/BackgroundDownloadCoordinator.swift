import Foundation
import os
import UniformTypeIdentifiers
import Audiobooks
import PlatformShared

/// Fetches book files and puts them where the player can find them.
///
/// A background `URLSessionConfiguration`, so a download survives the app being
/// suspended — an audiobook is hundreds of megabytes and nobody is going to hold
/// the app open for it. That has consequences the ordinary session does not:
///
///  - It must be a *separate* session from the one PlexKit uses for metadata. A
///    background session cannot serve ordinary requests.
///  - The identifier must be stable across launches, or the system hands the
///    finished transfers to a session nobody is listening to.
///  - The delegate is called on the session's own queue, not the main one, so
///    nothing here may assume otherwise.
/// `@Observable`, because `revision` exists to be watched.
///
/// Without it the property changed and no view ever redrew: the progress bar
/// sat at 0% for the whole download and only showed the truth after navigating
/// away and back, which rebuilt the view and re-read the store. A published
/// value nothing can observe is a value nobody sees.
@MainActor
@Observable
public final class BackgroundDownloadCoordinator {

    // A background-only launch can precede the first SwiftUI scene. Retain and
    // reuse that session when the app model later starts; two sessions with the
    // same background identifier cannot both own the system's callbacks.
    private static var applicationCoordinator: BackgroundDownloadCoordinator?

    public static func forApplication(
        store: DownloadStore, allowsExpensiveNetwork: Bool = false
    ) -> BackgroundDownloadCoordinator {
        if let applicationCoordinator { return applicationCoordinator }
        let coordinator = BackgroundDownloadCoordinator(
            store: store, allowsExpensiveNetwork: allowsExpensiveNetwork
        )
        applicationCoordinator = coordinator
        return coordinator
    }

    public static func reconnectForBackgroundEvents() throws {
        if applicationCoordinator == nil {
            let database = try StoreLocation.open()
            _ = forApplication(
                store: DownloadStore(database: database),
                allowsExpensiveNetwork: UserDefaults.standard.bool(
                    forKey: "downloads.allowExpensiveNetwork"
                )
            )
        }
        applicationCoordinator?.resumeAfterLaunch()
    }

    private let store: DownloadStore
    private let delegate: DownloadDelegate
    private let session: URLSession
    private let gate: DownloadTaskGate
    private let transfers: DownloadTransferQueue

    /// Bumped whenever a transfer moves, so views can watch one value.
    public private(set) var revision = 0

    /// Whether a download may run on a metered or constrained connection.
    ///
    /// Fixed at construction, and it has to be: a background `URLSession` reads
    /// its configuration once, when the session is made, and a session with a
    /// given identifier cannot be replaced while the old one lives. So the
    /// preference is read at launch and a change takes effect at the next one —
    /// which the settings row says, rather than appearing to do something
    /// immediately and not.
    private let allowsExpensiveNetwork: Bool

    public init(store: DownloadStore, allowsExpensiveNetwork: Bool = false) {
        self.store = store
        self.allowsExpensiveNetwork = allowsExpensiveNetwork
        let gate = DownloadTaskGate()
        self.gate = gate
        self.delegate = DownloadDelegate(store: store, gate: gate)

        let configuration = URLSessionConfiguration.background(
            withIdentifier: BackgroundDownloadEvents.sessionIdentifier
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        // A 900 MB file over a homelab connection can take a while; the default
        // 60-second resource timeout would abandon it.
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60

        // Wi-Fi only, unless told otherwise.
        //
        // The system holds the transfer until the network allows it rather than
        // failing it, which is the part a hand-rolled check cannot do: a
        // background session outlives the app, so an app-side "is this Wi-Fi"
        // test can only be true at the moment a transfer is *queued* and says
        // nothing about the hour it actually runs in.
        //
        // The tools README claimed `NWPathMonitor` was "consulted before each
        // job". Nothing consulted anything — and the monitor would have been the
        // wrong instrument anyway. These two flags are.
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetwork
        configuration.allowsConstrainedNetworkAccess = allowsExpensiveNetwork
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )

        self.session = session
        self.transfers = DownloadTransferQueue(gate: gate) {
            await session.allTasks.map { task in
                DownloadTransferQueue.Transfer(
                    key: task.taskDescription, id: task.taskIdentifier,
                    isActive: task.state == .running || task.state == .suspended,
                    cancel: { task.cancel() }
                )
            }
        }
        delegate.onChange = { [weak self] in self?.revision += 1 }
    }

    // MARK: - Locations

    /// Where downloaded files live.
    ///
    /// Application Support, excluded from backup: a 40 GB audiobook library must
    /// never enter iCloud Backup, and neither should half of one.
    ///
    /// `nonisolated` because `@MainActor` on the type isolates its static
    /// members as well, and the delegate needs this from its own queue. Nothing
    /// here touches actor state — it is `FileManager` and a path.
    public nonisolated static func downloadsDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("VocalisBook/Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var mutable = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutable.setResourceValues(values)
        }
        return directory
    }

    /// The local file for a part, if it is there.
    /// Whether a stored file is really there.
    ///
    /// Passed to `DownloadStore.state` so the decision stays in `Audiobooks`
    /// while the filesystem stays here — this package owns the directory, and
    /// Core owns what "downloaded" means.
    public nonisolated func hasFile(atRelativePath relativePath: String) -> Bool {
        guard let directory = try? Self.downloadsDirectory() else { return false }
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(relativePath).path
        )
    }

    public func localURL(forPartCacheKey key: String) -> URL? {
        // One binding, not two: `try?` on a function already returning `String?`
        // flattens rather than nesting, so there is no second optional to unwrap.
        guard let relative = try? store.relativePath(forPartCacheKey: key),
              let directory = try? Self.downloadsDirectory()
        else { return nil }

        let url = directory.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Queue

    /// Downloads a whole book.
    ///
    /// `urlForSegment` is supplied by the caller because building a stream URL
    /// needs the server connection, which this has no business knowing about.
    public func download(
        bookRatingKey: String,
        segments: [BookTimeline.Segment],
        urlForSegment: (BookTimeline.Segment) -> URL
    ) throws {
        try store.enqueue(bookRatingKey: bookRatingKey, segments: segments)

        let urls = Dictionary(segments.map { ($0.partCacheKey, urlForSegment($0)) },
                              uniquingKeysWith: { first, _ in first })
        transfers.enqueue(keys: segments.map(\.partCacheKey)) { [weak self] key in
            guard let self, let record = try? self.store.record(partCacheKey: key),
                  !record.requiresVerification, self.localURL(forPartCacheKey: key) == nil, let url = urls[key] else { return }
            let task = self.session.downloadTask(with: url)
            task.taskDescription = key
            self.gate.register(id: task.taskIdentifier, key: key)
            task.resume()
        }
        revision += 1
    }

    /// Removes a book's files and forgets them.
    public func evict(bookRatingKey: String) throws {
        let keys = try store.partCacheKeys(bookRatingKey: bookRatingKey)
        transfers.cancel(keys: Set(keys))
        let paths = try store.evict(bookRatingKey: bookRatingKey)
        let directory = try Self.downloadsDirectory()
        for path in paths {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(path))
        }
        revision += 1
    }

    /// Removes every downloaded file and forgets them all.
    ///
    /// The same two steps as `evict(bookRatingKey:)` — the store owns the rows,
    /// this owns the bytes — over everything rather than one book.
    ///
    /// Here rather than in the app, because the app had no business knowing that
    /// a relative path is resolved against a downloads directory this type
    /// computes. Reaching past it meant calling `evict(partCacheKey:)`, which is
    /// the protocol's method and takes a different kind of key entirely.
    public func evictAll() throws {
        transfers.cancelAll(knownKeys: Set(try store.partCacheKeys()))
        let paths = try store.evictAll()
        let directory = try Self.downloadsDirectory()
        for path in paths {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(path))
        }
        revision += 1
    }

    public func totalBytesOnDisk() throws -> Int {
        try store.totalBytes()
    }

    /// Deletes downloaded files nothing has a record of.
    ///
    /// Two changes orphaned files on devices that had already downloaded books:
    /// the stored filename gained a real extension, and the part cache key
    /// gained a fallback for servers that send no `updatedAt`. Both are correct
    /// and both change the name a file is stored under, so the old ones stopped
    /// being found — invisible to the app and still hundreds of megabytes each.
    ///
    /// Conservative on purpose: a file is removed only when the store knows of
    /// no record pointing at it. A transfer in flight has its record already, so
    /// its eventual file is not orphaned by being mid-download.
    public func pruneOrphanedFiles() {
        guard let directory = try? Self.downloadsDirectory(),
              let known = try? store.allRelativePaths(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
              )
        else { return }

        for file in files where !known.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Picks up transfers that finished while the app was not running.
    ///
    /// The system holds them and delivers them to a session with the same
    /// identifier, which is why constructing this at launch matters even when
    /// nothing is being downloaded right now.
    public func resumeAfterLaunch() {
        let store = self.store
        session.getAllTasks { tasks in
            for task in tasks {
                guard let key = task.taskDescription,
                      let record = try? store.record(partCacheKey: key),
                      !record.requiresVerification else {
                    task.cancel()
                    continue
                }
            }
        }
    }
}

/// The delegate.
///
/// Deliberately a separate object, and deliberately not `@MainActor`: the
/// session calls it on its serial delegate queue. The Sendable store commits
/// synchronously there; only UI notifications hop to the main actor. This keeps
/// database writes ahead of the system's background-completion handoff.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// What to call the file on disk.
    ///
    /// It used to be `<cacheKey>.audio`, which is not an extension anything
    /// recognises — and that is why a downloaded book would not play. For a
    /// local file `AVURLAsset` has no `Content-Type` to go on and infers the
    /// container from the extension; given one it does not know, the item fails
    /// to load. Streaming worked throughout, because an HTTP response says what
    /// it is, so the fault looked like the downloads feature rather than the
    /// filename.
    ///
    /// The Plex part path ends in the real filename, so its extension is the
    /// first and best answer. The response's MIME type is the fallback for a
    /// part key that somehow carries none. `m4b` last, because a wrong guess is
    /// no worse than the unknown extension this replaces and audiobooks are
    /// overwhelmingly that.
    static func fileExtension(for task: URLSessionTask) -> String {
        DownloadFileNaming.fileExtension(
            forPath: task.originalRequest?.url?.path,
            mimeType: task.response?.mimeType
        )
    }

    private let store: DownloadStore
    private let gate: DownloadTaskGate
    /// Isolated to the main actor, because what it does is mutate a property
    /// that lives there. The delegate already calls it from inside a
    /// `Task { @MainActor }`; this makes the type say so.
    var onChange: (@MainActor @Sendable () -> Void)?

    init(store: DownloadStore, gate: DownloadTaskGate) {
        self.store = store
        self.gate = gate
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let key = downloadTask.taskDescription else { return }

        // Checked before anything is written, not after: a full sync running
        // at the exact moment this completes can have already evicted the row
        // — see DownloadStore.evictMissingFromLibrary — if the book it belongs
        // to no longer exists locally. Moving the file first and finding out
        // afterwards, in the dispatched markComplete below, wrote a fully
        // downloaded file with nothing pointing at it: not dangerous, since
        // pruneOrphanedFiles reclaims it at the next launch, but a needless
        // disk write for a file already known to belong to nothing. The
        // network transfer has already happened either way — only the write
        // is avoidable here, not the bandwidth already spent reaching this
        // point.
        guard (try? store.record(partCacheKey: key)) != nil else { return }

        // The file at `location` is deleted the moment this method returns, so
        // it has to be moved now, synchronously, on this queue — not after a
        // hop to the main actor.
        do {
            try DownloadResponseValidation.validate(downloadTask.response)
            let directory = try BackgroundDownloadCoordinator.downloadsDirectory()
            let relative = "\(key)-\(downloadTask.taskIdentifier).\(Self.fileExtension(for: downloadTask))"
            let destination = directory.appendingPathComponent(relative)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)

            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let bytes = (attributes?[.size] as? Int) ?? 0
            let store = self.store
            let onChange = self.onChange
            // Commit before URLSession announces that its background events
            // are finished; the system may suspend us after that handoff.
            let accepted = try gate.performIfCurrent(id: downloadTask.taskIdentifier, key: key) {
                try store.markComplete(partCacheKey: key, relativePath: relative, bytes: bytes)
            }
            if !accepted { try? FileManager.default.removeItem(at: destination); return }
            Task { @MainActor in onChange?() }
        } catch {
            let store = self.store
            let onChange = self.onChange
            let message = error.localizedDescription
            _ = try? gate.performIfCurrent(id: downloadTask.taskIdentifier, key: key) {
                try store.markFailed(partCacheKey: key, error: message)
            }
            Task { @MainActor in onChange?() }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let key = downloadTask.taskDescription else { return }
        let done = Int(totalBytesWritten)
        let total = totalBytesExpectedToWrite > 0 ? Int(totalBytesExpectedToWrite) : nil
        let store = self.store
        let onChange = self.onChange
        _ = try? gate.performIfCurrent(id: downloadTask.taskIdentifier, key: key) {
            try store.markDownloading(partCacheKey: key, bytesDone: done, bytesTotal: total)
        }
        Task { @MainActor in onChange?() }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in BackgroundDownloadEvents.shared.finishEvents() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error, let key = task.taskDescription else { return }
        let store = self.store
        let onChange = self.onChange
        let message = error.localizedDescription

        // Logged as well as stored.
        //
        // The stored copy reaches a tooltip on a screen somebody has to be
        // looking at; this reaches Console on a device that is misbehaving. A
        // download that fails for everything — no space, a refused range
        // request, an expired token — looked the same from outside, and the one
        // question worth answering is which.
        Logger(subsystem: "se.kladhest.vocalisbook", category: "downloads")
            .error("Download failed for \(key, privacy: .public): \(message, privacy: .public)")
        _ = try? gate.performIfCurrent(id: task.taskIdentifier, key: key) {
            try store.markFailed(partCacheKey: key, error: message)
        }
        Task { @MainActor in onChange?() }
    }
}

/// What a downloaded file is called.
///
/// Its own type, and internal rather than private, so a test can reach it. The
/// delegate is private — correctly, nothing else should hold one — and the
/// decision used to live inside it taking a `URLSessionTask`, which cannot be
/// constructed with a chosen request and response. So the logic that decided a
/// downloaded book would not play was, by construction, impossible to test.
///
/// Tested from `Platform/macOS`, which is the only one of the three platform
/// packages `swift test` can run — iOS and tvOS build against a generic
/// simulator destination with nothing booted. `scripts/check-drift.py` asserts this file is
/// byte-identical across the copies, so testing one covers all of them.
enum DownloadFileNaming {

    /// The Plex part path ends in the real filename, so its extension is the
    /// first and best answer. The response's MIME type is the fallback. `m4b`
    /// last, because a wrong guess is no worse than the unknown extension this
    /// replaced and audiobooks are overwhelmingly that.
    static func fileExtension(forPath path: String?, mimeType: String?) -> String {
        if let path, case let ext = (path as NSString).pathExtension, !ext.isEmpty {
            return ext.lowercased()
        }
        if let mimeType,
           let type = UTType(mimeType: mimeType),
           let ext = type.preferredFilenameExtension {
            return ext
        }
        return "m4b"
    }
}
