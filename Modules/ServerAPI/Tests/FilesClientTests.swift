// FilesClient tests (Plan 4 Task 14 / LNK-40 coverage backfill): the two
// file endpoints against the canned transport — PUT /api/v1/files streaming
// from a real temp file (the 411 lesson: the explicit Content-Length from
// the file's size) and GET /api/v1/files/{id} carrying the server's digest
// header. Both are Bearer-authenticated; the typed errors match the other
// clients (no token → no request at all).

@testable import ServerAPI
import XCTest

final class FilesClientTests: XCTestCase {
    private let tokens = TokenStoreFake()

    // MARK: - Upload (PUT /api/v1/files)

    func test_upload_streams_file_and_decodes_reply() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let bytes = Data("linko file bytes".utf8)
        let fileURL = try makeTempFile(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let replyBody = #"{"fileId":"f1e2d3c4b5a697887766554433221100","sha256":"deadbeef","size":16}"#
        let fake = TransportFake(status: 201, body: Data(replyBody.utf8))
        let client = FilesClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")

        let reply = try await client.upload(fileURL: fileURL)

        XCTAssertEqual(reply.fileId, "f1e2d3c4b5a697887766554433221100")
        XCTAssertEqual(reply.sha256, "deadbeef")
        XCTAssertEqual(reply.size, 16)

        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/api/v1/files")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        // The server answers 411 without a length (Plan 3 Task 8): the
        // explicit header rides the request even though the body is a stream.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "\(bytes.count)")
        XCTAssertNotNil(request.httpBodyStream, "the body streams from disk, never as one Data")
    }

    func test_upload_without_token_is_error() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fileURL = try makeTempFile(bytes: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let fake = TransportFake(status: 201)
        let client = FilesClient(baseURL: baseURL, transport: fake, tokens: tokens)

        do {
            _ = try await client.upload(fileURL: fileURL)
            XCTFail("expected notAuthenticated")
        } catch let error as APIError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(fake.requests.isEmpty, "no token means no request at all")
    }

    func test_upload_non_201_is_typed_error() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fileURL = try makeTempFile(bytes: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let fake = TransportFake(status: 413)
        let client = FilesClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")

        do {
            _ = try await client.upload(fileURL: fileURL)
            XCTFail("expected server(413)")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(413))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_upload_malformed_reply_is_error() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fileURL = try makeTempFile(bytes: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let fake = TransportFake(status: 201, body: Data("not json".utf8))
        let client = FilesClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")

        do {
            _ = try await client.upload(fileURL: fileURL)
            XCTFail("expected malformedResponse")
        } catch let error as APIError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_upload_missing_file_throws() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("linko-missing-\(UUID().uuidString).bin")
        let fake = TransportFake(status: 201)
        let client = FilesClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")

        do {
            _ = try await client.upload(fileURL: missing)
            XCTFail("expected a throw for the missing file")
        } catch is APIError {
            XCTFail("the file attributes read throws before any request")
        } catch {
            // FileManager's CocoaError for the missing path.
        }
        XCTAssertTrue(fake.requests.isEmpty)
    }

    // MARK: - Download (GET /api/v1/files/{id})

    func test_download_returns_bytes_and_digest_header() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let body = Data("stored file bytes".utf8)
        let fake = TransportFake(
            status: 200,
            body: body,
            headers: ["X-Linko-Sha256": "cafebabe"]
        )
        let client = FilesClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")

        let result = try await client.download(fileId: "f1e2d3")

        XCTAssertEqual(result.data, body)
        XCTAssertEqual(result.sha256, "cafebabe")

        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/v1/files/f1e2d3")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
    }

    func test_download_absent_digest_header_is_nil() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fake = TransportFake(status: 200, body: Data("bytes".utf8))
        let client = FilesClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")

        let result = try await client.download(fileId: "f1e2d3")

        XCTAssertNil(result.sha256, "callers treat the absent header as an error")
    }

    func test_download_non_200_is_typed_error() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fake = TransportFake(status: 404)
        let client = FilesClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")

        do {
            _ = try await client.download(fileId: "f1e2d3")
            XCTFail("expected server(404)")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(404))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_download_without_token_is_error() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fake = TransportFake(status: 200)
        let client = FilesClient(baseURL: baseURL, transport: fake, tokens: tokens)

        do {
            _ = try await client.download(fileId: "f1e2d3")
            XCTFail("expected notAuthenticated")
        } catch let error as APIError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(fake.requests.isEmpty)
    }

    // MARK: - Fixtures

    /// A real file on disk: the upload reads its size and opens an
    /// InputStream over it, so the bytes must exist before the call.
    private func makeTempFile(bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linko-upload-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        return url
    }
}
