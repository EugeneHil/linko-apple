// TDD tests (Plan 4 Task 4 / LNK-30, Step 1) for SPKIPinValidator:
// the known-answer proof of the pin pipeline (certificate DER -> SPKI DER ->
// SHA-256 -> base64) against a pin precomputed with openssl, and the
// fail-closed behavior on a pin mismatch or an unparsable certificate
// (Review Focus 5: no fallback, no trust-on-first-use).

import Foundation
import Security
@testable import Signaling
import XCTest

final class SPKIPinValidatorTests: XCTestCase {
    // MARK: - Known answer (plan test name: test_spki_pin_matches_known_answer)

    func test_spki_pin_matches_known_answer() throws {
        let der = try TestCertificates.aDER()

        // The pure DER pipeline must reproduce the openssl-precomputed pin.
        let pin = try SPKIPinValidator.pin(certificateDER: der)
        XCTAssertEqual(pin, TestCertificates.aPin, "the Swift pipeline must reproduce base64(SHA-256(SPKI DER))")

        // And the same answer through the SecTrust path the delegate uses.
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData), "the embedded DER must parse as a certificate")
        let trust = try XCTUnwrap(Self.trust(from: certificate), "SecTrustCreateWithCertificates must succeed")
        let validator = SPKIPinValidator(expectedPin: TestCertificates.aPin)
        XCTAssertTrue(validator.isPinned(trust), "the certificate with the matching SPKI must be pinned")

        // The other embedded certificate (different key) must produce its own
        // distinct pin — proves the KAT is not accidentally vacuous.
        let otherPin = try SPKIPinValidator.pin(certificateDER: TestCertificates.bDER())
        XCTAssertEqual(otherPin, TestCertificates.bPin)
        XCTAssertNotEqual(otherPin, TestCertificates.aPin, "different keys must hash to different pins")
    }

    // MARK: - Fail closed (plan test name: test_pin_mismatch_fails_closed)

    func test_pin_mismatch_fails_closed() throws {
        let wrongCertificateDER = try TestCertificates.bDER()
        let wrongCertificate = try XCTUnwrap(SecCertificateCreateWithData(nil, wrongCertificateDER as CFData))
        let wrongTrust = try XCTUnwrap(Self.trust(from: wrongCertificate))

        let validator = SPKIPinValidator(expectedPin: TestCertificates.aPin)
        XCTAssertFalse(validator.isPinned(wrongTrust), "a certificate whose SPKI differs from the pin must not be trusted")

        // The delegate glue fails closed for any challenge that is not the
        // pinned server's trust: a non-server-trust challenge is cancelled.
        let basicSpace = URLProtectionSpace(
            host: "linko.example",
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodDefault
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: basicSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: StubChallengeSender()
        )
        final class ResultBox: @unchecked Sendable {
            var disposition: URLSession.AuthChallengeDisposition?
            var credential: URLCredential?
        }
        let result = ResultBox()
        validator.handleChallenge(challenge) { challenged, offered in
            result.disposition = challenged
            result.credential = offered
        }
        XCTAssertEqual(result.disposition, .cancelAuthenticationChallenge, "any non-server-trust challenge must fail closed")
        XCTAssertNil(result.credential)
    }

    func test_unparsable_certificate_fails_closed() {
        XCTAssertThrowsError(
            try SPKIPinValidator.pin(certificateDER: Data(repeating: 0x30, count: 3)),
            "a truncated certificate must throw, never hash garbage or fall back"
        )
    }

    // MARK: - Helpers

    private static func trust(from certificate: SecCertificate) -> SecTrust? {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, nil, &trust)
        return status == errSecSuccess ? trust : nil
    }
}

/// Minimal URLAuthenticationChallengeSender stub for synthetic challenges.
private final class StubChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_: URLCredential, for _: URLAuthenticationChallenge) {}

    func continueWithoutCredential(for _: URLAuthenticationChallenge) {}

    func cancel(_: URLAuthenticationChallenge) {}
}
