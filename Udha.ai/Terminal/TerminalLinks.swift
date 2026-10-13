import Foundation

/// Finds URLs in terminal output.
///
/// The reason this exists is narrow and worth stating. A device-authorization
/// flow — `aws sso login --no-browser`, `gh auth login`, `vercel login` — runs
/// on the Mac, prints a URL, and then *blocks*, polling until a human approves
/// it in a browser. The human is holding the iPad. So that URL has to stop
/// being text in a monospaced grid and start being something you can tap;
/// otherwise the only way through is to retype 60 characters by hand while a
/// session sits waiting.
///
/// Hand-rolled rather than `NSDataDetector`, which matches bare hostnames —
/// anything with a dot in it. In a terminal that means every file path, module
/// name and stack frame lights up as a link. Only an explicit http(s) scheme
/// counts here.
enum TerminalLinks {

    struct Hit: Equatable {
        let url: URL
        /// Character offsets into the plain text this was found in, so a caller
        /// can style the same range of a rendered `AttributedString`.
        let start: Int
        let end: Int
        /// The user code the flow will ask you to confirm in the browser, when
        /// the URL carries one. Worth showing beside the link: matching it is
        /// the one check that tells you the page you landed on belongs to the
        /// command that is waiting on you, and not to some other tab.
        let code: String?

        /// A device-authorization URL — meaning something on the host is
        /// blocked right now, waiting for this. Surfaced louder than a link
        /// that merely appeared in some output.
        var isSignIn: Bool { code != nil || TerminalLinks.isDeviceAuthShape(url) }
    }

    // MARK: - Detection

    /// Hits in already-plain text, in document order.
    static func detect(in plain: String) -> [Hit] {
        // Materialised once: offsets have to be *character* offsets to line up
        // with `AttributedString.CharacterView`, and walking String.Index for
        // each of those conversions would be quadratic.
        let chars = Array(plain)
        var hits: [Hit] = []
        var index = 0

        while index < chars.count {
            guard chars[index] == "h" || chars[index] == "H", hasScheme(chars, at: index) else {
                index += 1
                continue
            }
            var end = index
            while end < chars.count, isURLCharacter(chars[end]) { end += 1 }
            end = trimmingTrailingPunctuation(chars, from: index, to: end)

            if let url = URL(string: String(chars[index..<end])), url.host?.isEmpty == false {
                hits.append(Hit(url: url, start: index, end: end, code: userCode(url)))
            }
            index = max(end, index + 1)
        }
        return hits
    }

    /// Hits in output that still carries escape sequences, de-duplicated.
    ///
    /// Offsets are relative to the *stripped* text, which suits the chip bar —
    /// it wants the URLs, not where they sit on screen.
    static func detect(inANSI ansi: String) -> [Hit] {
        var seen = Set<String>()
        return detect(in: plainText(ansi)).filter { seen.insert($0.url.absoluteString).inserted }
    }

    /// Terminal text with its escape sequences removed.
    static func plainText(_ ansi: String) -> String {
        var output = String()
        output.reserveCapacity(ansi.count)
        var iterator = ansi.makeIterator()

        while let char = iterator.next() {
            guard char == "\u{1B}" else { output.append(char); continue }
            guard iterator.next() == "[" else { continue }
            // Consume the CSI parameter bytes and the final byte that ends them.
            while let next = iterator.next() {
                if !next.isNumber && next != ";" { break }
            }
        }
        return output
    }

    // MARK: - Shape

    private static func hasScheme(_ chars: [Character], at index: Int) -> Bool {
        for scheme in ["https://", "http://"] {
            let count = scheme.count
            guard index + count <= chars.count else { continue }
            if String(chars[index..<index + count]).lowercased() == scheme { return true }
        }
        return false
    }

    /// The characters a URL may contain, per RFC 3986 plus the delimiters a
    /// terminal is likely to wrap one in. Non-ASCII stops a match, which is
    /// what keeps a URL from swallowing the `│` at the end of a TUI box row.
    private static func isURLCharacter(_ char: Character) -> Bool {
        guard let ascii = char.asciiValue, ascii > 0x20, ascii != 0x7F else { return false }
        return !"\"'<>`{}|\\^".contains(char)
    }

    /// Prose runs into URLs — "open https://example.com/foo." — and the full
    /// stop is not part of the address. Brackets only come off when they are
    /// unbalanced, since plenty of real URLs contain a matched pair.
    private static func trimmingTrailingPunctuation(_ chars: [Character], from start: Int, to end: Int) -> Int {
        var end = end
        while end > start {
            let char = chars[end - 1]
            if ".,;:!?".contains(char) { end -= 1; continue }
            if char == ")" || char == "]" {
                let opening: Character = char == ")" ? "(" : "["
                let slice = chars[start..<end]
                if slice.count(where: { $0 == opening }) < slice.count(where: { $0 == char }) {
                    end -= 1
                    continue
                }
            }
            break
        }
        return end
    }

    /// `?user_code=ABCD-EFGH` (AWS IAM Identity Center, GitHub) or `?otc=...`
    /// (Microsoft Entra). Not `code`, which is the OAuth *authorization* code
    /// and appears on redirect URLs that are nobody's business to open.
    private static func userCode(_ url: URL) -> String? {
        let names: Set<String> = ["user_code", "usercode", "otc"]
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { names.contains($0.name.lowercased()) })?.value,
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Device-flow URLs that carry their code out of band — you read it off the
    /// terminal and type it into the page — so there is no query item to spot.
    private static func isDeviceAuthShape(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host.hasPrefix("device.sso.") { return true }            // AWS IAM Identity Center
        if path.hasSuffix("/devicelogin") { return true }           // Microsoft Entra
        if path.hasSuffix("/login/device") { return true }          // GitHub
        if path.hasSuffix("/device") { return true }                // Google, Vercel
        if path.hasSuffix("/activate") { return true }              // Okta
        return false
    }
}
