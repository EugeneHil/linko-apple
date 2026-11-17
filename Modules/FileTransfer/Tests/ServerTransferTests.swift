// Server transport tests (Plan 4 Task 11): streaming upload with digest
// verification, download with the X-Linko-Sha256 check, and the cap
// rejection that must happen before a single byte hits the network.

@testable import FileTransfer
import Foundation
import ServerAPI
import XCTest

/// Answers with a canned status/body/headers and records every request,
/// including the bytes read back from a streamed (httpBodyStream) body.
final class FilesTransportFake: HTTPTransport, @unchecked Sendable {
    struct Call {
        let request: URLRequest
        let body: Data
    }

    /// One canned HTTP answer.
    struct CannedReply: Sendable {
        let status: Int
        let body: Data
        let headers: [String: String]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let answer: @Sendable (URLRequest) -> CannedReply

    init(answer: @escaping @Sendable (URLRequest) -> CannedReply) {
        self.answer = answer
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = Self.readStreamedBody(request)
        lock.withLock {
            recorded.append(Call(request: request, body: body))
        }
        let reply = answer(request)
        guard let http = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/nonexistent"),
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        ) else {
            throw APIError.malformedResponse
        }
        return (reply.body, http)
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    /// URLSession delivers httpBodyStream in production; the fake drains it
    /// so the tests can assert exactly which bytes went on the wire.
    private static func readStreamedBody(_ request: URLRequest) -> Data {
        if let data = request.httpBody {
            return data
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var all = Data()
        let bufferSize = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 {
                break
            }
            all.append(buffer, count: read)
        }
        return all
    }
}

final class ServerTransferTests: XCTestCase {
    private func makeFilesClient(
        _ transport: FilesTransportFake,
        token: String = "tok-123"
    ) throws -> FilesClient {
        let tokens = TokenFake(token: token)
        return try FilesClient(
            baseURL: XCTUnwrap(URL(string: "https://server.example")),
            transport: transport,
            tokens: tokens
        )
    }

    /// Plan test name: test_upload_streams_and_verifies_digest
    func test_upload_streams_and_verifies_digest() async throws {
        let contents = randomBytes(5000)
        let url = try makeTempFile(name: "upload.bin", contents: contents)
        defer { try? FileManager.default.removeItem(at: url) }
        let digest = sha256Hex(contents)
        let replyTemplate =
            #"{"fileId":"abc123456789012345678901234567890","sha256":"%@","size":%lld}"#

        let transport = FilesTransportFake { _ in
            FilesTransportFake.CannedReply(
                status: 201,
                body: Data(String(format: replyTemplate, digest, Int64(contents.count)).utf8),
                headers: [:]
            )
        }
        let transfer = try ServerFileTransfer(files: makeFilesClient(transport))

        let reply = try await transfer.upload(fileURL: url)
        XCTAssertEqual(reply.fileId, "abc123456789012345678901234567890")
        XCTAssertEqual(reply.sha256, digest)
        XCTAssertEqual(reply.size, 5000)

        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.request.httpMethod, "PUT")
        XCTAssertEqual(call.request.url?.path, "/api/v1/files")
        XCTAssertEqual(call.request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(call.request.value(forHTTPHeaderField: "Content-Length"), "5000")
        // The bytes went on the wire streamed from disk, not buffered whole.
        XCTAssertEqual(call.body, contents)

        // A server digest that does not match what we sent is an error.
        let lying = FilesTransportFake { _ in
            FilesTransportFake.CannedReply(
                status: 201,
                body: Data(String(format: replyTemplate, "deadbeef", Int64(contents.count)).utf8),
                headers: [:]
            )
        }
        let lyingTransfer = try ServerFileTransfer(files: makeFilesClient(lying))
        do {
            _ = try await lyingTransfer.upload(fileURL: url)
            XCTFail("expected digestMismatch")
        } catch let error as TransferError {
            XCTAssertEqual(error, .digestMismatch(expected: digest, actual: "deadbeef"))
        }
    }

    /// Plan test name: test_download_verifies_digest
    func test_download_verifies_digest() async throws {
        let contents = randomBytes(3000)
        let digest = sha256Hex(contents)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("filetransfer-\(UUID().uuidString)-download.bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        let transport = FilesTransportFake { _ in
            FilesTransportFake.CannedReply(
                status: 200,
                body: contents,
                headers: ["X-Linko-Sha256": digest, "Content-Type": "application/octet-stream"]
            )
        }
        let transfer = try ServerFileTransfer(files: makeFilesClient(transport))

        try await transfer.download(fileId: "abc123456789012345678901234567890", destination: destination)

        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.request.httpMethod, "GET")
        XCTAssertEqual(call.request.url?.path, "/api/v1/files/abc123456789012345678901234567890")
        XCTAssertEqual(call.request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")

        let saved = try Data(contentsOf: destination)
        XCTAssertEqual(saved, contents)
    }

    /// Plan test name: test_download_digest_mismatch_is_error
    func test_download_digest_mismatch_is_error() async throws {
        let contents = randomBytes(100)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("filetransfer-\(UUID().uuidString)-bad.bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        let transport = FilesTransportFake { _ in
            FilesTransportFake.CannedReply(
                status: 200,
                body: contents,
                headers: [
                    "X-Linko-Sha256":
                        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
                ]
            )
        }
        let transfer = try ServerFileTransfer(files: makeFilesClient(transport))

        do {
            try await transfer.download(
                fileId: "abc123456789012345678901234567890",
                destination: destination
            )
            XCTFail("expected digestMismatch")
        } catch let error as TransferError {
            XCTAssertEqual(
                error,
                .digestMismatch(
                    expected: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                    actual: sha256Hex(contents)
                )
            )
        }
        // Nothing is written when the digest check fails.
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// Plan test name: test_file_over_cap_rejected_before_network
    func test_file_over_cap_rejected_before_network() async throws {
        // A sparse file one byte over the 100 MB cap: no payload write, but
        // the size attribute reports the full length.
        let url = try makeSparseTempFile(name: "huge.bin", size: FileLimits.maxUploadBytes + 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let transport = FilesTransportFake { _ in FilesTransportFake.CannedReply(status: 200, body: Data(), headers: [:]) }
        let transfer = try ServerFileTransfer(files: makeFilesClient(transport))

        do {
            _ = try await transfer.upload(fileURL: url)
            XCTFail("expected tooLarge")
        } catch let error as TransferError {
            XCTAssertEqual(error, .tooLarge(bytes: FileLimits.maxUploadBytes + 1, cap: FileLimits.maxUploadBytes))
        }
        XCTAssertTrue(transport.calls.isEmpty, "an over-cap file must never reach the network")
    }
}
