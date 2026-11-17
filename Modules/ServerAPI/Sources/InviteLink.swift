// Invite link parsing (Plan 4 Task 5). The link the server CLI prints —
// `linko://join?host=…&port=…[&pin=…]&code=…` — is the only carrier of the
// SPKI pin and the invite code. The pin is mandatory (a pin-less link would
// mean trust-on-first-use — rejected, spec 6), the code is mandatory, the
// port must parse into 1…65535, and unknown query parameters are ignored
// (Review Focus 1).

import Foundation

public enum InviteLinkError: Error, Sendable, Equatable {
    /// Not a `linko://join?…` URL (foreign scheme, missing query, junk).
    case notALinkoLink
    case missingHost
    case badHost
    case badPort
    case missingPin
    case missingCode
}

public struct InviteLink: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let pin: String
    public let code: String

    public static func parse(_ raw: String) -> Result<InviteLink, InviteLinkError> {
        guard let components = URLComponents(string: raw),
              components.scheme == "linko",
              components.host == "join"
        else {
            return .failure(.notALinkoLink)
        }

        // First occurrence wins; unknown parameters are simply skipped.
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            values[item.name] = item.value
        }

        guard let host = values["host"], !host.isEmpty else {
            return .failure(.missingHost)
        }
        guard host.allSatisfy(isAllowedHostCharacter) else {
            return .failure(.badHost)
        }
        guard let portValue = values["port"],
              let port = Int(portValue),
              (1 ... 65535).contains(port)
        else {
            return .failure(.badPort)
        }
        guard let pin = values["pin"], !pin.isEmpty else {
            return .failure(.missingPin)
        }
        guard let code = values["code"], !code.isEmpty else {
            return .failure(.missingCode)
        }
        return .success(InviteLink(host: host, port: port, pin: pin, code: code))
    }

    /// ASCII hostnames and IPv4 literals only — what the server CLI puts
    /// into the link for v0.1 (domain or IPv4). Whitespace, separators and
    /// anything URL-encodable are junk by this rule.
    private static func isAllowedHostCharacter(_ character: Character) -> Bool {
        ("a" ... "z").contains(character) ||
            ("A" ... "Z").contains(character) ||
            ("0" ... "9").contains(character) ||
            character == "." || character == "-"
    }
}
