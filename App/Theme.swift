import SkyKit
import SwiftUI

/// One palette for the whole app, so the dome, the lists and the controls read as one instrument.
enum Theme {
    /// Buttons and selection: a sky blue that keeps white text readable.
    static let accent = Color(red: 0.22, green: 0.58, blue: 0.96)
    /// A satellite in sunlight: the pass track, the profile, the "lit" chips.
    static let sunlit = Color(red: 0.36, green: 0.86, blue: 1.0)
    /// In the Earth's shadow.
    static let eclipsed = Color(white: 0.72)
    /// The highlighted (focused) object.
    static let focus = Color(red: 1.0, green: 0.78, blue: 0.28)
    /// The locked tracking target, and "go".
    static let target = Color(red: 0.32, green: 0.90, blue: 0.56)
    /// Where the scope is pointing, and "stop".
    static let scope = Color(red: 1.0, green: 0.33, blue: 0.38)
    /// The fill for "Start tracking": the target green, deep enough for white text.
    static let go = Color(red: 0.13, green: 0.62, blue: 0.36)
    static let rising = Color(red: 0.32, green: 0.90, blue: 0.56)
    static let setting = Color(red: 1.0, green: 0.62, blue: 0.30)

    /// Deep space behind the dome, the same in light and dark appearance (it's a window on the sky).
    static let space = LinearGradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.07),
                                               Color(red: 0.05, green: 0.07, blue: 0.15)],
                                      startPoint: .top, endPoint: .bottom)

    static func color(of body: SolarSystemBody) -> Color {
        switch body {
        case .sun: Color(red: 1.0, green: 0.84, blue: 0.35)
        case .moon: Color(white: 0.9)
        case .mercury: Color(red: 0.75, green: 0.72, blue: 0.68)
        case .venus: Color(red: 1.0, green: 0.95, blue: 0.80)
        case .mars: Color(red: 1.0, green: 0.45, blue: 0.30)
        case .jupiter: Color(red: 0.95, green: 0.80, blue: 0.62)
        case .saturn: Color(red: 0.95, green: 0.85, blue: 0.55)
        case .uranus: Color(red: 0.55, green: 0.90, blue: 0.92)
        case .neptune: Color(red: 0.45, green: 0.60, blue: 1.0)
        }
    }

    static func color(of object: SkyObject) -> Color {
        switch object {
        case .satellite: sunlit
        case .body(let b): color(of: b)
        case .star: Color(white: 0.92)
        }
    }

    static func symbol(of object: SkyObject) -> String {
        switch object {
        case .satellite: "antenna.radiowaves.left.and.right"
        case .body(.sun): "sun.max.fill"
        case .body(.moon): "moon.fill"
        case .body: "circle.fill"
        case .star: "sparkle"
        }
    }
}

/// A rounded panel: the building block of the control side.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionLabel(title, systemImage: systemImage) }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Small, spaced capitals above a group of controls.
struct SectionLabel: View {
    let title: String
    var systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title.uppercased()).tracking(0.8)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A small tinted capsule: "Visible", "NE → S", "Eclipsed".
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A glowing status light.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.9), radius: 4)
            .accessibilityHidden(true)
    }
}

/// An instrument readout: small label over large monospaced digits.
struct Readout: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .monospaced).weight(.medium)).monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }
}

/// A pass's altitude over time: sunlit in cyan, shadow in grey, with "now" marked while it's up.
struct PassProfile: View {
    let pass: SatellitePass
    let now: Date

    var body: some View {
        Canvas { context, size in
            let track = pass.track
            guard track.count > 1, pass.duration > 0 else { return }
            func point(_ s: PassSample) -> CGPoint {
                CGPoint(x: size.width * s.date.timeIntervalSince(pass.start.date) / pass.duration,
                        y: size.height * (1 - max(0, s.position.altitude) / 90))
            }
            // Baseline (the horizon).
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(base, with: .color(.secondary.opacity(0.35)), lineWidth: 1)

            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for s in track { area.addLine(to: point(s)) }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            let tint = pass.isEclipsed ? Theme.eclipsed : Theme.sunlit
            context.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.35), tint.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            for (a, b) in zip(track, track.dropFirst()) {
                var segment = Path()
                segment.move(to: point(a))
                segment.addLine(to: point(b))
                context.stroke(segment, with: .color(a.sunlit ? Theme.sunlit : Theme.eclipsed.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            if now > pass.start.date, now < pass.end.date {
                let x = size.width * now.timeIntervalSince(pass.start.date) / pass.duration
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(Theme.focus), lineWidth: 1.2)
            }
        }
        .accessibilityHidden(true)
    }
}
