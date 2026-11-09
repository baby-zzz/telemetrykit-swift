import Foundation

/// Keeps credentials and personal data out of what is sent: secret query values, e-mail addresses, bearer tokens and
/// credentials in `scheme://user:password@host`. Applied to every free string of an item before it is queued. Fails
/// closed: if any pattern did not compile, every text becomes `[REDACTED]`.
public struct TelemetryScrub: Sendable {
    public static let redacted = "[REDACTED]"
    public static let emailRedacted = "[email]"

    /// The query parameter names whose values are always replaced
    public static let defaultSecretParameters = ["signed", "ts", "token", "access_token", "refresh_token", "id_token", "code", "state",
                                                 "session_state", "key", "password", "secret"]

    /// The scrub with the default patterns only
    public static let `default` = TelemetryScrub()

    private let parameter: NSRegularExpression?
    private let email: NSRegularExpression?
    private let bearer: NSRegularExpression?
    private let userInfo: NSRegularExpression?
    private let extras: [NSRegularExpression]
    private let valid: Bool

    /// - Parameters:
    ///   - extraParameters: more query parameter names (matched case-insensitively, as literals) whose values are replaced
    ///   - extraPatterns: more regular expressions; every match is replaced by `[REDACTED]`. One that does not compile
    ///     makes the scrub fail closed.
    public init(extraParameters: [String] = [], extraPatterns: [String] = []) {
        let names = (Self.defaultSecretParameters + extraParameters).map(NSRegularExpression.escapedPattern(for:))
        // ?name=value or &name=value up to the next &, #, quote or whitespace
        parameter = try? NSRegularExpression(pattern: "([?&](?:\(names.joined(separator: "|")))=)[^&#\\s\"']*", options: [.caseInsensitive])
        // letters-only top-level domain, so package versions ("sdk@1.2.3") stay
        email = try? NSRegularExpression(pattern: "[\\w.%+-]+@[a-z0-9.-]+\\.[a-z]{2,}\\b", options: [.caseInsensitive])
        bearer = try? NSRegularExpression(pattern: "(Bearer\\s+)[A-Za-z0-9._~+/=-]+")
        userInfo = try? NSRegularExpression(pattern: "([a-z][a-z0-9+.-]*://)[^/?#@\\s]+@", options: [.caseInsensitive])
        let compiled = extraPatterns.map { try? NSRegularExpression(pattern: $0) }
        extras = compiled.compactMap { $0 }
        valid = extras.count == compiled.count
    }

    /// The text with credentials in URLs, secret query values, bearer tokens, e-mail addresses and extra matches replaced
    public func text(_ value: String) -> String {
        guard valid, let parameter, let email, let bearer, let userInfo else { return Self.redacted }
        var out = value
        out = Self.replace(userInfo, in: out, with: "$1\(Self.redacted)@")
        if out.contains("=") { out = Self.replace(parameter, in: out, with: "$1\(Self.redacted)") }
        out = Self.replace(bearer, in: out, with: "$1\(Self.redacted)")
        if out.contains("@") { out = Self.replace(email, in: out, with: Self.emailRedacted) }
        for pattern in extras {
            out = Self.replace(pattern, in: out, with: NSRegularExpression.escapedTemplate(for: Self.redacted))
        }
        return out
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
