import CoreText
import SwiftUI

/// How many characters of terminal fit on this screen, at this type size.
///
/// This is the number the whole "size the Mac to my phone" feature turns on, so
/// it is measured rather than estimated. `TerminalPane.fit()` gets away with the
/// 0.601 advance-width approximation because being a hair off just makes the
/// text slightly smaller than ideal; here a single character of error means the
/// host lays the pane out one column too wide and *every* line wraps.
///
/// So the advance comes from CoreText, for the same font SwiftUI is rendering.
enum TerminalGrid {

    /// Character cell for `UdhaFont.mono(size)`, in points.
    ///
    /// Cached: this is called on every layout pass of a view that also handles
    /// pinch gestures, and `CTFontGetAdvancesForGlyphs` is far too expensive to
    /// run per frame.
    static func cell(for size: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let key = size.rounded(toPlaces: 2)
        if let hit = cache[key] { return hit }

        let font = CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, size, nil)

        // Any glyph would do in a monospaced face; "M" is the conventional
        // probe and is guaranteed present.
        var glyph = CGGlyph()
        var character: UniChar = 77  // "M"
        var advance = CGSize.zero
        if CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) {
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        }
        let width = advance.width > 0 ? advance.width : size * 0.6

        // Line height is ascent + descent + leading, the same sum SwiftUI uses
        // to stack lines of a single-font Text.
        let height = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)

        let cell = (width: width, height: height > 0 ? height : size * 1.2)
        cache[key] = cell
        return cell
    }

    /// The character grid that fits `viewport`, given the pane's padding.
    ///
    /// Rounds *down* on both axes. A column that only half fits is a column the
    /// host would fill with text the reader has to scroll sideways to see,
    /// which is the exact problem this feature exists to remove.
    static func grid(viewport: CGSize,
                     fontSize: CGFloat,
                     horizontalPadding: CGFloat = 24,
                     verticalPadding: CGFloat = 20) -> (cols: Int, rows: Int) {
        let cell = cell(for: fontSize)
        let usableWidth = max(0, viewport.width - horizontalPadding)
        let usableHeight = max(0, viewport.height - verticalPadding)
        return (
            cols: max(minimumColumns, Int(usableWidth / cell.width)),
            rows: max(minimumRows, Int(usableHeight / cell.height))
        )
    }

    /// Floors that mirror the host's own clamp. Below these the TUI is not
    /// readable at either end, and a mismeasurement should not be able to ask
    /// for a three-column pane.
    static let minimumColumns = 20
    static let minimumRows = 10

    private static var cache: [CGFloat: (width: CGFloat, height: CGFloat)] = [:]
}

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = pow(10.0, CGFloat(places))
        return (self * factor).rounded() / factor
    }
}
