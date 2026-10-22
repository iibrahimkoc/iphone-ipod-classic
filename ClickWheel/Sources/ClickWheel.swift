import SwiftUI

/// A touch click wheel: dragging around the ring scrolls, tapping the ring's
/// quadrants acts as MENU / ⏭ / ⏯ / ⏮, and tapping the center selects.
/// Holding the center calls `onHold`; if it took the hold, sliding the finger out onto the ring
/// scrolls, and letting go selects nothing.
struct ClickWheel: View {
    var onScroll: (Int) -> Void
    var onSelect: () -> Void
    /// Returns false when the screen has no use for a hold, so letting go selects as a tap would.
    var onHold: () -> Bool = { false }
    var onMenu: () -> Void
    var onPlayPause: () -> Void
    var onNext: () -> Void
    var onPrevious: () -> Void

    /// 24 ticks per full turn, like the original wheel.
    private let step = Double.pi / 12

    @State private var lastAngle: Double?
    @State private var accumulated = 0.0
    @State private var moved = false
    @State private var pressedCenter = false
    @State private var holdTimer: DispatchWorkItem?
    @State private var held = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: size / 2, y: size / 2)
            let inner = size * 0.19
            let labelOffset = size * 0.38

            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.14)],
                                         startPoint: .top, endPoint: .bottom))
                Text("MENU")
                    .font(.system(size: size * 0.06, weight: .bold))
                    .offset(y: -labelOffset)
                Image(systemName: "forward.end.alt.fill")
                    .font(.system(size: size * 0.055))
                    .offset(x: labelOffset)
                Image(systemName: "backward.end.alt.fill")
                    .font(.system(size: size * 0.055))
                    .offset(x: -labelOffset)
                Image(systemName: "playpause.fill")
                    .font(.system(size: size * 0.055))
                    .offset(y: labelOffset)
                Circle()
                    .fill(Color(white: pressedCenter ? 0.04 : 0.09))
                    .overlay(Circle().stroke(Color(white: 0.28), lineWidth: 1))
                    .frame(width: inner * 2, height: inner * 2)
            }
            .foregroundColor(Color(white: 0.75))
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in changed(value, center: center, inner: inner) }
                    .onEnded { value in ended(value, center: center, inner: inner) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func changed(_ value: DragGesture.Value, center: CGPoint, inner: CGFloat) {
        let start = value.startLocation
        let startedInCenter = hypot(start.x - center.x, start.y - center.y) < inner
        pressedCenter = startedInCenter
        if startedInCenter && holdTimer == nil && !held && !moved {
            let work = DispatchWorkItem { held = onHold() }
            holdTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        if hypot(value.translation.width, value.translation.height) > 8 && !held {
            moved = true
            holdTimer?.cancel()
        }
        if startedInCenter && !held { return }

        let dx = value.location.x - center.x
        let dy = value.location.y - center.y
        // Angles are meaningless near the middle, so ignore that region while scrolling.
        guard hypot(dx, dy) > inner * 0.6 else {
            lastAngle = nil
            return
        }

        // Screen y grows downward, so atan2 increases clockwise: clockwise scrolls down.
        let angle = atan2(Double(dy), Double(dx))
        if let last = lastAngle {
            var delta = angle - last
            if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
            accumulated += delta
            while accumulated >= step {
                accumulated -= step
                onScroll(1)
            }
            while accumulated <= -step {
                accumulated += step
                onScroll(-1)
            }
        }
        lastAngle = angle
    }

    private func ended(_ value: DragGesture.Value, center: CGPoint, inner: CGFloat) {
        defer {
            lastAngle = nil
            accumulated = 0
            moved = false
            pressedCenter = false
            holdTimer?.cancel()
            holdTimer = nil
            held = false
        }
        guard !moved, !held else { return }

        let dx = value.startLocation.x - center.x
        let dy = value.startLocation.y - center.y
        if hypot(dx, dy) < inner {
            onSelect()
            return
        }
        let degrees = atan2(Double(dy), Double(dx)) * 180 / .pi
        switch degrees {
        case -135 ..< -45: onMenu()
        case -45 ..< 45: onNext()
        case 45 ..< 135: onPlayPause()
        default: onPrevious()
        }
    }
}
