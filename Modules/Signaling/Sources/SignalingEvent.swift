// Signaling event surface (Plan 4 Task 4): the AsyncStream element type the
// SignalingClient emits — connection lifecycle, decoded envelopes and
// protocol-level errors. Envelopes are immutable Objective-C objects marked
// Sendable in CoreBridge, so events can cross actor boundaries safely.

import CoreBridge

/// One validation problem of a hostile server frame, carried as a plain
/// value (the Objective-C LKValidationError never crosses into events).
public struct EnvelopeIssue: Sendable, Equatable {
    /// JSON path such as "v" or "body.sdp" (from the core's validation).
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// Protocol-level failures surfaced as `.error(SignalingError)` events or
/// thrown by `SignalingClient.send`. None of the payloads ever contain
/// tokens, SDP or ICE credentials — only codes, paths and byte counts.
public enum SignalingError: Error, Sendable, Equatable {
    /// A server frame that is not a valid protocol v1 envelope.
    case malformedEnvelope([EnvelopeIssue])
    /// A server frame larger than the wire limit (`LKTypes.maxEnvelopeBytes`);
    /// the socket stays until the server closes it.
    case oversizedFrame(bytes: Int)
    /// A server frame with a protocol version other than 1.
    case unsupportedVersion
    /// A session.error envelope from the server (code, detail).
    case sessionError(code: String, detail: String)
    /// An outgoing envelope exceeded the wire limit and was refused locally.
    case oversizedEnvelope(bytes: Int)
    /// An outgoing envelope could not be serialized to wire format.
    case invalidOutgoingEnvelope
    /// There is no live connection (connecting, backing off or stopped).
    case notConnected
    /// The token provider returned no token.
    case tokenMissing
    /// The transport or handshake failed; the payload is a static reason
    /// plus an OSStatus/URLError code number, never request material.
    case transportFailed(String)
}

/// What the SignalingClient streams to its consumer.
public enum SignalingEvent: Sendable {
    /// The socket is open and session.hello has been sent.
    case connected
    /// The connection dropped. `code` is the WebSocket close code the peer
    /// sent (4001 another socket, 4003 hello mismatch, ...); 1006 means the
    /// transport failed (or the pong timed out) without a wire close code.
    case disconnected(code: Int)
    /// A decoded server envelope (session.pong is consumed internally and
    /// never surfaced).
    case envelope(LKEnvelope)
    case error(SignalingError)
}
