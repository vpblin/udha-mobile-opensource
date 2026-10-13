import SwiftUI

/// A flat, axis-less line of one measurement over time, with the area under it
/// washed in the same hue.
///
/// The app's only chart. It scales to what it holds — an idle CPU that never
/// leaves 3% still shows its texture — with a little headroom above and below so
/// the line never touches its own frame. The fill is what makes a 40pt-tall
/// chart legible on a phone: at that height a hairline alone reads as noise.
///
/// Colour carries the same meaning it does everywhere else here: the accent for
/// a reading, warn or bad only when the thing is at a level that wants you.
struct Sparkline: View {
    var values: [Double]
    var color: Color = UdhaTheme.accent
    var lineWidth: CGFloat = 1.9
    /// Washed under the line. Nil draws the line alone.
    var fill: Color?
    /// Drawn when there is nothing else to draw.
    var baseline: Color = UdhaTheme.hairline
    /// Sweeps the line in on first appearance, as the design's `dash` animation
    /// does. Off for the small inline lines, where it would just flicker.
    var animated: Bool = true

    @State private var drawn = false

    /// Fewer than two points is not a line. The screen draws a dashed baseline
    /// and says "collecting" in words rather than a dot that reads as data.
    private var hasLine: Bool { values.count > 1 }

    init(values: [Double],
         color: Color = UdhaTheme.accent,
         lineWidth: CGFloat = 1.9,
         fill: Color? = nil,
         baseline: Color = UdhaTheme.hairline,
         animated: Bool = true) {
        self.values = values
        self.color = color
        self.lineWidth = lineWidth
        self.fill = fill
        self.baseline = baseline
        self.animated = animated
    }

    var body: some View {
        GeometryReader { geo in
            if hasLine {
                let points = normalized(in: geo.size)
                ZStack {
                    if let fill {
                        Path { path in
                            guard let first = points.first, let last = points.last else { return }
                            path.move(to: CGPoint(x: first.x, y: geo.size.height))
                            path.addLine(to: first)
                            for point in points.dropFirst() { path.addLine(to: point) }
                            path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                            path.closeSubpath()
                        }
                        .fill(fill)
                    }
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .trim(from: 0, to: animated ? (drawn ? 1 : 0) : 1)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth,
                                                      lineCap: .round, lineJoin: .round))
                }
                .onAppear {
                    guard animated, !drawn else { return }
                    withAnimation(.easeOut(duration: 0.9)) { drawn = true }
                }
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height - 1))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 1))
                }
                .stroke(baseline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .accessibilityHidden(true)
    }

    /// 20% of the range as padding top and bottom, so a flat series sits centred
    /// rather than smeared across the full height.
    private func normalized(in size: CGSize) -> [CGPoint] {
        var low = values.min() ?? 0
        var high = values.max() ?? 1
        let pad = (high - low) * 0.2
        low -= pad
        high += pad
        if high - low < 1e-6 { low -= 1; high += 1 }

        return values.enumerated().map { index, value in
            let x = values.count == 1
                ? size.width / 2
                : (CGFloat(index) / CGFloat(values.count - 1)) * size.width
            let unit = (value - low) / (high - low)
            // A stroke centred on the frame edge is clipped in half, so keep the
            // line inside by its own width.
            let inset = lineWidth
            let y = size.height - inset - CGFloat(unit) * (size.height - inset * 2)
            return CGPoint(x: x, y: y)
        }
    }
}

/// The design's stat card: a label, a big tabular number, a sparkline, a note.
///
/// Two of these across is the phone's answer to the desktop's six-across strip —
/// a sparkline narrower than a thumb is decoration, so fewer and bigger wins.
struct StatCard: View {
    var label: String
    var value: String
    var note: String?
    var series: [Double]
    var hot: Bool = false
    var chartHeight: CGFloat = 40

    var body: some View {
        UdhaCard(insets: EdgeInsets(top: 13, leading: 14, bottom: 12, trailing: 14)) {
            Text(label)
                .font(UdhaFont.medium(12.5))
                .foregroundStyle(UdhaTheme.secondary)
                .lineLimit(1)
            Text(value)
                .font(UdhaFont.bold(20))
                .monospacedDigit()
                .foregroundStyle(hot ? UdhaTheme.warn : UdhaTheme.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 2)
            Sparkline(values: series,
                      color: hot ? UdhaTheme.warn : UdhaTheme.accent,
                      fill: hot ? UdhaTheme.warnTint : UdhaTheme.accentTint)
                .frame(height: chartHeight)
                .padding(.top, 8)
            if let note {
                Text(series.count > 1 ? note : "collecting · \(note)")
                    .font(UdhaFont.regular(11.5))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .lineLimit(1)
                    .padding(.top, 6)
            }
        }
    }
}
