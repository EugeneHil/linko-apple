// Shared fixtures for the CallEngine test targets (Plan 4 Task 7 / LNK-33):
// the shared constants, the engine fixture builder that wires a fresh engine
// to one set of fakes (the fakes themselves live in FakeRTCWorld.swift), and
// the bounded-wait helpers that keep cross-actor settling out of assertions.

@testable import CallEngine
import Foundation
import ServerAPI
import Synchronization
import WebRTC
import XCTest

// MARK: - Constants

/// The wire-visible data channel label the engine uses (Task 9/11 frame
/// call control and file transfer over it).
let dataChannelLabel = "control"

/// A sample TURN credentials set as the server's `GET /api/v1/turn` replies
/// with it (turn_handler.cpp: username, credential, ttl, configured URIs).
let sampleCredentials = TurnCredentials(
    username: "1795000000:eugene",
    credential: "hmac-secret==",
    ttlSec: 86400,
    urls: ["turn:relay.example:3478?transport=udp", "turn:relay.example:3478?transport=tcp"]
)

// MARK: - Engine builder

/// A fresh engine wired to one set of fakes; the fakes stay reachable for the
/// test's assertions and callback firing.
struct EngineFixture {
    let engine: DefaultCallEngine
    let provider: FakePeerConnectionProvider
    let connection: FakePeerConnection
    let camera: FakeCameraAvailability
    let manualAudio: FakeManualAudio
    let logger: RecordingCallEngineLogger
}

func makeEngineFixture(
    media: CallMedia,
    camera: FakeCameraAvailability = FakeCameraAvailability(hasCamera: true),
    statsInterval: Duration = .seconds(1)
) async throws -> EngineFixture {
    let provider = FakePeerConnectionProvider()
    let manualAudio = FakeManualAudio()
    let logger = RecordingCallEngineLogger()
    let engine = DefaultCallEngine(
        credentials: sampleCredentials,
        peerConnectionProvider: provider,
        cameraAvailability: camera,
        manualAudio: manualAudio,
        statsInterval: statsInterval,
        logging: logger
    )
    try await engine.prepare(media: media)
    return EngineFixture(
        engine: engine,
        provider: provider,
        connection: provider.connection,
        camera: camera,
        manualAudio: manualAudio,
        logger: logger
    )
}

// MARK: - Async helpers

extension XCTestCase {
    /// The bounded first element of a stream (nil on timeout) — keeps a lost
    /// event from hanging the suite.
    func nextEvent<T: Sendable>(
        of stream: AsyncStream<T>,
        timeout: TimeInterval = 5
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                for await value in stream {
                    return value
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Polls a predicate until it holds or the timeout expires (the Signaling
    /// tests' bounded-wait pattern).
    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !predicate() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(description)")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
