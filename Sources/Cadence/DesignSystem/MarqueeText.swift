import SwiftUI

/// One line of text that, when too long for its width, slides left until
/// its end shows, waits, and slides back, instead of wrapping and pushing
/// the controls down. Still, and truncated, under Reduce Motion.
struct MarqueeText: View {
    let text: String
    let font: Font
    /// Points a second.
    var speed: CGFloat = 24
    /// How long it rests at each end.
    var pause: Double = 2.5
    /// How far the fade reaches in from an edge where text is cut off.
    var fade: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var start = Date.now

    private var overflow: CGFloat { textWidth - boxWidth }
    private var scrolls: Bool { !reduceMotion && overflow > 1 }

    var body: some View {
        // The one-line text sizes the box; the moving copy is drawn over it.
        Text(text).font(font).lineLimit(1)
            .opacity(scrolls ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .background {
                Text(text).font(font).lineLimit(1).fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if scrolls {
                    TimelineView(.animation) { context in
                        let x = offset(at: context.date)
                        Text(text)
                            .font(font).lineLimit(1).fixedSize()
                            .offset(x: x)
                            // The measured width, not `maxWidth: .infinity`: a
                            // flexible frame takes the wider, fixed-size text's
                            // width and the copy runs off the screen.
                            .frame(width: boxWidth, alignment: .leading)
                            .clipped()
                            .mask { edges(offset: x) }
                    }
                    .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .onChange(of: text) { start = .now }
    }

    /// Fades only an edge that has text beyond it, eased in as the text
    /// moves, so the first letter is crisp at rest at the start and the last
    /// at rest at the end.
    private func edges(offset x: CGFloat) -> some View {
        let leading = min(-x, fade) / max(boxWidth, 1)
        let trailing = min(overflow + x, fade) / max(boxWidth, 1)
        return LinearGradient(stops: [.init(color: leading > 0 ? .clear : .black, location: 0),
                                      .init(color: .black, location: leading),
                                      .init(color: .black, location: 1 - trailing),
                                      .init(color: trailing > 0 ? .clear : .black, location: 1)],
                              startPoint: .leading, endPoint: .trailing)
    }

    /// Rest at the start, ease left to the end, rest, ease back, again.
    private func offset(at date: Date) -> CGFloat {
        let travel = Double(overflow / speed)
        let cycle = 2 * (pause + travel)
        let t = date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
        let progress: Double
        switch t {
        case ..<pause: progress = 0
        case ..<(pause + travel): progress = ease((t - pause) / travel)
        case ..<(2 * pause + travel): progress = 1
        default: progress = 1 - ease((t - 2 * pause - travel) / travel)
        }
        return -overflow * CGFloat(progress)
    }

    /// Smoothstep: starts and stops gently rather than jerking at the ends.
    private func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}
