import SwiftUI

/// Minimal SGR renderer for `capture-pane -pe` output.
///
/// The host forwards pane captures with escapes intact, and that matters: dim
/// is how Claude's ghost suggestions stay visually distinct from committed
/// text, so stripping ANSI would lose real information. This handles the subset
/// tmux actually emits — 8/16 colour, 256-colour, bold, dim, italic, inverse —
/// and ignores cursor movement, which a full-frame capture never needs.
///
/// A complete emulator (scrollback regions, mouse, resize) arrives with
/// SwiftTerm alongside the PTY channel; this keeps frames mode dependency-free.
enum ANSIText {

    static func render(_ input: String, baseFont: Font = .system(size: 11, design: .monospaced)) -> AttributedString {
        var output = AttributedString()
        var style = Style()
        var buffer = String()

        func flush() {
            guard !buffer.isEmpty else { return }
            var run = AttributedString(buffer)
            run.font = baseFont
            run.foregroundColor = style.resolvedForeground
            if let background = style.resolvedBackground {
                run.backgroundColor = background
            }
            output.append(run)
            buffer.removeAll(keepingCapacity: true)
        }

        var iterator = input.makeIterator()
        var pending: Character?

        while let char = pending ?? iterator.next() {
            pending = nil

            guard char == "\u{1B}" else {
                buffer.append(char)
                continue
            }
            // ESC — only CSI ... m (SGR) changes appearance. Everything else is
            // consumed and dropped so stray escapes never reach the label.
            guard let bracket = iterator.next() else { break }
            guard bracket == "[" else {
                if bracket == "\u{1B}" { pending = bracket }
                continue
            }

            var parameters = String()
            var terminator: Character?
            while let next = iterator.next() {
                if next.isNumber || next == ";" {
                    parameters.append(next)
                } else {
                    terminator = next
                    break
                }
            }
            guard terminator == "m" else { continue }

            flush()
            style.apply(parameters)
        }

        flush()
        return linkified(output)
    }

    /// Marks up http(s) URLs so they can be tapped.
    ///
    /// Applied after the fact rather than during the scan because a URL is not
    /// guaranteed to sit inside one SGR run — Claude's TUI dims a line's
    /// trailing half often enough — and a detector that ran per run would see
    /// two halves of an address and match neither.
    private static func linkified(_ rendered: AttributedString) -> AttributedString {
        var output = rendered
        let hits = TerminalLinks.detect(in: String(output.characters))
        guard !hits.isEmpty else { return output }

        for hit in hits {
            let characters = output.characters
            guard let start = characters.index(characters.startIndex,
                                               offsetBy: hit.start,
                                               limitedBy: characters.endIndex),
                  let end = characters.index(characters.startIndex,
                                             offsetBy: hit.end,
                                             limitedBy: characters.endIndex)
            else { continue }

            output[start..<end].link = hit.url
            // Overrides whatever colour the escape codes asked for. Losing the
            // host's styling on these few characters is the right trade: a link
            // that is not visibly a link is one nobody thinks to tap.
            output[start..<end].foregroundColor = hit.isSignIn
                ? UdhaTheme.Term.red : UdhaTheme.Term.link
            output[start..<end].underlineStyle = Text.LineStyle.single
        }
        return output
    }

    /// Printable length of a line, ignoring escape sequences.
    ///
    /// `String.count` would include every byte of `ESC[38;5;39m`, so a heavily
    /// coloured line looks far wider than it renders and the fit calculation
    /// would shrink the text to nothing.
    static func visibleLength(_ line: String) -> Int {
        var count = 0
        var iterator = line.makeIterator()
        while let char = iterator.next() {
            guard char == "\u{1B}" else { count += 1; continue }
            guard iterator.next() == "[" else { continue }
            // Consume the CSI parameter bytes and its final byte.
            while let next = iterator.next() {
                if !next.isNumber && next != ";" { break }
            }
        }
        return count
    }

    /// Drops trailing rows that render as nothing.
    ///
    /// A row of pure escape sequences is visually empty but is not an empty
    /// string, so a naive `isEmpty` check leaves the padding in place.
    static func trimTrailingBlankLines(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, visibleLength(last.trimmingCharacters(in: .whitespaces)) == 0 {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - SGR state

    private struct Style {
        var foreground: Int?
        var background: Int?
        var bold = false
        var dim = false
        var inverse = false

        var resolvedForeground: Color {
            let base = foreground.map(Style.palette) ?? Color.white.opacity(0.88)
            if inverse { return background.map(Style.palette) ?? Color.black }
            return dim ? base.opacity(0.45) : base
        }

        var resolvedBackground: Color? {
            if inverse { return foreground.map(Style.palette) ?? Color.white.opacity(0.88) }
            return background.map(Style.palette)
        }

        mutating func apply(_ parameters: String) {
            let codes = parameters
                .split(separator: ";", omittingEmptySubsequences: false)
                .map { Int($0) ?? 0 }
            var index = 0
            // An empty parameter list (`ESC[m`) means reset.
            if codes.isEmpty { self = Style(); return }

            while index < codes.count {
                let code = codes[index]
                switch code {
                case 0:  self = Style()
                case 1:  bold = true
                case 2:  dim = true
                case 7:  inverse = true
                case 22: bold = false; dim = false
                case 27: inverse = false
                case 30...37: foreground = code - 30
                case 39: foreground = nil
                case 40...47: background = code - 40
                case 49: background = nil
                case 90...97: foreground = code - 90 + 8
                case 100...107: background = code - 100 + 8
                case 38, 48:
                    // 38;5;N (256-colour) or 38;2;R;G;B (truecolor)
                    guard index + 1 < codes.count else { index = codes.count; break }
                    let mode = codes[index + 1]
                    if mode == 5, index + 2 < codes.count {
                        if code == 38 { foreground = codes[index + 2] } else { background = codes[index + 2] }
                        index += 2
                    } else if mode == 2, index + 4 < codes.count {
                        // Collapse truecolor onto the nearest cube entry rather
                        // than carrying a second colour representation.
                        let cube = 16
                            + 36 * (codes[index + 2] * 5 / 255)
                            + 6 * (codes[index + 3] * 5 / 255)
                            + (codes[index + 4] * 5 / 255)
                        if code == 38 { foreground = cube } else { background = cube }
                        index += 4
                    }
                default: break
                }
                index += 1
            }
        }

        /// xterm 256-colour palette: 16 named, a 6×6×6 cube, then 24 greys.
        static func palette(_ index: Int) -> Color {
            switch index {
            case 0:  return Color(white: 0.16)
            case 1:  return Color(red: 0.94, green: 0.38, blue: 0.38)
            case 2:  return Color(red: 0.38, green: 0.84, blue: 0.52)
            case 3:  return Color(red: 0.94, green: 0.76, blue: 0.35)
            case 4:  return Color(red: 0.40, green: 0.63, blue: 0.98)
            case 5:  return Color(red: 0.78, green: 0.52, blue: 0.96)
            case 6:  return Color(red: 0.36, green: 0.80, blue: 0.84)
            case 7:  return Color(white: 0.85)
            case 8:  return Color(white: 0.45)
            case 9:  return Color(red: 1.00, green: 0.50, blue: 0.50)
            case 10: return Color(red: 0.50, green: 0.94, blue: 0.62)
            case 11: return Color(red: 1.00, green: 0.86, blue: 0.45)
            case 12: return Color(red: 0.52, green: 0.73, blue: 1.00)
            case 13: return Color(red: 0.88, green: 0.62, blue: 1.00)
            case 14: return Color(red: 0.46, green: 0.90, blue: 0.94)
            case 15: return Color.white
            case 16...231:
                let value = index - 16
                let steps: [Double] = [0, 0.373, 0.529, 0.686, 0.843, 1.0]
                return Color(red: steps[(value / 36) % 6],
                             green: steps[(value / 6) % 6],
                             blue: steps[value % 6])
            case 232...255:
                return Color(white: (Double(index - 232) * 10 + 8) / 255)
            default:
                return Color.white.opacity(0.88)
            }
        }
    }
}
