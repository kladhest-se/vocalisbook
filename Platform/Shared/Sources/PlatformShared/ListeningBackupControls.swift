#if !os(tvOS) && !os(watchOS)
import SwiftUI
import UniformTypeIdentifiers
import Audiobooks

public struct ListeningBackupDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.json] }
    public var data: Data
    public init(data: Data) { self.data = data }
    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ListeningBackupError.invalid }
        self.data = data
    }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Both native file pickers operate only after the user chooses an action.
/// Inspect and review the selected backup before the transactional merge.
public struct ListeningBackupControls: View {
    private let export: @MainActor () throws -> Data
    private let restore: @MainActor (Data) throws -> Int
    @State private var document = ListeningBackupDocument(data: Data())
    @State private var exporting = false
    @State private var importing = false
    @State private var reviewing = false
    @State private var importData: Data?
    @State private var preview = ""
    @State private var message: String?

    public init(export: @escaping @MainActor () throws -> Data, restore: @escaping @MainActor (Data) throws -> Int) {
        self.export = export
        self.restore = restore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Export listening backup…") {
                do { document = .init(data: try export()); exporting = true }
                catch { message = error.localizedDescription }
            }
            Button("Import listening backup…") { importing = true }
            Text("Backs up your place, bookmarks, history and book speeds. Imports keep newer local changes. Audio files and account details are not included.")
                .font(.footnote).foregroundStyle(.secondary)
            if let message { Text(message).font(.footnote).textSelection(.enabled) }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "VocalisBook-listening-backup") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size > ListeningBackupStore.maximumBytes { throw ListeningBackupError.tooLarge }
                let data = try Data(contentsOf: url)
                let backup = try ListeningBackupStore.inspect(data)
                preview = backup.summary
                importData = data
                reviewing = true
            } catch { message = error.localizedDescription }
        }
        .confirmationDialog("Merge this listening backup?", isPresented: $reviewing, titleVisibility: .visible) {
            Button("Merge backup") {
                guard let data = importData else { return }
                do { message = "Merged \(try restore(data)) records. Books not cached here will recover their data when they return." }
                catch { message = error.localizedDescription }
                importData = nil
            }
            Button("Cancel", role: .cancel) { importData = nil }
        } message: {
            Text("\(preview). Existing data is kept; newer local edits take priority. Imported changes use your normal sync settings.")
        }
    }
}
#endif
