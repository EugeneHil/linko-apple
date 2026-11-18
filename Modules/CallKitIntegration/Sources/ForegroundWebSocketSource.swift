// ForegroundWebSocketSource (Plan 4 Task 10 / LNK-36): the sole invite
// source — call.invite envelopes on the signaling event stream become
// IncomingCall values. The coordinator ignores call.invite in its own copy
// of the events stream, so invites flow to the machine only through here
// (they are never applied twice). The splitter hands one SignalingClient
// stream to both consumers (AsyncStream is single-consumer).

import Calls
import CoreBridge
import Foundation
import Signaling

/// The v0.1 invite source over the foreground WebSocket's events (PushKit
/// plugs in later behind the same IncomingCallSource protocol, spec §2).
public final class ForegroundWebSocketSource: IncomingCallSource {
    /// Single consumer: the coordinator.
    public let calls: AsyncStream<IncomingCall>

    private let continuation: AsyncStream<IncomingCall>.Continuation
    private let pump: Task<Void, Never>

    public init(events: AsyncStream<SignalingEvent>) {
        let (stream, streamContinuation) = AsyncStream<IncomingCall>.makeStream(bufferingPolicy: .unbounded)
        calls = stream
        continuation = streamContinuation
        pump = Task {
            for await event in events {
                guard case let .envelope(envelope) = event,
                      envelope.type == LKTypes.callInvite,
                      let body = try? LKCallInvite.from(bodyJSON: envelope.bodyJSON)
                else { continue }
                streamContinuation.yield(IncomingCall(
                    callId: body.callId,
                    peer: body.to,
                    video: body.media == "video"
                ))
            }
            streamContinuation.finish()
        }
    }

    deinit {
        pump.cancel()
        continuation.finish()
    }

    /// Splits one SignalingClient event stream into the coordinator's copy
    /// and the invite-filtering source. The pump lives until the client's
    /// stream finishes; the coordinator drops call.invite, so an invite
    /// reaches the machine only through the source.
    public static func split(_ events: AsyncStream<SignalingEvent>) -> SignalingEventSplit {
        let (coordinatorEvents, coordinatorContinuation) = AsyncStream<SignalingEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (sourceEvents, sourceContinuation) = AsyncStream<SignalingEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let source = ForegroundWebSocketSource(events: sourceEvents)
        let pump = Task {
            for await event in events {
                coordinatorContinuation.yield(event)
                sourceContinuation.yield(event)
            }
            coordinatorContinuation.finish()
            sourceContinuation.finish()
        }
        return SignalingEventSplit(events: coordinatorEvents, source: source, pump: pump)
    }
}

/// The two consumers of one SignalingClient event stream.
public struct SignalingEventSplit: Sendable {
    /// The coordinator's copy of every event.
    public let events: AsyncStream<SignalingEvent>
    /// The invite-filtering source over the same events.
    public let source: ForegroundWebSocketSource
    /// The splitter's pump; retained so its lifetime stays explicit.
    let pump: Task<Void, Never>
}
