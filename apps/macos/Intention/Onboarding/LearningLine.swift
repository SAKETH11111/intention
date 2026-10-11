import SwiftUI

/// What Intention has read of the person's sent mail, in the words
/// `LearningProgress` gives, over the track the update window uses, 3
/// points at the rule's strength filled in ink, or the moonlit sky by
/// night, to the share read. With no total there is no share to draw, so
/// the track is left out and its room kept, and the line holds its height
/// as a total arrives.
struct LearningLine: View {
    let label: String
    /// 0...1, or nil when the total is unknown.
    let fraction: Double?
    var detail: String? = nil
    var width: CGFloat = 300
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = fraction.map { min(1, max(0, $0)) }
        let track = RoundedRectangle(cornerRadius: 2, style: .continuous)
        VStack(alignment: .leading, spacing: detail == nil ? 7 : 3) {
            // One line, wider than the track when the count needs it.
            Text(label)
                .font(SetupStyle.text(13, .semibold))
                .foregroundStyle(palette.ink)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            if let detail {
                Text(detail)
                    .font(SetupStyle.text(13))
                    .foregroundStyle(palette.lead)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if detail == nil || shown != nil {
                Group {
                    if let shown {
                        track.fill(palette.rule)
                            .overlay(alignment: .leading) {
                                GeometryReader { proxy in
                                    track.fill(palette.isNight ? palette.skyInk : palette.ink)
                                        .frame(width: proxy.size.width * shown)
                                }
                            }
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: shown)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 300, height: 3)
            }
        }
        .frame(minWidth: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([label, detail].compactMap { $0 }.joined(separator: ". "))
        .accessibilityValue(shown.map { "\(Int(($0 * 100).rounded())) percent" } ?? "")
    }
}
