// FileBubbleProgress (Plan 4 Task 12): binds the transfer-events stream
// (fan-out of TransferCoordinator.events) onto per-file progress fractions
// for the conversation's file bubbles. Completion and cancellation clear
// the entry — the bubble shows no bar once the transfer ends.

import FileTransfer
import Foundation

@MainActor
@Observable
public final class FileBubbleProgress {
    public private(set) var progressByFileId: [String: Double] = [:]

    public init() {}

    public func handle(_ event: TransferEvent) {
        switch event {
        case let .progress(progress):
            guard progress.totalBytes > 0 else { return }
            progressByFileId[progress.fileId] =
                Double(progress.bytesTransferred) / Double(progress.totalBytes)
        case let .completed(completed):
            progressByFileId.removeValue(forKey: completed.fileId)
        case let .cancelled(_, fileId):
            progressByFileId.removeValue(forKey: fileId)
        case let .failed(_, fileId, _):
            progressByFileId.removeValue(forKey: fileId)
        }
    }

    /// The in-flight fraction (0...1) for a file bubble; nil when idle.
    public func progress(for fileId: String) -> Double? {
        progressByFileId[fileId]
    }
}
