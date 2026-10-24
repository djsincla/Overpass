import SwiftUI

/// Moves the Observe screen through time, up to two days either way. The scale is logarithmic,
/// so minutes are easy to set near the middle and days are reached at the ends, and there's a
/// detent at the centre that snaps back to now.
struct TimeBar: View {
    @Environment(AppModel.self) private var model
    @State private var dragging = false

    /// The labelled marks, as offsets from now. One day is marked but not labelled (it would
    /// crowd the two-day label).
    private static let marks: [(seconds: TimeInterval, label: String?)] = [
        (600, "10m"), (3600, "1h"), (6 * 3600, "6h"), (86_400, nil), (2 * 86_400, "2d"),
    ]
    private static let inset: CGFloat = 10

    var body: some View {
        let shift = model.timeShift
        let shifted = shift != 0
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: shifted ? "clock.arrow.2.circlepath" : "clock")
                    .foregroundStyle(shifted ? Theme.focus : .secondary)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(model.viewDate(context.date), format: .dateTime.weekday(.abbreviated).hour().minute().second())
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(shifted ? Theme.focus : .primary)
                }
                if shifted {
                    Chip(text: offsetText(shift), tint: Theme.focus)
                } else {
                    Chip(text: "Live", systemImage: "dot.radiowaves.left.and.right", tint: Theme.rising)
                }
                Spacer()
                Button("Now") { withAnimation(.spring(duration: 0.3)) { model.timeShift = 0 } }
                    .controlSize(.small)
                    .disabled(!shifted)
                    .keyboardShortcut("0", modifiers: .command)
                    .help("Back to the current time (⌘0)")
            }

            GeometryReader { proxy in
                let width = proxy.size.width - 2 * Self.inset
                let x = { (position: Double) in Self.inset + CGFloat((position + 1) / 2) * width }
                let thumb = x(TimeScale.position(shift))
                let centre = x(0)
                ZStack(alignment: .topLeading) {
                    // The groove.
                    Capsule().fill(Color.primary.opacity(0.10))
                        .frame(width: width, height: 6)
                        .offset(x: Self.inset, y: 9)
                    // From now to the chosen time.
                    Capsule().fill(Theme.focus.gradient)
                        .frame(width: abs(thumb - centre), height: 6)
                        .offset(x: min(thumb, centre), y: 9)
                    // Marks either side, with the detent (now) in the middle.
                    ForEach(Self.marks, id: \.seconds) { mark in
                        ForEach([-1.0, 1.0], id: \.self) { side in
                            let px = x(side * TimeScale.position(mark.seconds))
                            Rectangle().fill(Color.secondary.opacity(0.5))
                                .frame(width: 1, height: mark.label == nil ? 5 : 8)
                                .offset(x: px - 0.5, y: 8)
                            if let label = mark.label {
                                Text((side < 0 ? "−" : "+") + label)
                                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                    .position(x: px, y: 28)
                            }
                        }
                    }
                    // The indent at now: a notch cut into the groove.
                    Path { p in
                        p.move(to: CGPoint(x: centre - 5, y: 1))
                        p.addLine(to: CGPoint(x: centre + 5, y: 1))
                        p.addLine(to: CGPoint(x: centre, y: 7))
                        p.closeSubpath()
                    }
                    .fill(shifted ? Color.secondary : Theme.rising)
                    Text("NOW").font(.system(size: 9, weight: .bold)).tracking(0.5)
                        .foregroundStyle(shifted ? Color.secondary : Theme.rising)
                        .fixedSize()
                        .position(x: centre, y: 28)
                    // The thumb.
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(shifted ? Theme.focus : Theme.rising, lineWidth: 2.5))
                        .shadow(color: (shifted ? Theme.focus : Theme.rising).opacity(dragging ? 0.8 : 0.4), radius: dragging ? 6 : 3)
                        .frame(width: dragging ? 20 : 17, height: dragging ? 20 : 17)
                        .position(x: thumb, y: 12)
                        .animation(.easeOut(duration: 0.12), value: dragging)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        let position = Double((drag.location.x - Self.inset) / max(width, 1)) * 2 - 1
                        model.timeShift = TimeScale.shift(position)
                    }
                    .onEnded { _ in dragging = false })
            }
            .frame(height: 34)
            .sensoryFeedback(.selection, trigger: shift == 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time")
        .accessibilityValue(shifted ? offsetText(shift) : "Now")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            let position = TimeScale.position(model.timeShift)
            switch direction {
            case .increment: model.timeShift = TimeScale.shift(min(position + step, 1))
            case .decrement: model.timeShift = TimeScale.shift(max(position - step, -1))
            @unknown default: break
            }
        }
    }

    private func offsetText(_ shift: TimeInterval) -> String {
        (shift < 0 ? "−" : "+") + countdown(abs(shift))
    }
}

/// The time bar's logarithmic scale: position −1…1 to an offset of up to two days either way.
enum TimeScale {
    /// The scale is linear-ish below this, logarithmic above.
    static let knee: TimeInterval = 60
    static let k = log(1 + AppModel.maximumTimeShift / knee)
    /// Within this distance of the centre, the bar snaps to now.
    static let detent = 0.045

    static func shift(_ position: Double) -> TimeInterval {
        let a = min(abs(position), 1)
        guard a > detent else { return 0 }
        let seconds = knee * (exp(k * a) - 1)
        // Whole minutes: nobody needs to set the sky to the second from a slider.
        return (position < 0 ? -1 : 1) * max(60, (seconds / 60).rounded() * 60)
    }

    static func position(_ shift: TimeInterval) -> Double {
        guard shift != 0 else { return 0 }
        let a = min(log(1 + abs(shift) / knee) / k, 1)
        return shift < 0 ? -a : a
    }
}
