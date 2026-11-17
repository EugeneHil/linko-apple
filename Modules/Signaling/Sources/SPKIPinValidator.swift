// SPKI pinning (Plan 4 Task 4): the TLS trust anchor is the server's
// self-signed certificate, validated by the SPKI pin carried in the invite
// link — base64(SHA-256(subjectPublicKeyInfo DER)). Fail closed: a
// certificate whose pin does not match (or any challenge that is not the
// pinned server's trust) is cancelled — never a fallback, never
// trust-on-first-use (spec 4.3).

import CryptoKit
import Foundation
import Security

public final class SPKIPinValidator: NSObject, URLSessionDelegate {
    private let expectedPin: String

    public init(expectedPin: String) {
        self.expectedPin = expectedPin
        super.init()
    }

    // MARK: - Pin pipeline

    /// base64(SHA-256(SPKI DER)) of the certificate — the same pipeline as
    /// `openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER |
    /// openssl dgst -sha256 -binary | openssl enc -base64`. Throws when the
    /// bytes are not a certificate: garbage is never hashed into a pin.
    public static func pin(certificateDER: Data) throws -> String {
        guard SecCertificateCreateWithData(nil, certificateDER as CFData) != nil else {
            throw PinError.notACertificate
        }
        let spki = try subjectPublicKeyInfo(of: certificateDER)
        let digest = SHA256.hash(data: spki)
        return Data(digest).base64EncodedString()
    }

    // MARK: - Trust evaluation

    /// True when the trust object's leaf certificate hashes to the expected
    /// pin. Every failure mode (no chain, unparsable leaf, mismatch) is a
    /// false — the caller fails closed.
    public func isPinned(_ trust: SecTrust) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let pin = try? Self.pin(certificateDER: SecCertificateCopyData(leaf) as Data)
        else {
            return false
        }
        return pin == expectedPin
    }

    /// The URLSessionDelegate answer for one authentication challenge:
    /// pinned server trust proceeds with a credential, everything else —
    /// including basic/NTLM and unpinned server trust — is cancelled.
    public func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              isPinned(trust)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    // MARK: - URLSessionDelegate

    public func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    // MARK: - Minimal DER walk

    /// Extracts the full subjectPublicKeyInfo TLV from a certificate. The
    /// structure walk is fixed by X.509: Certificate{ tbsCertificate{ ... } },
    /// and inside tbsCertificate, after the optional [0] version and the
    /// serialNumber INTEGER, exactly five SEQUENCEs follow — signature
    /// algorithm, issuer, validity, subject and the subjectPublicKeyInfo we
    /// want (extensions live in the [3] tag after it).
    private static func subjectPublicKeyInfo(of certificateDER: Data) throws -> Data {
        let bytes = [UInt8](certificateDER)
        let certificate = try element(in: bytes, at: 0)
        guard certificate.tag == 0x30 else { throw PinError.notACertificate }
        let tbs = try element(in: bytes, at: certificate.content.lowerBound)
        guard tbs.tag == 0x30 else { throw PinError.notACertificate }

        var offset = tbs.content.lowerBound
        var sequenceCount = 0
        var sawSerial = false
        while offset < tbs.content.upperBound {
            let current = try element(in: bytes, at: offset)
            if current.tag == 0xA0 {
                offset = current.next // explicit version number
                continue
            }
            if current.tag == 0x02 {
                sawSerial = true // serialNumber
            }
            if current.tag == 0x30, sawSerial {
                sequenceCount += 1
                if sequenceCount == 5 {
                    return Data(bytes[current.full])
                }
            }
            offset = current.next
        }
        throw PinError.notACertificate
    }

    /// One DER TLV: the tag, the full element range and the offset of the
    /// next element.
    private struct DERElement {
        let tag: UInt8
        let full: Range<Int>
        let content: Range<Int>
        let next: Int
    }

    private static func element(in bytes: [UInt8], at offset: Int) throws -> DERElement {
        guard offset + 2 <= bytes.count else { throw PinError.truncated }
        let tag = bytes[offset]
        var length = Int(bytes[offset + 1])
        var headerBytes = 2
        if length & 0x80 != 0 {
            // Long-form length: the first byte counts the length bytes.
            let byteCount = length & 0x7F
            guard byteCount >= 1, byteCount <= 4, offset + 2 + byteCount <= bytes.count else {
                throw PinError.truncated
            }
            length = 0
            for index in 0 ..< byteCount {
                length = (length << 8) | Int(bytes[offset + 2 + index])
            }
            headerBytes = 2 + byteCount
        }
        let contentStart = offset + headerBytes
        guard contentStart + length <= bytes.count else { throw PinError.truncated }
        return DERElement(tag: tag, full: offset ..< contentStart + length,
                          content: contentStart ..< contentStart + length,
                          next: contentStart + length)
    }

    /// Why a pin could not be computed or matched. Payload-free — callers
    /// log the case, never certificate bytes.
    public enum PinError: Error, Equatable {
        case notACertificate
        case truncated
    }
}
