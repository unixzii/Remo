//
//  Created by Cyandev on 11/25/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import QuartzCore
import SwiftUI
import UIKit
import QuartzFilters

// MARK: - SwiftUI Configuration Interface

/// Icon source for the quick-action orb or one of its menu rows.
enum QuickActionIcon {
    case system(String)
    case image(UIImage)

    func makeUIImage(pointSize: CGFloat, weight: UIImage.SymbolWeight = .medium) -> UIImage? {
        switch self {
        case .system(let name):
            let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            return UIImage(systemName: name, withConfiguration: config)
        case .image(let image):
            return image.withRenderingMode(.alwaysTemplate)
        }
    }
}

/// A single action entry in `QuickActionMenu` (ordered top-to-bottom; the last item is selected
/// by default when the orb expands).
struct QuickActionItem: Identifiable {
    enum Role: Equatable {
        case normal
        case destructive
    }

    let id: String
    let title: String
    let icon: QuickActionIcon
    let role: Role
    let action: () -> Void

    init(
        id: String? = nil,
        title: String,
        icon: QuickActionIcon,
        role: Role = .normal,
        action: @escaping () -> Void
    ) {
        self.id = id ?? title
        self.title = title
        self.icon = icon
        self.role = role
        self.action = action
    }

    init(
        id: String? = nil,
        title: String,
        systemImage: String,
        role: Role = .normal,
        action: @escaping () -> Void
    ) {
        self.init(id: id, title: title, icon: .system(systemImage), role: role, action: action)
    }
}

/// A circular quick-action orb positioned by SwiftUI whose interactive morphing menu is hosted
/// directly on the owning `UIWindow` in UIKit for unconstrained layout and 120 Hz spring physics.
///
/// - Short tap triggers `onTap` immediately without expanding.
/// - Holding (or dragging) morphs the orb into a glass menu panel shifted slightly left away from
///   the finger, with an oversized white highlight bar that micro-follows in 4 directions while
///   a single top-layer row set smoothly interpolates color and magnetically locks to the bar.
/// - Pulling past the menu bounds elastically stretches the panel; pulling past the cancel
///   threshold deselects all items while keeping the panel continuously dragged until release.
struct QuickActionMenu: View {
    static let orbSize: CGFloat = 36
    static let horizontalHitPadding: CGFloat = 4
    static let hitWidth: CGFloat = orbSize + horizontalHitPadding * 2

    let orbIcon: QuickActionIcon
    let orbAccessibilityLabel: String
    let onTap: () -> Void
    let items: [QuickActionItem]
    var onExpandedChanged: ((Bool) -> Void)? = nil

    var body: some View {
        QuickActionOrbRepresentable(
            orbIcon: orbIcon,
            onTap: onTap,
            items: items,
            onExpandedChanged: onExpandedChanged
        )
        .frame(width: Self.hitWidth, height: Self.orbSize)
        .accessibilityElement()
        .accessibilityLabel(orbAccessibilityLabel)
        .accessibilityHint("Double-tap to trigger, or use actions for more controls.")
        .accessibilityAction { onTap() }
    }
}

// MARK: - SwiftUI → UIKit Anchor Bridge

private struct QuickActionOrbRepresentable: UIViewRepresentable {
    let orbIcon: QuickActionIcon
    let onTap: () -> Void
    let items: [QuickActionItem]
    let onExpandedChanged: ((Bool) -> Void)?

    func makeUIView(context: Context) -> QuickActionAnchorView {
        let view = QuickActionAnchorView()
        view.configure(
            orbIcon: orbIcon,
            onTap: onTap,
            items: items,
            onExpandedChanged: onExpandedChanged)
        return view
    }

    func updateUIView(_ uiView: QuickActionAnchorView, context: Context) {
        uiView.configure(
            orbIcon: orbIcon,
            onTap: onTap,
            items: items,
            onExpandedChanged: onExpandedChanged)
    }
}

// MARK: - SwiftUI Spring State Wrapper

private struct SpringState<Value: VectorArithmetic> {
    var value: Value
    var velocity: Value = .zero
    var target: Value
    var spring: Spring
    
    init(_ initial: Value, spring: Spring) {
        self.value = initial
        self.target = initial
        self.spring = spring
    }

    init(_ initial: Value, duration: TimeInterval, bounce: Double) {
        self.init(initial, spring: .init(duration: duration, bounce: bounce))
    }

    var isSettled: Bool {
        (value - target).magnitudeSquared < 1e-6 && velocity.magnitudeSquared < 1e-4
    }

    mutating func snap(to newValue: Value) {
        value = newValue
        target = newValue
        velocity = .zero
    }

    mutating func step(dt: TimeInterval) {
        guard dt > 0 else { return }
        if isSettled {
            value = target
            velocity = .zero
            return
        }
        spring.update(value: &value, velocity: &velocity, target: target, deltaTime: dt)
        if isSettled {
            value = target
            velocity = .zero
        }
    }
}

private typealias SpringVec2 = AnimatablePair<CGFloat, CGFloat>

// MARK: - Anchor View (Resting Orb + Gesture Capture)

private final class QuickActionAnchorView: UIView {
    private static let holdExpandDelay: TimeInterval = 0.35
    private static let dragExpandThreshold: CGFloat = 8

    private var orbIcon: QuickActionIcon?
    private var onTap: (() -> Void)?
    private var items: [QuickActionItem] = []
    private var onExpandedChanged: ((Bool) -> Void)?

    // Resting orb visuals (hidden while the window-level morph overlay is active)
    private let orbContainer = UIView()
    private let orbIconView = UIImageView()

    private var pressGesture: UILongPressGestureRecognizer!
    private var holdWorkItem: DispatchWorkItem?
    private var touchStartInWindow = CGPoint.zero
    private var isPressing = false
    private var isExpanded = false
    private var activeOverlay: QuickActionWindowOverlay?

    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setupRestingOrb()
        setupGesture()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(
        orbIcon: QuickActionIcon,
        onTap: @escaping () -> Void,
        items: [QuickActionItem],
        onExpandedChanged: ((Bool) -> Void)?
    ) {
        self.orbIcon = orbIcon
        self.onTap = onTap
        self.items = items
        self.onExpandedChanged = onExpandedChanged
        orbIconView.image = orbIcon.makeUIImage(pointSize: 16, weight: .medium)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = QuickActionMenu.orbSize
        orbContainer.bounds = CGRect(origin: .zero, size: CGSize(width: size, height: size))
        orbContainer.center = CGPoint(x: bounds.midX, y: bounds.midY)
        orbContainer.layer.cornerRadius = size / 2
        orbIconView.frame = CGRect(
            x: (size - 18) / 2, y: (size - 18) / 2, width: 18, height: 18)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            tearDownImmediately()
        }
    }

    var orbFrameInWindow: CGRect? {
        guard let window else { return nil }
        let size = QuickActionMenu.orbSize
        let local = CGRect(
            x: bounds.midX - size / 2,
            y: bounds.midY - size / 2,
            width: size,
            height: size)
        return convert(local, to: window)
    }

    private func setupRestingOrb() {
        orbContainer.isUserInteractionEnabled = false
        orbContainer.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        orbContainer.layer.cornerCurve = .continuous
        orbContainer.layer.borderWidth = 1
        orbContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        orbContainer.alpha = 0.45
        addSubview(orbContainer)

        orbIconView.contentMode = .scaleAspectFit
        orbIconView.tintColor = .white
        orbContainer.addSubview(orbIconView)
    }

    private func setupGesture() {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.allowedTouchTypes = TouchInput.fingerTouchTypes
        addGestureRecognizer(press)
        pressGesture = press
    }

    private func setRestingPressed(_ pressed: Bool) {
        UIView.animate(
            withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.orbContainer.transform =
                pressed ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
            self.orbContainer.alpha = pressed ? 1.0 : 0.45
        }
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard let window else {
            tearDownImmediately()
            return
        }
        let pointInWindow = gesture.location(in: window)

        switch gesture.state {
        case .began:
            cancelHoldTimer()
            isPressing = true
            isExpanded = false
            touchStartInWindow = pointInWindow
            lightImpact.prepare()
            selectionFeedback.prepare()
            softImpact.prepare()
            setRestingPressed(true)

            guard !items.isEmpty else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isPressing, !self.isExpanded else { return }
                let currentPoint = self.pressGesture.location(in: window)
                self.expandMenu(fingerInWindow: currentPoint)
            }
            holdWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdExpandDelay, execute: work)

        case .changed:
            guard isPressing else { return }
            if !isExpanded {
                let distance = hypot(
                    pointInWindow.x - touchStartInWindow.x,
                    pointInWindow.y - touchStartInWindow.y)
                if distance >= Self.dragExpandThreshold, !items.isEmpty {
                    cancelHoldTimer()
                    expandMenu(fingerInWindow: pointInWindow)
                }
            } else {
                activeOverlay?.updateFinger(at: pointInWindow)
            }

        case .ended:
            cancelHoldTimer()
            let wasExpanded = isExpanded
            isPressing = false
            isExpanded = false

            if wasExpanded {
                let chosen = activeOverlay?.collapseAndReturnSelectedItem()
                onExpandedChanged?(false)
                if let chosen {
                    mediumImpact.impactOccurred()
                    chosen.action()
                }
            } else {
                setRestingPressed(false)
                let distance = hypot(
                    pointInWindow.x - touchStartInWindow.x,
                    pointInWindow.y - touchStartInWindow.y)
                if distance < Self.dragExpandThreshold {
                    lightImpact.impactOccurred()
                    onTap?()
                }
            }

        case .cancelled, .failed:
            cancelHoldTimer()
            let wasExpanded = isExpanded
            isPressing = false
            isExpanded = false
            setRestingPressed(false)
            if wasExpanded {
                _ = activeOverlay?.collapseAndReturnSelectedItem(executeSelection: false)
                onExpandedChanged?(false)
            }

        default:
            break
        }
    }

    private func expandMenu(fingerInWindow: CGPoint) {
        guard let window, let orbIcon, let orbFrame = orbFrameInWindow, !items.isEmpty else {
            return
        }
        isExpanded = true

        // Cleanly tear down any lingering collapsing overlay before opening fresh
        activeOverlay?.removeFromSuperview()
        activeOverlay = nil

        orbContainer.isHidden = true
        orbContainer.transform = .identity
        orbContainer.alpha = 0.45

        lightImpact.impactOccurred()
        onExpandedChanged?(true)

        let overlay = QuickActionWindowOverlay(
            frame: window.bounds,
            orbFrame: orbFrame,
            orbIcon: orbIcon,
            items: items,
            initialFinger: fingerInWindow,
            orbFrameProvider: { [weak self] in self?.orbFrameInWindow ?? orbFrame },
            onSelectionChanged: { [weak self] armed in
                guard let self else { return }
                if armed {
                    self.selectionFeedback.selectionChanged()
                    self.selectionFeedback.prepare()
                } else {
                    self.softImpact.impactOccurred()
                    self.softImpact.prepare()
                }
            },
            onDidFinishCollapse: { [weak self, weak window] overlayView in
                guard let self else {
                    overlayView.removeFromSuperview()
                    return
                }
                if self.activeOverlay === overlayView {
                    self.activeOverlay = nil
                    self.orbContainer.isHidden = false
                }
                overlayView.removeFromSuperview()
                _ = window
            })
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(overlay)
        activeOverlay = overlay
        overlay.expand()
    }

    private func cancelHoldTimer() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
    }

    private func tearDownImmediately() {
        cancelHoldTimer()
        let wasExpanded = isExpanded
        isPressing = false
        isExpanded = false
        activeOverlay?.invalidateAndRemove()
        activeOverlay = nil
        orbContainer.isHidden = false
        orbContainer.transform = .identity
        orbContainer.alpha = 0.45
        if wasExpanded {
            onExpandedChanged?(false)
        }
    }
}

// MARK: - Window-Level Morphing Menu Overlay

private final class QuickActionWindowOverlay: UIView {
    private static let panelWidth: CGFloat = 192
    private static let rowHeight: CGFloat = 48
    private static let panelPadY: CGFloat = 6
    private static let leftShiftFromOrb: CGFloat = 28
    private static let barOverhangX: CGFloat = 7
    private static let barHeight: CGFloat = 50
    private static let cancelOverY: CGFloat = 58
    private static let cancelOverX: CGFloat = 92
    private static let cancelOverRight: CGFloat = 64

    private let items: [QuickActionItem]
    private let orbFrameProvider: () -> CGRect
    private let onSelectionChanged: (Bool) -> Void
    private let onDidFinishCollapse: (QuickActionWindowOverlay) -> Void

    private var originOrbFrame: CGRect
    private var expandedPanelFrame: CGRect
    private var touchOriginX: CGFloat
    private let panelHeight: CGFloat

    // 3-layer hierarchy inside a single transformable stage:
    //   1. panelShadowContainer -> panelBlurView (morphing glass panel)
    //   2. highlightBarView (oversized pure white backing pill, no duplicate text)
    //   3. rowViews (THE ONE AND ONLY set of rows, always painted on top!)
    private let stageView = UIView()
    private let panelShadowView = UIView()
    private let panelSurfaceView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let panelTintView = UIView()
    private let orbIconView = UIImageView()
    private let highlightBarView = UIView()
    private let rowContainerView = UIView()
    private var rowViews: [QuickActionRowView] = []

    // Interactive state
    private var isCollapsing = false
    private var armedIndex: Int?
    private var lastArmedIndex: Int

    // SwiftUI.Spring states stepped via UIUpdateLink
    private var expandSpring = SpringState<CGFloat>(0, duration: 0.38, bounce: 0.26)
    private var barVisSpring = SpringState<CGFloat>(0, duration: 0.24, bounce: 0.22)
    private var barTopSpring: SpringState<CGFloat>
    private var selectSprings: [SpringState<CGFloat>]
    private var microSpring = SpringState(SpringVec2(0, 0), duration: 0.135, bounce: 0.16)
    private var stretchScaleSpring = SpringState(SpringVec2(1, 1), duration: 0.2, bounce: 0.18)
    private var stretchShiftSpring = SpringState(SpringVec2(0, 0), duration: 0.2, bounce: 0.18)

    #if !targetEnvironment(macCatalyst)
        private var updateLink: UIUpdateLink?
    #else
        private var displayLink: CADisplayLink?
    #endif
    private var lastModelTime: TimeInterval?

    init(
        frame: CGRect,
        orbFrame: CGRect,
        orbIcon: QuickActionIcon,
        items: [QuickActionItem],
        initialFinger: CGPoint,
        orbFrameProvider: @escaping () -> CGRect,
        onSelectionChanged: @escaping (Bool) -> Void,
        onDidFinishCollapse: @escaping (QuickActionWindowOverlay) -> Void
    ) {
        self.items = items
        self.originOrbFrame = orbFrame
        self.touchOriginX = initialFinger.x
        self.orbFrameProvider = orbFrameProvider
        self.onSelectionChanged = onSelectionChanged
        self.onDidFinishCollapse = onDidFinishCollapse
        self.panelHeight = CGFloat(items.count) * Self.rowHeight + Self.panelPadY * 2

        let defaultIndex = max(0, items.count - 1)
        self.armedIndex = defaultIndex
        self.lastArmedIndex = defaultIndex
        let defaultRowTop = Self.rowTop(for: defaultIndex)
        self.barTopSpring = SpringState(defaultRowTop, duration: 0.24, bounce: 0.2)
        self.selectSprings = items.indices.map { _ in
            SpringState<CGFloat>(0, duration: 0.16, bounce: 0)
        }
        self.expandedPanelFrame = Self.computeExpandedPanelFrame(
            orbFrame: orbFrame, panelHeight: panelHeight, in: frame)

        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        setupHierarchy(orbIcon: orbIcon)
        setupUpdateLink()
        applyVisualState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private static func rowTop(for index: Int) -> CGFloat {
        panelPadY + CGFloat(index) * rowHeight
    }

    private static func computeExpandedPanelFrame(
        orbFrame: CGRect, panelHeight: CGFloat, in bounds: CGRect
    ) -> CGRect {
        let desiredMaxX = orbFrame.maxX - leftShiftFromOrb
        let desiredMaxY = orbFrame.maxY
        let safe = bounds.inset(by: UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 16))
        let x = clamp(desiredMaxX - panelWidth, safe.minX, max(safe.minX, safe.maxX - panelWidth))
        let y = clamp(
            desiredMaxY - panelHeight, safe.minY, max(safe.minY, safe.maxY - panelHeight))
        return CGRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }

    private func setupHierarchy(orbIcon: QuickActionIcon) {
        stageView.backgroundColor = .clear
        stageView.frame = bounds
        stageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(stageView)

        // Layer 1: Morphing glass panel (shadow outer + blurred surface inner)
        panelShadowView.backgroundColor = .clear
        panelShadowView.layer.shadowColor = UIColor.black.cgColor
        panelShadowView.layer.shadowOpacity = 0.34
        panelShadowView.layer.shadowOffset = CGSize(width: 0, height: 12)
        panelShadowView.layer.shadowRadius = 22
        stageView.addSubview(panelShadowView)

        panelSurfaceView.overrideUserInterfaceStyle = .dark
        panelSurfaceView.clipsToBounds = true
        panelSurfaceView.layer.cornerCurve = .continuous
        panelShadowView.addSubview(panelSurfaceView)

        panelTintView.backgroundColor = .clear
        panelSurfaceView.contentView.addSubview(panelTintView)

        orbIconView.contentMode = .scaleAspectFit
        orbIconView.tintColor = .white
        orbIconView.image = orbIcon.makeUIImage(pointSize: 16, weight: .medium)
        panelSurfaceView.contentView.addSubview(orbIconView)

        // Layer 2: Oversized white highlight bar (pure backing surface, NO duplicate text)
        highlightBarView.backgroundColor = .white
        highlightBarView.layer.cornerRadius = 17
        highlightBarView.layer.cornerCurve = .continuous
        highlightBarView.layer.shadowColor = UIColor.black.cgColor
        highlightBarView.layer.shadowOpacity = 0.24
        highlightBarView.layer.shadowOffset = CGSize(width: 0, height: 8)
        highlightBarView.layer.shadowRadius = 18
        stageView.addSubview(highlightBarView)

        // Layer 3: The single top-layer rows
        rowContainerView.clipsToBounds = true
        stageView.addSubview(rowContainerView)
        rowViews = items.map { item in
            let row = QuickActionRowView(item: item)
            rowContainerView.addSubview(row)
            return row
        }
    }

    // MARK: - Lifecycle & Control

    func expand() {
        isCollapsing = false
        expandSpring.target = 1
        barVisSpring.target = 1
        if let armedIndex {
            barTopSpring.snap(to: Self.rowTop(for: armedIndex))
            for i in selectSprings.indices {
                selectSprings[i].target = (i == armedIndex) ? 1 : 0
            }
        }
        setUpdatesActive(true)
    }

    func updateFinger(at point: CGPoint) {
        guard !isCollapsing else { return }

        let panel = expandedPanelFrame
        let overTop = max(0, panel.minY - point.y)
        let overBottom = max(0, point.y - panel.maxY)
        let overLeft = max(0, panel.minX - point.x)
        let overRight = max(0, point.x - (bounds.maxX - 4))

        let cancelled =
            overTop > Self.cancelOverY || overBottom > Self.cancelOverY
            || overLeft > Self.cancelOverX || overRight > Self.cancelOverRight

        // Signed continuous over-drag (constant [0.5, 0.5] pivot + additive shifts → zero jitter!)
        let overY = overBottom - overTop
        let overX = overRight - overLeft

        let vStretch = rubber(abs(overY), limit: 95) / 95
        let hStretch = rubber(abs(overX), limit: 110) / 110

        stretchScaleSpring.target = SpringVec2(
            1 + 0.065 * hStretch - 0.045 * vStretch,
            1 + 0.11 * vStretch - 0.03 * hStretch)

        let inBoundsX = clamp(point.x, panel.minX, bounds.maxX - 4)
        let inBoundsY = clamp(point.y, panel.minY, panel.maxY)

        let anchorCompY = signOf(overY) * 0.5 * (0.11 * vStretch) * panelHeight
        let anchorCompX = signOf(overX) * 0.5 * (0.065 * hStretch) * Self.panelWidth

        stretchShiftSpring.target = SpringVec2(
            rubber((inBoundsX - touchOriginX) * 0.035, limit: 4)
                + rubber(overX * 0.24, limit: 20)
                + anchorCompX,
            rubber((inBoundsY - panel.midY) * 0.03, limit: 3)
                + rubber(overY * 0.30, limit: 22)
                + anchorCompY)

        let previousArmed = armedIndex

        if cancelled {
            armedIndex = nil
            barVisSpring.target = 0
            microSpring.target = .zero
            for i in selectSprings.indices {
                selectSprings[i].target = 0
            }
            if previousArmed != nil {
                onSelectionChanged(false)
            }
        } else {
            let rawRow = Int(floor((point.y - (panel.minY + Self.panelPadY)) / Self.rowHeight))
            let newIndex = clamp(rawRow, 0, items.count - 1)
            armedIndex = newIndex
            lastArmedIndex = newIndex
            barVisSpring.target = 1
            barTopSpring.target = Self.rowTop(for: newIndex)

            let rowCenterY = panel.minY + Self.rowTop(for: newIndex) + Self.rowHeight / 2
            microSpring.target = SpringVec2(
                rubber((point.x - touchOriginX) * 0.14, limit: 7.5),
                rubber((point.y - rowCenterY) * 0.24, limit: 6.0))

            for i in selectSprings.indices {
                selectSprings[i].target = (i == newIndex) ? 1 : 0
            }

            if newIndex != previousArmed {
                onSelectionChanged(true)
            }
        }

        setUpdatesActive(true)
    }

    func collapseAndReturnSelectedItem(executeSelection: Bool = true) -> QuickActionItem? {
        let selected = executeSelection ? armedIndex.map { items[$0] } : nil
        isCollapsing = true
        originOrbFrame = orbFrameProvider()
        armedIndex = nil

        expandSpring.target = 0
        barVisSpring.target = 0
        microSpring.target = .zero
        stretchScaleSpring.target = SpringVec2(1, 1)
        stretchShiftSpring.target = .zero
        for i in selectSprings.indices {
            selectSprings[i].target = 0
        }

        setUpdatesActive(true)
        return selected
    }

    func invalidateAndRemove() {
        setUpdatesActive(false)
        #if !targetEnvironment(macCatalyst)
            updateLink = nil
        #endif
        removeFromSuperview()
    }

    // MARK: - UIUpdateLink Frame Loop

    private func setupUpdateLink() {
        #if !targetEnvironment(macCatalyst)
            let link = UIUpdateLink(view: self) { [weak self] _, info in
                self?.step(modelTime: info.modelTime)
            }
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60, maximum: 120, preferred: 120)
            link.requiresContinuousUpdates = true
            updateLink = link
        #endif
    }

    private func setUpdatesActive(_ active: Bool) {
        #if !targetEnvironment(macCatalyst)
            if active {
                if updateLink?.isEnabled != true {
                    lastModelTime = nil
                    updateLink?.isEnabled = true
                }
            } else {
                updateLink?.isEnabled = false
                lastModelTime = nil
            }
        #else
            if active {
                guard displayLink == nil else { return }
                lastModelTime = nil
                let link = CADisplayLink(target: self, selector: #selector(catalystTick(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            } else {
                displayLink?.invalidate()
                displayLink = nil
                lastModelTime = nil
            }
        #endif
    }

    #if targetEnvironment(macCatalyst)
        @objc private func catalystTick(_ link: CADisplayLink) {
            step(modelTime: link.timestamp)
        }
    #endif

    private func step(modelTime: TimeInterval) {
        let rawDt = lastModelTime.map { modelTime - $0 } ?? (1.0 / 120.0)
        lastModelTime = modelTime
        let dt = min(max(rawDt, 1.0 / 240.0), 1.0 / 30.0)

        expandSpring.step(dt: dt)
        barVisSpring.step(dt: dt)
        barTopSpring.step(dt: dt)
        microSpring.step(dt: dt)
        stretchScaleSpring.step(dt: dt)
        stretchShiftSpring.step(dt: dt)
        for i in selectSprings.indices { selectSprings[i].step(dt: dt) }

        applyVisualState()

        let allSettled =
            expandSpring.isSettled && barVisSpring.isSettled && barTopSpring.isSettled
            && microSpring.isSettled && stretchScaleSpring.isSettled
            && stretchShiftSpring.isSettled
            && selectSprings.allSatisfy(\.isSettled)

        if allSettled {
            setUpdatesActive(false)
            if isCollapsing {
                onDidFinishCollapse(self)
            }
        }
    }

    // MARK: - Frame Layout & Rendering

    private func applyVisualState() {
        let ep = expandSpring.value
        let epClamped = clamp01(ep)
        let bv = barVisSpring.value
        let bvClamped = clamp01(bv)

        // Interpolate panel frame with UNCLAMPED spring `ep` for authentic overshoot & settle!
        let orb = originOrbFrame
        let target = expandedPanelFrame
        let w = max(20, orb.width + ep * (target.width - orb.width))
        let h = max(20, orb.height + ep * (target.height - orb.height))
        let maxX = orb.maxX + ep * (target.maxX - orb.maxX)
        let maxY = orb.maxY + ep * (target.maxY - orb.maxY)
        let panelFrame = CGRect(x: maxX - w, y: maxY - h, width: w, height: h)
        let maxPanelCornerRadius = min(panelFrame.width, panelFrame.height) / 2

        // Apply continuous rubber-band deformation around panel center (constant [0.5, 0.5] pivot!)
        let panelCenter = CGPoint(x: panelFrame.midX, y: panelFrame.midY)
        let sx = max(0.75, stretchScaleSpring.value.first)
        let sy = max(0.75, stretchScaleSpring.value.second)
        let tx = stretchShiftSpring.value.first
        let ty = stretchShiftSpring.value.second
        let microX = microSpring.value.first
        let microY = microSpring.value.second

        stageView.transform = .identity
        stageView.bounds = bounds
        stageView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        var stageTransform = CGAffineTransform.identity
        stageTransform = stageTransform.translatedBy(
            x: panelCenter.x - bounds.midX + tx, y: panelCenter.y - bounds.midY + ty)
        stageTransform = stageTransform.scaledBy(x: sx, y: sy)
        stageTransform = stageTransform.translatedBy(
            x: -(panelCenter.x - bounds.midX), y: -(panelCenter.y - bounds.midY))
        stageView.transform = stageTransform

        // Layer 1: Morphing Glass Panel
        let cornerRadius = min(maxPanelCornerRadius, (orb.height / 2) + epClamped * (22 - orb.height / 2))
        panelShadowView.frame = panelFrame
        panelShadowView.layer.shadowPath =
            UIBezierPath(roundedRect: panelShadowView.bounds, cornerRadius: cornerRadius).cgPath
        panelShadowView.layer.shadowOpacity = Float(0.18 + epClamped * 0.16)
        panelShadowView.layer.shadowRadius = 10 + epClamped * 14

        panelSurfaceView.frame = panelShadowView.bounds
        panelSurfaceView.layer.cornerRadius = cornerRadius
        panelTintView.frame = panelSurfaceView.bounds

        // Resting orb glyph crossfades smoothly out as morph begins
        let orbIconAlpha = clamp01(1 - epClamped * 3.4)
        orbIconView.alpha = orbIconAlpha * 0.92
        orbIconView.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        orbIconView.center = CGPoint(x: w / 2, y: h / 2)
        let orbIconScale = max(0.5, 1 - epClamped * 0.35)
        orbIconView.transform = CGAffineTransform(scaleX: orbIconScale, y: orbIconScale)

        // Single top-layer rows opacity
        let rowsAlpha = clamp01((epClamped - 0.44) * 2.0)

        // Layer 2: Oversized White Highlight Bar (pure backing surface)
        let showBar = bvClamped > 0.005 && epClamped > 0.45
        highlightBarView.isHidden = !showBar
        if showBar {
            let barW = max(36, w + Self.barOverhangX * 2 * epClamped)
            let barX = panelFrame.minX - Self.barOverhangX * epClamped
            let barTopInPanel = (barTopSpring.value / panelHeight) * h
            let barY = panelFrame.minY + barTopInPanel - 1
            let barScale = max(0.7, 0.86 + bv * 0.14)

            highlightBarView.transform = .identity
            highlightBarView.bounds = CGRect(x: 0, y: 0, width: barW, height: Self.barHeight)
            highlightBarView.center = CGPoint(
                x: barX + barW / 2 + microX,
                y: barY + Self.barHeight / 2 + microY)
            highlightBarView.transform = CGAffineTransform(scaleX: barScale, y: barScale)
            highlightBarView.alpha = clamp01(bvClamped * rowsAlpha * 1.2)
        }

        // Layer 3: Single top-layer rows (smooth color lerp + magnetic center attraction)
        rowContainerView.frame = panelFrame
        rowContainerView.layer.cornerRadius = cornerRadius
        let rowContainerBlurFilter = QuartzFilter.gaussianBlur()
        rowContainerBlurFilter.radius = (1 - epClamped) * 20
        rowContainerView.layer.quartzFilters = [rowContainerBlurFilter]
        for (index, rowView) in rowViews.enumerated() {
            let sp = selectSprings[index].value
            let spClamped = clamp01(sp)
            let itemRowTop = Self.rowTop(for: index)

            let barDeltaY = (barTopSpring.value - itemRowTop) * 0.1
            let attractX = microX * sp
            let attractY = (barDeltaY + microY) * sp
            let rowScale = 1 + spClamped * 0.025

            rowView.transform = .identity
            rowView.bounds = CGRect(x: 0, y: 0, width: target.width, height: Self.rowHeight)
            rowView.center = CGPoint(
                x: w / 2 + attractX,
                y: itemRowTop + Self.rowHeight / 2 + attractY)
            rowView.transform = CGAffineTransform(scaleX: rowScale, y: rowScale)
            rowView.alpha = clamp01(rowsAlpha * (0.94 + spClamped * 0.06))
            rowView.updateSelection(progress: spClamped)
        }
    }
}

// MARK: - Single Top-Layer Menu Row View (Smooth Color & Weight Interpolation)

private final class QuickActionRowView: UIView {
    private let item: QuickActionItem
    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    private static let normalUnselected = RGBColor(r: 1, g: 1, b: 1)
    private static let normalSelected = RGBColor(r: 17 / 255, g: 17 / 255, b: 19 / 255)
    private static let dangerUnselected = RGBColor(r: 1, g: 182 / 255, b: 178 / 255)
    private static let dangerSelected = RGBColor(r: 215 / 255, g: 0, b: 21 / 255)

    private var lastAppliedProgress: CGFloat = -1
    private var isSemibold = false

    init(item: QuickActionItem) {
        self.item = item
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .clear

        iconView.contentMode = .scaleAspectFit
        iconView.image = item.icon.makeUIImage(pointSize: 17, weight: .medium)
        addSubview(iconView)

        titleLabel.text = item.title
        titleLabel.font = .systemFont(ofSize: 14.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        updateSelection(progress: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconSize: CGFloat = 22
        let leading: CGFloat = 18
        let gap: CGFloat = 12
        iconView.frame = CGRect(
            x: leading,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize)
        let labelX = leading + iconSize + gap
        titleLabel.frame = CGRect(
            x: labelX,
            y: 0,
            width: max(0, bounds.width - labelX - 14),
            height: bounds.height)
    }

    func updateSelection(progress t: CGFloat) {
        guard abs(t - lastAppliedProgress) > 0.002 else { return }
        lastAppliedProgress = t

        if item.role == .destructive {
            iconView.tintColor = RGBColor.lerp(
                Self.dangerUnselected, Self.dangerSelected, t: t)
            titleLabel.textColor = RGBColor.lerp(
                Self.dangerUnselected, Self.dangerSelected, t: t)
        } else {
            let color = RGBColor.lerp(Self.normalUnselected, Self.normalSelected, t: t)
            iconView.tintColor = color
            titleLabel.textColor = color
        }

        let semibold = t > 0.5
        if semibold != isSemibold {
            isSemibold = semibold
            titleLabel.font = .systemFont(ofSize: 14.5, weight: semibold ? .semibold : .medium)
        }
    }
}

// MARK: - Math Helpers

private struct RGBColor {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat

    static func lerp(_ a: RGBColor, _ b: RGBColor, t: CGFloat) -> UIColor {
        let k = clamp01(t)
        return UIColor(
            red: a.r + (b.r - a.r) * k,
            green: a.g + (b.g - a.g) * k,
            blue: a.b + (b.b - a.b) * k,
            alpha: 1)
    }
}

private func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
    min(high, max(low, value))
}

private func clamp01(_ value: CGFloat) -> CGFloat {
    clamp(value, 0, 1)
}

private func signOf(_ value: CGFloat) -> CGFloat {
    if value > 0 { return 1 }
    if value < 0 { return -1 }
    return 0
}

private func rubber(_ delta: CGFloat, limit: CGFloat) -> CGFloat {
    guard delta != 0, limit > 0 else { return 0 }
    let s = signOf(delta)
    let a = abs(delta)
    return s * limit * (1 - exp(-a / limit))
}
