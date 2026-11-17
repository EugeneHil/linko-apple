// CallReporting (Plan 4 Task 9): the seam the machine's ringing and report
// effects execute through. CallKit's provider adapter implements it on iOS
// (Task 10); the Mac call presenter implements it on macOS. The values are
// plain Swift mirrors of the machine's end reasons, so reporting surfaces
// never import CoreBridge.

import CoreBridge
import Foundation

/// Why a call ended (machine LKEndReason mirrored).
public enum CallEndReason: String, Sendable, Equatable {
    case normal
    case busy
    case rejected
    case cancelled
    case missed
    case timeout
    case error

    /// Maps the machine's end reason.
    init(_ reason: LKEndReason) {
        switch reason {
        case .normal: self = .normal
        case .busy: self = .busy
        case .rejected: self = .rejected
        case .cancelled: self = .cancelled
        case .missed: self = .missed
        case .timeout: self = .timeout
        case .error: self = .error
        @unknown default: self = .error
        }
    }

    /// The wire-facing report name (CallReport.endReason is stored verbatim).
    var reportName: String {
        rawValue
    }
}

/// The lifecycle reports the host executes: ringtone control and the
/// CallKit/presenter reports the machine emits as StartRinging, StopRinging,
/// ReportIncoming and ReportEnded effects.
public protocol CallReporting: Sendable {
    /// StartRinging: the local ringtone (incoming) or outgoing feedback.
    func startRinging() async
    /// StopRinging: the ringtone dies with accept, reject or cancel.
    func stopRinging() async
    /// ReportIncoming: a call is ringing for the user to answer.
    func reportIncoming(callId: String, peer: String, video: Bool) async
    /// ReportEnded: the call ended for `reason`.
    func reportEnded(callId: String, reason: CallEndReason) async
}

/// The end-of-call report upload seam (ReportsClient in production, Task 13
/// wiring). The coordinator uploads once and never retries a throw.
public protocol CallReportUploading: Sendable {
    /// POSTs the serialized CallReport JSON for the call.
    func post(callId: String, report: String) async throws
}
