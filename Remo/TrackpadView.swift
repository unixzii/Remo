//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import QuartzCore
import RemoEngine
import SwiftUI
import UIKit

enum TouchInput {
    static let fingerTouchTypes: [NSNumber] = [
        NSNumber(value: UITouch.TouchType.direct.rawValue),
        NSNumber(value: UITouch.TouchType.pencil.rawValue),
    ]
}

enum TrackpadGesture {
    /// Finger travel in view points.
    case move(CGPoint)
    /// A hardware pointer position, normalized to the picture from its upper left.
    case point(CGPoint)
    /// Whole lines; positive values move the content down, following the finger.
    case scroll(lines: Int)
    /// A physical scroll: continuous deltas in points, or one unit per wheel notch.
    /// The position is normalized to the picture and stays where scrolling began.
    case scrollAt(delta: CGVector, unit: PointerScrollUnit, position: CGPoint)
    case button(PointerButton, clickCount: Int = 1)
}

struct TrackpadView: View {
    let onInput: (TrackpadGesture) -> Void
    /// Window-space frames of SwiftUI controls drawn over the trackpad.
    var excludedRects: [CGRect] = []
    /// The wheel only makes sense while the remote mouse can be controlled.
    var showsWheel = true
    /// Whether the session granted remote pointer control; hardware forwards only then.
    var controlsPointer = false
    /// The picture, which this view zooms and pans.
    let surface: VideoSurface
    /// Pixel size of the remote picture, which the zoomed view is sized from.
    var videoSize: CGSize?
    /// Height obscured at the bottom (e.g. the on-screen keyboard).
    var bottomInset: CGFloat = 0
    /// Quick-action orb placed directly beneath the scroll wheel.
    var quickActionOrbIcon: QuickActionIcon
    var quickActionOrbAccessibilityLabel: String
    var onQuickActionTap: () -> Void = {}
    var quickActionItems: [QuickActionItem] = []

    private static let edgeControlSpacing: CGFloat = 12

    @State private var edgeControlsFrame = CGRect.zero
    @State private var quickMenuExpanded = false

    var body: some View {
        // The trackpad fills the entire screen (with the video aspect-fitted inside it). On
        // iOS 27.1+, the scroll wheel and quick-action orb avoid exact hardware occlusions and
        // corner insets instead of the full-edge rectangular safe area. The trackpad’s UIKit view
        // excludes their frame so touches meant for them reach them.
        ZStack(alignment: .trailing) {
            TrackpadRegion(
                onInput: onInput,
                excludedRects: excludedRects + (showsEdgeControls ? [edgeControlsFrame] : []),
                surface: surface, videoSize: videoSize, bottomInset: bottomInset,
                controlsPointer: controlsPointer
            )
            .ignoresSafeArea()
            if showsEdgeControls {
                edgeControlsOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The on-screen wheel is for fingers; a Mac already has real scrolling.
    private var wheelShown: Bool {
        #if targetEnvironment(macCatalyst)
            false
        #else
            showsWheel
        #endif
    }

    private var quickActionShown: Bool {
        #if targetEnvironment(macCatalyst)
            false
        #else
            !quickActionItems.isEmpty
        #endif
    }

    private var showsEdgeControls: Bool {
        wheelShown || quickActionShown
    }

    @ViewBuilder
    private var edgeControlsOverlay: some View {
        if #available(iOS 27.1, *) {
            GeometryReader { proxy in
                let layout = ScreenOcclusionLayout(proxy: proxy)
                let wheelHeight = min(proxy.size.height * 0.6, 120)
                let totalHeight =
                    (wheelShown ? wheelHeight : 0)
                    + (wheelShown && quickActionShown ? Self.edgeControlSpacing : 0)
                    + (quickActionShown ? QuickActionMenu.orbSize : 0)
                let controlWidth = max(ScrollWheel.hitWidth, QuickActionMenu.hitWidth)
                let trailing = layout.trailingInset(
                    forCenteredHeight: totalHeight,
                    width: controlWidth,
                    bottomInset: bottomInset)
                edgeControlStack(wheelHeight: wheelHeight)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        edgeControlsFrame = $0
                    }
                    .padding(.trailing, trailing)
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .animation(.spring(duration: 0.36, bounce: 0.06), value: bottomInset)
                    .animation(.spring(duration: 0.36, bounce: 0.06), value: trailing)
            }
            .ignoresSafeArea()
        } else {
            edgeControlStack(wheelHeight: nil)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    edgeControlsFrame = $0
                }
                .padding(.trailing, 16)
                .padding(.bottom, bottomInset)
                .animation(.spring(duration: 0.36, bounce: 0.06), value: bottomInset)
        }
    }

    private func edgeControlStack(wheelHeight: CGFloat?) -> some View {
        VStack(spacing: Self.edgeControlSpacing) {
            if wheelShown {
                Group {
                    if let wheelHeight {
                        ScrollWheel(onInput: onInput)
                            .frame(height: wheelHeight)
                    } else {
                        ScrollWheel(onInput: onInput)
                            .containerRelativeFrame(.vertical) { height, _ in min(height * 0.6, 120) }
                    }
                }
                .scaleEffect(quickMenuExpanded ? 0.84 : 1)
                .offset(y: quickMenuExpanded ? 12 : 0)
                .opacity(quickMenuExpanded ? 0 : 1)
                .allowsHitTesting(!quickMenuExpanded)
                .animation(.spring(duration: 0.28, bounce: 0.08), value: quickMenuExpanded)
            }

            if quickActionShown {
                QuickActionMenu(
                    orbIcon: quickActionOrbIcon,
                    orbAccessibilityLabel: quickActionOrbAccessibilityLabel,
                    onTap: onQuickActionTap,
                    items: quickActionItems,
                    onExpandedChanged: { expanded in
                        quickMenuExpanded = expanded
                    }
                )
            }
        }
    }
}

/// The trackpad: one finger drives the remote pointer, two fingers zoom and pan the picture.
///
/// It is a scroll view so UIKit handles pinching, panning, deceleration and bounce. The video
/// surface is the zoomed view, so zooming is a layer transform rather than a redraw. The scroll
/// view’s pan needs two fingers, leaving single touches to the pointer gestures.
///
/// A mouse or trackpad drives the pointer absolutely instead: hover moves it, its real buttons
/// press, and wheel and two-finger scrolls go to the remote screen. A physical scroll never
/// pans the local picture; a physical pinch still zooms it.
///
/// Touches inside `excludedRects` (window space) are left to the SwiftUI controls drawn over it.
/// Taps are read from raw touches rather than a `UITapGestureRecognizer`: SwiftUI makes buttons
/// drawn over this view wait for such a recognizer to fail, which it never does for touches it
/// isn’t given, so those buttons stopped responding.
private final class TouchSurface: UIScrollView {
    var excludedRects: [CGRect] = [] {
        didSet { if excludedRects != oldValue { invalidatePointerStyle() } }
    }
    var onTap: (() -> Void)?
    var onGesture: ((TrackpadGesture) -> Void)?
    var videoSize: CGSize? {
        didSet { if videoSize != oldValue { resetZoom() } }
    }
    /// Height obscured along the bottom edge, such as an active on-screen keyboard.
    var bottomInset: CGFloat = 0 {
        didSet {
            guard abs(bottomInset - oldValue) > 0.5 else { return }
            updateBottomInset()
        }
    }
    /// The picture at its fitted size; zooming scales it.
    var zoomContent: UIView? {
        didSet {
            guard zoomContent !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let zoomContent {
                // Touches land on the scroll view itself, where the trackpad gestures live.
                zoomContent.isUserInteractionEnabled = false
                addSubview(zoomContent)
            }
            resetZoom()
        }
    }

    private var videoSurface: VideoSurface? { zoomContent as? VideoSurface }

    /// Whether the session granted remote control; hardware input forwards only then.
    var controlsPointer = false {
        didSet {
            guard controlsPointer != oldValue else { return }
            if !controlsPointer { endHardwareCapture() }
            invalidatePointerStyle()
        }
    }

    private var tapStart: (location: CGPoint, time: TimeInterval)?
    private var laidOutSize = CGSize.zero
    /// Hardware moves the cursor directly, so panning the zoomed view after it would chase the
    /// user's own input; finger input still lets the picture follow the cursor.
    private var lastInputWasHardware = false

    static let hardwareTouchTypes: Set<UITouch.TouchType> = [.indirectPointer]
    static let fingerTouchTypes: [NSNumber] = TouchInput.fingerTouchTypes

    private enum HardwareButton {
        case primary, secondary
        var down: PointerButton { self == .primary ? .leftDown : .rightDown }
        var up: PointerButton { self == .primary ? .leftUp : .rightUp }
    }

    private var capture: (touch: ObjectIdentifier, button: HardwareButton, clickCount: Int)?
    private var lastPointerLocation: CGPoint?
    private var scrollAnchor: CGPoint?
    private var scrollLast = CGPoint.zero
    private var scrollHasChanged = false
    private var momentumLink: CADisplayLink?
    private var momentumLast: CFTimeInterval = 0
    private var momentumVelocity = CGPoint.zero
    private var lastClick: (time: TimeInterval, point: CGPoint, count: Int)?
    private var pointerInteraction: UIPointerInteraction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        delaysContentTouches = false
        panGestureRecognizer.minimumNumberOfTouches = 2
        // Only fingers pan the picture; two-finger trackpad scroll goes to the remote screen.
        panGestureRecognizer.allowedTouchTypes = Self.fingerTouchTypes
        panGestureRecognizer.allowedScrollTypesMask = []

        let pointerInteraction = UIPointerInteraction(delegate: self)
        addInteraction(pointerInteraction)
        self.pointerInteraction = pointerInteraction
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover)))
        for mask: UIScrollTypeMask in [.discrete, .continuous] {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(scrollGesture(_:)))
            pan.allowedTouchTypes = []
            pan.allowedScrollTypesMask = mask
            addGestureRecognizer(pan)
        }
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)),
            name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(
            self, selector: #selector(windowDidResignKey(_:)),
            name: UIWindow.didResignKeyNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func excludes(windowPoint: CGPoint) -> Bool {
        excludedRects.contains { $0.contains(windowPoint) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { endHardwareCapture() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            resetZoom()
        }
        invalidatePointerStyle()
    }

    /// Shows the whole picture, fitted and centered.
    private func resetZoom() {
        guard let zoomContent else { return }
        zoomScale = 1
        var size = bounds.size
        if let videoSize, videoSize.width > 0, videoSize.height > 0, !bounds.isEmpty {
            let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
            size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        }
        zoomContent.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centerContent()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    /// Scrolls as little as it takes to show `rect` of `view` whole, so a zoomed-in view
    /// follows the cursor to its edges. A zoom or pan the user is making is left alone.
    func reveal(_ rect: CGRect, in view: UIView) {
        guard !isZooming, !isZoomBouncing, !isDragging, !bounds.isEmpty, !lastInputWasHardware
        else { return }
        let target = view.convert(rect, to: self)
        let visible = CGRect(
            x: bounds.minX, y: bounds.minY,
            width: bounds.width, height: max(0, bounds.height - bottomInset))
        func shift(_ low: CGFloat, _ high: CGFloat, within start: CGFloat, _ end: CGFloat)
            -> CGFloat
        {
            if low < start { return low - start }
            if high > end { return high - end }
            return 0
        }
        let minimum = CGPoint(x: -contentInset.left, y: -contentInset.top)
        let maximum = CGPoint(
            x: max(minimum.x, contentSize.width + contentInset.right - bounds.width),
            y: max(minimum.y, contentSize.height + contentInset.bottom - bounds.height))
        let offset = CGPoint(
            x: min(
                maximum.x,
                max(
                    minimum.x,
                    contentOffset.x
                        + shift(target.minX, target.maxX, within: visible.minX, visible.maxX))),
            y: min(
                maximum.y,
                max(
                    minimum.y,
                    contentOffset.y
                        + shift(target.minY, target.maxY, within: visible.minY, visible.maxY))))
        if offset != contentOffset { contentOffset = offset }
    }

    /// Keeps the picture centered on any axis where it is smaller than the view.
    ///
    /// This uses content insets, updated from `scrollViewDidZoom`, because the scroll view
    /// calls that inside its own zoom-bounce animation and so animates the inset change too.
    /// Moving the view in `layoutSubviews` instead happened outside that animation, and the
    /// picture jumped to the corner the moment a pinch below the minimum was released.
    func centerContent() {
        let size = contentSize
        let x = max(0, (bounds.width - size.width) / 2)
        let visibleHeight = max(0, bounds.height - bottomInset)
        let y = max(0, (visibleHeight - size.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y + bottomInset, right: x)
    }

    private func updateBottomInset() {
        UIView.animate(.spring) {
            self.centerContent()
            let minimumY = -self.contentInset.top
            let maximumY = max(
                minimumY, self.contentSize.height + self.contentInset.bottom - self.bounds.height)
            let clampedY = min(maximumY, max(minimumY, self.contentOffset.y))
            if self.contentSize.height <= max(0, self.bounds.height - self.bottomInset) {
                self.contentOffset.y = minimumY
            } else if clampedY != self.contentOffset.y {
                self.contentOffset.y = clampedY
            }
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !excludes(windowPoint: convert(point, to: nil)) && super.point(inside: point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        stopMomentum()
        if let event, pointerTouchBegan(touches, event: event) { return }
        guard event?.allTouches?.count == 1, let touch = touches.first,
            !Self.hardwareTouchTypes.contains(touch.type)
        else {
            tapStart = nil
            return
        }
        tapStart = (touch.location(in: self), touch.timestamp)
        lastInputWasHardware = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        pointerTouchMoved(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        pointerTouchFinished(touches)
        guard let start = tapStart,
            let touch = touches.first(where: { !Self.hardwareTouchTypes.contains($0.type) })
        else { return }
        tapStart = nil
        // The pan and hold recognizers cancel the touch once they begin, so a drag never ends here.
        let location = touch.location(in: self)
        if touch.timestamp - start.time < 0.35,
            hypot(location.x - start.location.x, location.y - start.location.y) < 10
        {
            onTap?()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        tapStart = nil
        pointerTouchFinished(touches)
    }

    // MARK: Hardware pointer

    /// A view point as a share of the remote picture, from its upper left. `clamping` lets a
    /// drag that leaves the picture keep reporting at its edge instead of going silent.
    private func normalizedPoint(_ point: CGPoint, clamping: Bool = false) -> CGPoint? {
        guard let surface = videoSurface, let picture = surface.pictureRect else { return nil }
        let local = convert(point, to: surface)
        guard clamping || picture.contains(local) else { return nil }
        let x = min(1, max(0, (local.x - picture.minX) / picture.width))
        let y = min(1, max(0, (local.y - picture.minY) / picture.height))
        return CGPoint(x: x, y: y)
    }

    private func emit(_ gesture: TrackpadGesture) {
        guard controlsPointer else { return }
        lastInputWasHardware = true
        onGesture?(gesture)
    }

    private func pressedButton(in event: UIEvent) -> HardwareButton? {
        let mask = event.buttonMask
        if mask.contains(.secondary) { return .secondary }
        if mask.contains(.primary) {
            return event.modifierFlags.contains(.control) ? .secondary : .primary
        }
        return nil
    }

    private func pointerTouchBegan(_ touches: Set<UITouch>, event: UIEvent) -> Bool {
        guard let touch = touches.first(where: { Self.hardwareTouchTypes.contains($0.type) })
        else { return false }
        let location = touch.location(in: self)
        lastPointerLocation = location
        guard capture == nil, let position = normalizedPoint(location),
            let button = pressedButton(in: event)
        else { return true }
        let count = clickCount(of: touch, button: button)
        capture = (ObjectIdentifier(touch), button, count)
        emit(.point(position))
        emit(.button(button.down, clickCount: count))
        return true
    }

    private func pointerTouchMoved(_ touches: Set<UITouch>) {
        guard let capture,
            let touch = touches.first(where: { ObjectIdentifier($0) == capture.touch })
        else { return }
        let location = touch.location(in: self)
        lastPointerLocation = location
        guard let position = normalizedPoint(location, clamping: true) else { return }
        emit(.point(position))
    }

    private func pointerTouchFinished(_ touches: Set<UITouch>) {
        guard let capture,
            let touch = touches.first(where: { ObjectIdentifier($0) == capture.touch })
        else { return }
        self.capture = nil
        let location = touch.location(in: self)
        lastPointerLocation = location
        if let position = normalizedPoint(location, clamping: true) {
            emit(.point(position))
        }
        emit(.button(capture.button.up, clickCount: capture.clickCount))
    }

    private func endHardwareCapture() {
        stopMomentum()
        scrollAnchor = nil
        guard let capture else { return }
        self.capture = nil
        if let location = lastPointerLocation,
            let position = normalizedPoint(location, clamping: true)
        {
            emit(.point(position))
        }
        emit(.button(capture.button.up, clickCount: capture.clickCount))
    }

    @objc private func sceneWillDeactivate(_ note: Notification) {
        guard note.object as? UIWindowScene === window?.windowScene else { return }
        endHardwareCapture()
    }

    @objc private func windowDidResignKey(_ note: Notification) {
        guard note.object as? UIWindow === window else { return }
        endHardwareCapture()
    }

    /// `tapCount` counts hardware presses, but a count the event leaves at one is rechecked
    /// against the last press: same place, inside a third of a second, means a repeat.
    private func clickCount(of touch: UITouch, button: HardwareButton) -> Int {
        guard button == .primary else { return 1 }
        if touch.tapCount > 1 { return touch.tapCount }
        let location = touch.location(in: self)
        var count = 1
        if let last = lastClick,
            touch.timestamp - last.time < 0.35,
            hypot(location.x - last.point.x, location.y - last.point.y) < 10
        {
            count = last.count + 1
        }
        lastClick = (touch.timestamp, location, count)
        return count
    }

    // MARK: Hover and scroll

    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .began else { return }
        let location = gesture.location(in: self)
        lastPointerLocation = location
        guard let position = normalizedPoint(location) else { return }
        emit(.point(position))
    }

    @objc private func scrollGesture(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopMomentum()
            scrollLast = .zero
            scrollHasChanged = false
            let location = gesture.location(in: self)
            let translation = gesture.translation(in: self)
            let pointer =
                lastPointerLocation
                ?? CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            scrollAnchor =
                excludes(windowPoint: convert(pointer, to: nil)) ? nil : normalizedPoint(pointer)
            sendScrollDelta(from: gesture)
        case .changed:
            scrollHasChanged = true
            sendScrollDelta(from: gesture)
        case .ended:
            sendScrollDelta(from: gesture)
            guard gesture.allowedScrollTypesMask == .continuous, scrollHasChanged else {
                scrollAnchor = nil
                return
            }
            beginMomentum(gesture.velocity(in: self))
        case .cancelled, .failed:
            scrollAnchor = nil
            stopMomentum()
        default:
            break
        }
    }

    private func sendScrollDelta(from gesture: UIPanGestureRecognizer) {
        guard let position = scrollAnchor else {
            scrollLast = gesture.translation(in: self)
            return
        }
        let translation = gesture.translation(in: self)
        let delta = CGVector(
            dx: translation.x - scrollLast.x, dy: translation.y - scrollLast.y)
        scrollLast = translation
        guard delta != .zero else { return }
        if gesture.allowedScrollTypesMask == .discrete {
            var lines = CGVector.zero
            if delta.dx != 0 { lines.dx = delta.dx > 0 ? 1 : -1 }
            if delta.dy != 0 { lines.dy = delta.dy > 0 ? 1 : -1 }
            emit(.scrollAt(delta: lines, unit: .line, position: position))
        } else {
            emit(.scrollAt(delta: delta, unit: .pixel, position: position))
        }
    }

    /// UIKit reports no momentum phase for a scroll pan; coast from the release velocity.
    private func beginMomentum(_ velocity: CGPoint) {
        guard scrollAnchor != nil, controlsPointer, hypot(velocity.x, velocity.y) > 30 else {
            scrollAnchor = nil
            return
        }
        momentumVelocity = velocity
        momentumLast = 0
        let link = CADisplayLink(target: self, selector: #selector(momentum(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
    }

    @objc private func momentum(_ link: CADisplayLink) {
        let elapsed = momentumLast == 0 ? link.duration : link.timestamp - momentumLast
        momentumLast = link.timestamp
        guard let position = scrollAnchor else {
            stopMomentum()
            return
        }
        let decay = pow(UIScrollView.DecelerationRate.normal.rawValue, elapsed * 1000)
        let delta = CGVector(
            dx: momentumVelocity.x * elapsed * (1 + decay) / 2,
            dy: momentumVelocity.y * elapsed * (1 + decay) / 2)
        momentumVelocity.x *= decay
        momentumVelocity.y *= decay
        if hypot(momentumVelocity.x, momentumVelocity.y) < 1 {
            scrollAnchor = nil
            stopMomentum()
            return
        }
        if delta != .zero { emit(.scrollAt(delta: delta, unit: .pixel, position: position)) }
    }

    func invalidatePointerStyle() {
        pointerInteraction?.invalidate()
    }
}

extension TouchSurface: UIPointerInteractionDelegate {
    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        guard controlsPointer, let surface = videoSurface, let picture = surface.pictureRect else {
            return nil
        }
        let local = convert(request.location, to: surface)
        guard picture.contains(local), !excludes(windowPoint: convert(request.location, to: nil))
        else { return nil }
        let rect = surface.convert(picture, to: self).intersection(bounds)
        return rect.isEmpty ? nil : UIPointerRegion(rect: rect)
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        controlsPointer && videoSurface?.showsRemoteCursor == true ? .hidden() : nil
    }
}

private struct TrackpadRegion: UIViewRepresentable {
    let onInput: (TrackpadGesture) -> Void
    let excludedRects: [CGRect]
    let surface: VideoSurface
    let videoSize: CGSize?
    let bottomInset: CGFloat
    let controlsPointer: Bool

    func makeCoordinator() -> Coordinator { Coordinator(onInput: onInput) }

    func makeUIView(context: Context) -> TouchSurface {
        let view = TouchSurface()
        let coordinator = context.coordinator
        coordinator.surface = view
        view.delegate = coordinator
        view.onTap = { [weak coordinator] in coordinator?.onInput(.button(.leftClick)) }
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = TouchSurface.fingerTouchTypes
        let hold = UILongPressGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.hold))
        hold.minimumPressDuration = 0.4
        hold.allowedTouchTypes = TouchSurface.fingerTouchTypes
        pan.require(toFail: hold)
        coordinator.pointerPan = pan
        for recognizer in [pan, hold] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ uiView: TouchSurface, context: Context) {
        context.coordinator.onInput = onInput
        uiView.excludedRects = excludedRects
        uiView.zoomContent = surface
        uiView.videoSize = videoSize
        uiView.bottomInset = bottomInset
        uiView.onGesture = onInput
        uiView.controlsPointer = controlsPointer
        surface.onCursorMoved = { [weak uiView, weak surface] frame in
            guard let uiView, let surface else { return }
            uiView.reveal(frame, in: surface)
        }
        surface.onCursorVisibilityChanged = { [weak uiView] in uiView?.invalidatePointerStyle() }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIScrollViewDelegate {
        var onInput: (TrackpadGesture) -> Void
        weak var surface: TouchSurface?
        weak var pointerPan: UIPanGestureRecognizer?
        private var dragLocation: CGPoint?
        private var touchDown = CGPoint.zero
        private var panIgnored = false

        init(onInput: @escaping (TrackpadGesture) -> Void) {
            self.onInput = onInput
        }

        // MARK: Zoom

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { surface?.zoomContent }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            surface?.centerContent()
            surface?.invalidatePointerStyle()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            surface?.invalidatePointerStyle()
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            surface?.stopMomentum()
            cancelPointerDrag()
        }

        func scrollViewDidEndZooming(
            _ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat
        ) {
            (view as? VideoSurface)?.zoomDidSettle()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { cancelPointerDrag() }

        /// A second finger turns a pointer drag into a zoom; stop moving the pointer.
        private func cancelPointerDrag() {
            guard let pointerPan, pointerPan.state != .possible else { return }
            pointerPan.isEnabled = false
            pointerPan.isEnabled = true
        }

        // MARK: Pointer

        // Touches on the controls drawn over the trackpad still reach these recognizers. Refusing
        // them would leave the recognizers pending, and SwiftUI buttons wait on them, so they are
        // taken and later ignored instead. Hardware pointer buttons bypass these recognizers via
        // `allowedTouchTypes` and take the view's own press/release path.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            guard !TouchSurface.hardwareTouchTypes.contains(touch.type) else { return false }
            touchDown = touch.location(in: nil)
            return true
        }

        /// Lets a pinch start even after a finger has begun moving the pointer.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other === surface?.pinchGestureRecognizer || other === surface?.panGestureRecognizer
        }

        private var startedOnControl: Bool {
            surface?.excludes(windowPoint: touchDown) ?? false
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { panIgnored = startedOnControl }
            guard !panIgnored,
                gesture.state == .began || gesture.state == .changed || gesture.state == .ended
            else { return }
            let translation = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            onInput(.move(translation))
        }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            let location = gesture.location(in: gesture.view)
            switch gesture.state {
            case .began:
                guard !startedOnControl else { return }
                dragLocation = location
                onInput(.button(.leftDown))
            case .changed, .ended:
                guard let previous = dragLocation else { return }
                dragLocation = location
                onInput(.move(CGPoint(x: location.x - previous.x, y: location.y - previous.y)))
                if gesture.state == .ended { endDrag() }
            case .cancelled, .failed:
                endDrag()
            default: break
            }
        }

        private func endDrag() {
            guard dragLocation != nil else { return }
            dragLocation = nil
            onInput(.button(.leftUp))
        }
    }
}
