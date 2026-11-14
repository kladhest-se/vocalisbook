import SwiftUI
import Audiobooks

public struct SyncHealthView: View {
    public let status: SyncStore.QueueStatus?
    public let cloudLastSuccess: Date?
    public let cloudPending: Int
    public let cloudEnabled: Bool
    private let retryCloud: @MainActor () -> Void
    public let isOffline: Bool
    private let retry: @MainActor () -> Void

    public init(status: SyncStore.QueueStatus?, cloudLastSuccess: Date?, cloudPending: Int, cloudEnabled: Bool,
                retryCloud: @escaping @MainActor () -> Void, isOffline: Bool, retry: @escaping @MainActor () -> Void) {
        self.cloudPending = cloudPending; self.cloudEnabled = cloudEnabled; self.retryCloud = retryCloud
        self.status = status; self.cloudLastSuccess = cloudLastSuccess; self.isOffline = isOffline; self.retry = retry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status {
                Text("Plex: \(status.pending) pending · \(status.failed) need retry")
                if let date = status.lastSuccess {
                    HStack { Text("Last Plex update"); Text(date, style: .relative) }
                }
                if let date = status.nextRetry {
                    HStack { Text("Next retry"); Text(date, style: .relative) }
                }
                if let error = status.lastError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                if isOffline { Text("Plex updates wait until offline mode is turned off.").font(.footnote) }
                Button("Sync with Plex now", action: retry).disabled(isOffline || status.pending == 0)
            } else { Text("Plex status is unavailable.") }
            Text(cloudEnabled ? "iCloud: \(cloudPending) pending" : "iCloud sync is off; changes stay on this device.")
            Button("Sync with iCloud now", action: retryCloud).disabled(!cloudEnabled)
            if let date = cloudLastSuccess {
                HStack { Text("Last iCloud update"); Text(date, style: .relative) }
            }
        }
    }
}
