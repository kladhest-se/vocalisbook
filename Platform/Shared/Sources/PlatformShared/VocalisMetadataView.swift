import SwiftUI
import UniformTypeIdentifiers
import Audiobooks
import PlexKit

/// Cached source information remains usable offline. Refresh and recording-state
/// copies are explicit user actions, with a separate review before any write.
public struct VocalisMetadataView: View {
    private let database: AudiobookDatabase
    private let ratingKey: String
    private let canReload: Bool
    private let reload: @MainActor () async throws -> Void
    private let pause: @MainActor () -> Void
    private let changed: @MainActor () -> Void
    @State private var info: BookMetadataInfo?
    @State private var message: String?
    @State private var busy = false
    @State private var reviewing: RecordingUpgradeStore.Review?
    @State private var recovery: RecordingUpgradeStore.Recovery?
    @State private var restoring = false
    #if !os(tvOS) && !os(watchOS)
    @State private var exporting = false
    @State private var document = ListeningBackupDocument(data: Data())
    #endif

    public init(database: AudiobookDatabase, ratingKey: String, canReload: Bool,
                reload: @escaping @MainActor () async throws -> Void,
                pause: @escaping @MainActor () -> Void, changed: @escaping @MainActor () -> Void) {
        self.database = database; self.ratingKey = ratingKey; self.canReload = canReload
        self.reload = reload; self.pause = pause; self.changed = changed
    }
    private var store: RecordingUpgradeStore { RecordingUpgradeStore(database: database) }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let info {
                    Text(info.status).font(.headline)
                    if let packet = info.packet {
                        Text("Overall matching method: " + Self.title(packet.match.method)).font(.footnote)
                        Text("Overall matching source: " + Self.title(packet.match.source)).font(.footnote)
                        ForEach(packet.fields.keys.sorted(), id: \.self) { name in
                            if let field = packet.fields[name] {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(Self.title(name)).font(.headline)
                                    Text("Agent snapshot: " + description(field, name: name, packet: packet))
                                    if !info.available || info.needsRefresh {
                                        Text("Previously reported source information").font(.footnote).foregroundStyle(.secondary)
                                    } else if info.mismatches.contains(name) {
                                        Text("Plex differs from the agent snapshot; the source is unverified.").font(.footnote).foregroundStyle(.secondary)
                                    } else {
                                        Text("\(field.provenance.label) · \(Self.state(field))").font(.footnote).foregroundStyle(.secondary)
                                        if let kind = field.provenance.dateKind { Text(Self.title(kind)).font(.footnote).foregroundStyle(.secondary) }
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .focusable()
                                Divider()
                            }
                        }
                        if !packet.identityUpgrades.isEmpty {
                            Text("Recording identity changes").font(.title3)
                            Text("Nothing is moved automatically. Review the saved state under each recording before choosing what to copy.")
                            ForEach(packet.identityUpgrades) { upgrade in
                                upgradeRow(upgrade, enabled: info.available && !info.needsRefresh)
                            }
                        }
                    }
                }
                if let recovery {
                    Text("Recovery snapshot").font(.title3)
                    Text("Original source data and the pre-copy snapshot are retained.").font(.footnote)
                    #if !os(tvOS) && !os(watchOS)
                    Button("Export recovery backup…") {
                        document = .init(data: recovery.data); exporting = true
                    }
                    #endif
                    if let previous = recovery.previousPosition {
                        Text("Position before copy: \(Format.duration(ms: previous.absoluteMs))\(previous.finishedAt == nil ? "" : " · Finished")")
                        Button("Review restoring the earlier position") {
                            pause()
                            do { self.recovery = try store.recovery(bookRatingKey: ratingKey); restoring = true }
                            catch { self.message = error.localizedDescription }
                        }
                    }
                }
                Button(busy ? "Reloading…" : "Reload from Plex") {
                    busy = true
                    Task {
                        do { try await reload(); load() }
                        catch { self.message = error.localizedDescription }
                        busy = false
                    }
                }.disabled(busy || !canReload)
                if let message { Text(message).foregroundStyle(.secondary) }
            }.padding(24)
        }
        .navigationTitle("Metadata sources")
        .task { load() }
        .sheet(item: $reviewing) { review in
            RecordingUpgradeReviewView(review: review, store: store, changed: { changed(); load() })
        }
        .confirmationDialog("Restore the position from before the copy?", isPresented: $restoring, titleVisibility: .visible) {
            Button("Restore earlier position") {
                guard let recovery else { return }
                do { try store.restoreEarlierPosition(recovery); changed(); load() }
                catch { self.message = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let previous = recovery?.previousPosition {
                Text("Use \(Format.duration(ms: previous.absoluteMs))\(previous.finishedAt == nil ? " · Unfinished" : " · Finished"). This replaces the current position and completion state. Copied bookmarks and history are retained.")
            }
        }
        #if !os(tvOS) && !os(watchOS)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "VocalisBook-recording-recovery") { result in
            if case .failure(let failure) = result { self.message = failure.localizedDescription }
        }
        #endif
    }
    private func upgradeRow(_ upgrade: VocalisMetaV4.Upgrade, enabled: Bool) -> some View {
        let label = upgrade.status == "verified_same_recording"
            ? "Agent reports matching recording evidence" : "Recording equivalence needs review"
        let identities = "\(upgrade.previous) → \(upgrade.current)"
        return VStack(alignment: .leading, spacing: 8) {
            Text(label)
            Text(identities).font(.caption)
            Button("Pause and review saved state") {
                pause()
                do { reviewing = try store.review(bookRatingKey: ratingKey, upgradeID: upgrade.id) }
                catch { self.message = error.localizedDescription }
            }.disabled(!enabled)
        }
    }

    private func load() {
        do { info = try LibraryStore(database: database).metadataInfo(bookRatingKey: ratingKey); recovery = try store.recovery(bookRatingKey: ratingKey) }
        catch { self.message = error.localizedDescription }
    }
    private func description(_ field: VocalisMetaV4.Field, name: String, packet: VocalisMetaV4) -> String {
        if name == "artwork" { return field.value == .null ? "Revision unknown" : "Agent artwork revision available" }
        if name == "series" {
            return packet.series.memberships.map {
                let primary = $0.ref == packet.series.primaryRef ? " · Primary" : ""
                let provider = $0.providerID.map { " · \($0.source)\($0.scope.isEmpty ? "" : " (\($0.scope.uppercased()))")" } ?? ""
                return $0.title + ($0.sequence.isEmpty ? "" : " · Book " + $0.sequence) + primary + provider
            }.joined(separator: "\n").v4Nonempty ?? "No published memberships"
        }
        if name == "contributors", let values = field.value.strings {
            return values.compactMap { ContributorIdentity(mood: String($0.dropFirst(16))) }.map {
                $0.displayName + ($0.isProviderBacked ? " · Provider identifier" : " · Name-based identifier")
            }.joined(separator: "\n").v4Nonempty ?? "No published credits"
        }
        return field.value.string ?? field.value.strings?.joined(separator: ", ").v4Nonempty ?? "No published value"
    }
    private static func title(_ value: String) -> String { value.replacingOccurrences(of: "_", with: " ").capitalized }
    private static func state(_ field: VocalisMetaV4.Field) -> String {
        switch field.state {
        case .known: field.stale ? "Retained older value" : "Published value"
        case .unknown: "Unknown"
        case .unavailable: "Temporarily unavailable"
        case .cleared: "Deliberately cleared"
        }
    }
}

private struct RecordingUpgradeReviewView: View {
    @State var review: RecordingUpgradeStore.Review
    let store: RecordingUpgradeStore
    let changed: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var position = false
    @State private var bookmarks = false
    @State private var history = false
    @State private var confirming = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summary("Previous saved state", review.previous)
                    summary("Current saved state", review.current)
                    if !review.conflicts.isEmpty {
                        Text("Review differences: " + review.conflicts.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", "))
                    }
                    Text("Chapter alignment is not inferred. Saved positions use elapsed book time. The original data is retained, and a pre-copy recovery snapshot is saved.")
                    Toggle("Use previous position and finished state", isOn: $position).disabled(!review.canCopyPosition)
                    Toggle("Copy bookmarks", isOn: $bookmarks).disabled(review.previous.bookmarks == 0)
                    Toggle("Copy listening history", isOn: $history).disabled(review.previous.sessions == 0)
                    if !review.canCopyPosition { Text("Copying a position requires a known recording length that contains the saved position.").font(.footnote) }
                    if review.alreadyCopied { Text("This identity change has already been copied. Originals and recovery data remain available.") }
                    Button("Copy selected saved data") { confirming = true }
                        .disabled(review.alreadyCopied || (!position && !bookmarks && !history))
                    Button("Refresh review") {
                        do { review = try store.review(bookRatingKey: review.bookRatingKey, upgradeID: review.upgrade.id); position = false; self.message = nil }
                        catch { self.message = error.localizedDescription }
                    }
                    if let message { Text(message).foregroundStyle(.secondary) }
                }.padding(24)
            }
            .navigationTitle("Review recording upgrade")
            .toolbar { ToolbarItem { Button("Close") { dismiss() } } }
            .confirmationDialog("Copy the selected saved data?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Copy data") {
                    do {
                        _ = try store.confirm(review, usePreviousPosition: position, copyBookmarks: bookmarks, copyHistory: history)
                        changed(); dismiss()
                    } catch { self.message = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmationDescription)
            }
        }
    }
    private var confirmationDescription: String {
        var text = position ? "Replace the current position and completion state. " : "Keep the current position and completion state. "
        if bookmarks { text += "Copy \(review.previous.bookmarks) bookmarks. " }
        if history { text += "Copy \(review.previous.sessions) sessions. " }
        return text + "Original source records are retained. Accepted changes use your normal sync settings."
    }

    private func summary(_ title: String, _ state: RecordingUpgradeStore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(state.title)
            Text(state.identity).font(.caption)
            Text(state.durationMs.map { "Recording length: " + Format.duration(ms: $0) } ?? "Recording length unknown")
            Text(state.positionMs.map { "Saved position: " + Format.duration(ms: $0) } ?? "No saved position")
            Text("\(state.finished ? "Finished" : "Not marked finished") · \(state.bookmarks) bookmarks · \(state.sessions) sessions")
        }.accessibilityElement(children: .combine).focusable()
    }
}

private extension String {
    var v4Nonempty: String? { isEmpty ? nil : self }
}
