import SwiftUI

/// Two panes with a divider you can drag. The split is a fraction of the space, so it survives
/// window resizing, and callers keep it in @AppStorage so it's remembered between launches.
struct ResizableSplit<First: View, Second: View>: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    @Binding var fraction: Double
    var range: ClosedRange<Double> = 0.2...0.8
    @ViewBuilder let first: First
    @ViewBuilder let second: Second

    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .horizontal ? proxy.size.width : proxy.size.height
            let firstSize = max(0, total * fraction - Self.handle / 2)
            let layout = axis == .horizontal
                ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first
                    .frame(width: axis == .horizontal ? firstSize : nil,
                           height: axis == .vertical ? firstSize : nil)
                handleView(total: total)
                second.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    static var handle: CGFloat { 9 }

    private func handleView(total: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            Capsule().fill(Color.secondary.opacity(0.5))
                .frame(width: axis == .horizontal ? 3 : 36, height: axis == .horizontal ? 36 : 3)
        }
        .frame(width: axis == .horizontal ? Self.handle : nil, height: axis == .vertical ? Self.handle : nil)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { drag in
                let start = dragStart ?? fraction
                dragStart = start
                let moved = axis == .horizontal ? drag.translation.width : drag.translation.height
                fraction = min(max(start + moved / max(total, 1), range.lowerBound), range.upperBound)
            }
            .onEnded { _ in dragStart = nil })
        #if os(macOS)
        .onHover { inside in
            if inside {
                (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        #endif
        .accessibilityElement()
        .accessibilityLabel("Divider")
        .accessibilityValue("\(Int(fraction * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            switch direction {
            case .increment: fraction = min(fraction + step, range.upperBound)
            case .decrement: fraction = max(fraction - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}
