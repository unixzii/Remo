//
//  Created by Cyandev on 11/25/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import RemoEngine
import SwiftUI
import UIKit

/// A detented wheel: each step of finger travel scrolls one line with a haptic tick.
///
/// SwiftUI only draws it. Touches are tracked by `WheelTouchArea`, because a SwiftUI gesture laid
/// over the trackpad’s UIKit view stopped every other button on the screen from responding.
struct ScrollWheel: View {
    let onInput: (TrackpadGesture) -> Void

    /// Finger travel for one detent.
    private static let step: CGFloat = 6
    static let capsuleWidth: CGFloat = 36
    static let horizontalHitPadding: CGFloat = 4
    static let hitWidth: CGFloat = capsuleWidth + horizontalHitPadding * 2
    private static let shape = RoundedRectangle(cornerRadius: capsuleWidth / 2, style: .continuous)

    /// Where the ticks sit; follows the finger and springs onto a detent when it lifts.
    @State private var travel: CGFloat = 0
    @State private var dragBase: CGFloat = 0
    @State private var sentSteps = 0
    @State private var detents = 0
    @State private var pressed = false

    var body: some View {
        ZStack {
            Self.shape.fill(.black.opacity(0.35))
            Ticks(offset: travel, step: Self.step)
                .fill(.white.opacity(0.7))
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                            .init(color: .black, location: 0.75), .init(color: .clear, location: 1),
                        ], startPoint: .top, endPoint: .bottom))
            Self.shape.strokeBorder(.white.opacity(0.25), lineWidth: 1)
        }
        .clipShape(Self.shape)
        .frame(width: Self.capsuleWidth)
        .scaleEffect(pressed ? 1.12 : 1)
        .opacity(pressed ? 1 : 0.45)
        .animation(.spring(duration: 0.35, bounce: 0.45), value: pressed)
        .allowsHitTesting(false)
        .padding(.horizontal, Self.horizontalHitPadding)
        .overlay {
            WheelTouchArea(onBegan: { pressed = true }, onMoved: moved, onEnded: ended)
        }
        .sensoryFeedback(.selection, trigger: detents)
        .accessibilityElement()
        .accessibilityLabel("Scroll wheel")
        .accessibilityHint("Swipe up or down to scroll one line.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onInput(.scroll(lines: -1))
            case .decrement: onInput(.scroll(lines: 1))
            @unknown default: break
            }
        }
    }

    private func moved(_ translation: CGFloat) {
        travel = dragBase + translation
        let steps = Int((translation / Self.step).rounded(.towardZero))
        let delta = steps - sentSteps
        guard delta != 0 else { return }
        sentSteps = steps
        // One command per detent, never a batched count.
        for _ in 0..<abs(delta) { onInput(.scroll(lines: delta.signum())) }
        detents += abs(delta)
    }

    /// A touch that barely moved is a right-click.
    private func ended(_ translation: CGSize, cancelled: Bool) {
        pressed = false
        let settled = dragBase + CGFloat(sentSteps) * Self.step
        dragBase = settled
        sentSteps = 0
        withAnimation(.spring(duration: 0.4, bounce: 0.35)) { travel = settled }
    }
}

/// Follows one finger from the moment it lands, reporting its travel to the wheel.
private struct WheelTouchArea: UIViewRepresentable {
    let onBegan: () -> Void
    let onMoved: (CGFloat) -> Void
    let onEnded: (CGSize, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        // A zero-duration long press tracks the touch from touch-down, unlike a pan.
        let press = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.press))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        // The wheel is for fingers; a hardware click here shouldn't animate it.
        press.allowedTouchTypes = TouchInput.fingerTouchTypes
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.area = self
    }

    final class Coordinator: NSObject {
        var area: WheelTouchArea?
        private var start = CGPoint.zero

        @objc func press(_ gesture: UILongPressGestureRecognizer) {
            guard let area else { return }
            let location = gesture.location(in: gesture.view)
            let translation = CGSize(width: location.x - start.x, height: location.y - start.y)
            switch gesture.state {
            case .began:
                start = location
                area.onBegan()
            case .changed:
                area.onMoved(translation.height)
            case .ended:
                area.onEnded(translation, false)
            case .cancelled, .failed:
                area.onEnded(translation, true)
            default: break
            }
        }
    }
}

/// Evenly spaced tick marks shifted by `offset`, animatable so they can spring between detents.
private struct Ticks: Shape {
    var offset: CGFloat
    let step: CGFloat

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let phase = (offset.truncatingRemainder(dividingBy: step) + step)
            .truncatingRemainder(dividingBy: step)
        let width: CGFloat = 14
        var y = rect.minY + phase - step / 2
        while y < rect.maxY + step {
            path.addRoundedRect(
                in: CGRect(x: rect.midX - width / 2, y: y - 1, width: width, height: 2),
                cornerSize: CGSize(width: 1, height: 1))
            y += step
        }
        return path
    }
}
