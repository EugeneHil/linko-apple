// ServerFileTransfer (Plan 4 Task 11): the server transport fallback.
// Upload streams the file from disk (digest computed in 64 KiB chunks, body
// handed to URLSession as an InputStream) and verifies the server's digest;
// download verifies the X-Linko-Sha256 header against the received bytes
// before anything is written to the destination. Files over the server's
// 100 MB cap are rejected before any network call. Nothing is logged except
// what FilesClient already logs (method/URL/status).

import CryptoKit
import Foundation
import ServerAPI

/// The server's upload caps (linko-server config.hpp defaults): 100 MB per
/// file, 1 GB per-user quota, 30-day TTL — enforced server-side; the
/// per-file cap is also checked client-side before any network call.
public enum FileLimits {
    public static let maxUploadBytes: Int64 = 100 * 1024 * 1024
}

/// Streaming upload/download against `PUT /api/v1/files` and
/// `GET /api/v1/files/{id}` with SHA-256 verification on both paths.
public struct ServerFileTransfer: Sendable {
    private let files: FilesClient
    private let maxFileBytes: Int64

    public init(files: FilesClient, maxFileBytes: Int64 = FileLimits.maxUploadBytes) {
        self.files = files
        self.maxFileBytes = maxFileBytes
    }

    /// Uploads the file and verifies the server's digest against the one
    /// computed while streaming the file from disk. Over-cap files are
    /// rejected before any network call.
    public func upload(fileURL: URL) async throws -> FileUploadReply {
        let size = try Self.fileSize(fileURL)
        guard size <= maxFileBytes else {
            throw TransferError.tooLarge(bytes: size, cap: maxFileBytes)
        }
        let digest = try FileDigest.sha256Hex(fileURL: fileURL)
        let reply = try await files.upload(fileURL: fileURL)
        guard reply.sha256 == digest else {
            throw TransferError.digestMismatch(expected: digest, actual: reply.sha256)
        }
        return reply
    }

    /// Downloads `fileId` to `destination`, verifying the X-Linko-Sha256
    /// header before writing anything; the destination is not touched on a
    /// digest mismatch. A response without the header is unverifiable and
    /// therefore an error.
    public func download(fileId: String, destination: URL) async throws {
        let (data, header) = try await files.download(fileId: fileId)
        guard let expected = header else {
            throw TransferError.digestMissing
        }
        let actual = FileDigest.sha256Hex(data)
        guard actual == expected else {
            throw TransferError.digestMismatch(expected: expected, actual: actual)
        }
        try data.write(to: destination)
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw TransferError.unreadable
        }
        return number.int64Value
    }
}

/// Streaming SHA-256 (module-internal): the upload path digests the file in
/// 64 KiB chunks from disk, the download path the received bytes.
enum FileDigest {
    static func sha256Hex(fileURL: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw TransferError.unreadable
        }
        defer { try? handle.close() }
        do {
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return Self.hex(hasher.finalize())
        } catch {
            throw TransferError.unreadable
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
