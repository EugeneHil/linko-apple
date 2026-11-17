// FilesClient (Plan 4 Task 11): the two server file endpoints —
// PUT /api/v1/files (the reply is {"fileId","sha256","size"}; the server
// caps uploads at 100 MB / per-user quota / 30-day TTL) and
// GET /api/v1/files/{id} (the bytes plus the digest in X-Linko-Sha256).
// Both are Bearer-authenticated like every other ServerAPI client. Uploads
// stream from disk: the body rides an InputStream, so a 100 MB file never
// sits in memory as one Data.

import Foundation

/// The server's upload reply: the server-assigned 32-hex-char file id, the
/// digest it computed over the stored bytes and the stored size.
public struct FileUploadReply: Equatable, Sendable {
    public let fileId: String
    public let sha256: String
    public let size: Int64

    public init(fileId: String, sha256: String, size: Int64) {
        self.fileId = fileId
        self.sha256 = sha256
        self.size = size
    }
}

/// File upload and download over the pinned HTTP transport.
public struct FilesClient: Sendable {
    private let baseURL: URL
    private let transport: HTTPTransport
    private let tokens: TokenStoring

    public init(baseURL: URL, transport: HTTPTransport, tokens: TokenStoring) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokens = tokens
    }

    /// PUTs the file's bytes, streamed from disk, and decodes the upload
    /// reply. The digest verification is the caller's (ServerFileTransfer)
    /// — the client only carries bytes and headers.
    public func upload(fileURL: URL) async throws -> FileUploadReply {
        let token = try await token()
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let number = attributes[.size] as? NSNumber, let stream = InputStream(url: fileURL) else {
            throw APIError.malformedResponse
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/files"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The upload handler answers 411 without a length (Plan 3 Task 8);
        // for a body stream the explicit length is what makes URLSession
        // send one instead of chunked transfer encoding.
        request.setValue("\(number.int64Value)", forHTTPHeaderField: "Content-Length")
        request.httpBodyStream = stream

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.malformedResponse
        }
        guard http.statusCode == 201 else {
            throw APIError.server(http.statusCode)
        }
        struct UploadReply: Decodable {
            let fileId: String
            let sha256: String
            let size: Int64
        }
        guard let reply = try? JSONDecoder().decode(UploadReply.self, from: data) else {
            throw APIError.malformedResponse
        }
        return FileUploadReply(fileId: reply.fileId, sha256: reply.sha256, size: reply.size)
    }

    /// GETs the stored bytes; `sha256` is the server's X-Linko-Sha256 value
    /// (nil when the header is absent, which callers treat as an error).
    public func download(fileId: String) async throws -> (data: Data, sha256: String?) {
        let token = try await token()
        var request = URLRequest(
            url: baseURL
                .appendingPathComponent("api/v1/files")
                .appendingPathComponent(fileId)
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.malformedResponse
        }
        guard http.statusCode == 200 else {
            throw APIError.server(http.statusCode)
        }
        return (data, http.value(forHTTPHeaderField: "X-Linko-Sha256"))
    }

    private func token() async throws -> String {
        guard let token = try await tokens.load() else {
            throw APIError.notAuthenticated
        }
        return token
    }
}
