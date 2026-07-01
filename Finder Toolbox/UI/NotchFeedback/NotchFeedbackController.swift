import AppKit
import SwiftUI
import Combine

// MARK: - State

enum NotchFeedbackState: Equatable {
    case progress(message: String, value: Double?)   // value nil = indeterminate
    case success(message: String)
    case error(message: String, detail: String?)
}

// MARK: - View Model

@MainActor
final class NotchFeedbackModel: ObservableObject {
    @Published var state: NotchFeedbackState = .progress(message: "", value: nil)
    @Published var isDetailExpanded: Bool = false
    /// Drives the content opacity fade; decoupled from the shape grow animation.
    @Published var contentVisible: Bool = false
}

// MARK: - Rounded container

/// Bare NSView whose only job is clipping children to a rounded rect.
/// Corner radius is applied at three points to survive AppKit's lazy layer
/// lifecycle: makeBackingLayer (creation), viewDidMoveToWindow (live layer),
/// and applyRounding (called explicitly after orderFrontRegardless).
private final class RoundedContainerView: NSView {
    private let radius: CGFloat

    init(cornerRadius: CGFloat) {
        self.radius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // Attempt 1: configure at layer-creation time.
    override func makeBackingLayer() -> CALayer {
        let l = super.makeBackingLayer()
        configure(l)
        return l
    }

    // Attempt 2: re-apply once the view is inside a live window (layer guaranteed
    // to exist here). Schedule async so it runs after the current call stack
    // finishes setting up the panel — belt-and-suspenders against AppKit resets.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.applyRounding() }
    }

    // Attempt 3: public entry for the panel to call after orderFrontRegardless().
    func applyRounding() {
        guard let layer else { return }
        configure(layer)
    }

    private func configure(_ layer: CALayer) {
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }
}

// MARK: - Panel

@MainActor
final class NotchFeedbackPanel: NSPanel {

    // Named `targetScreen` to avoid shadowing NSWindow.screen.
    private let targetScreen: NSScreen

    /// Physical notch dead-zone height. ≈ 32–38 pt on MacBook Pro/Air; 0 elsewhere.
    var notchInset: CGFloat { targetScreen.safeAreaInsets.top }

    // Start width matches the physical notch so the grow animation looks like the
    // notch itself is expanding.
    private static let notchNativeWidth: CGFloat = 162
    static let contentWidth: CGFloat = 280

    init(model: NotchFeedbackModel, targetScreen: NSScreen) {
        self.targetScreen = targetScreen
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // On non-notch screens the system draws a window shadow that follows the
        // pill's alpha mask. On notch screens shadow above the bezel looks wrong.
        hasShadow = (targetScreen.safeAreaInsets.top == 0)
        ignoresMouseEvents = false
        level = .popUpMenu
        appearance = NSApp.effectiveAppearance

        // Round corners via a custom NSView wrapper whose makeBackingLayer() override
        // sets cornerRadius at layer-creation time — the only hook guaranteed to run
        // before any draw cycle. Accessing host.layer directly after wantsLayer=true
        // returns nil until the first layout pass, which is why prior attempts silently
        // skipped the configuration.
        //
        // We use radius 12 on ALL four corners. On notch screens the physical bezel
        // covers the top ~notchInset pt of the panel, so the rounded top corners are
        // never visible; only the bottom two matter visually. No maskedCorners needed.
        let inset = targetScreen.safeAreaInsets.top
        let container = RoundedContainerView(cornerRadius: 12)
        container.autoresizingMask = [.width, .height]

        let host = NSHostingView(rootView: NotchFeedbackView(model: model, topInset: inset))
        // Autoresizing mask (not Auto Layout) so the host scales with the container
        // during CoreAnimation frame animations without needing a layout pass.
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
    }

    // MARK: Frame helpers

    /// Collapsed "seed" frame used as the animation start point.
    /// On notch screens: exactly the hardware notch shape (162 × notchInset),
    /// entirely within the dead zone — nothing is visible yet.
    /// On non-notch: a thin 4 pt pill just below the menu bar.
    private var collapsedFrame: NSRect {
        let inset = notchInset
        if inset > 0 {
            return NSRect(
                x: targetScreen.frame.midX - Self.notchNativeWidth / 2,
                y: targetScreen.frame.maxY - inset,
                width: Self.notchNativeWidth,
                height: inset
            )
        } else {
            let menuBar = NSStatusBar.system.thickness
            return NSRect(
                x: targetScreen.frame.midX - 80,
                y: targetScreen.frame.maxY - menuBar - 8 - 4,
                width: 160,
                height: 4
            )
        }
    }

    private func expandedFrame(contentHeight: CGFloat) -> NSRect {
        let inset = notchInset
        if inset > 0 {
            let h = inset + contentHeight
            return NSRect(
                x: targetScreen.frame.midX - Self.contentWidth / 2,
                y: targetScreen.frame.maxY - h,
                width: Self.contentWidth,
                height: h
            )
        } else {
            let menuBar = NSStatusBar.system.thickness
            return NSRect(
                x: targetScreen.frame.midX - Self.contentWidth / 2,
                y: targetScreen.frame.maxY - menuBar - 8 - contentHeight,
                width: Self.contentWidth,
                height: contentHeight
            )
        }
    }

    // MARK: Animation API

    func placeCollapsed() {
        setFrame(collapsedFrame, display: false)
    }

    func animateExpand(contentHeight: CGFloat, duration: TimeInterval = 0.38) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(expandedFrame(contentHeight: contentHeight), display: true)
        }
    }

    func animateCollapse(duration: TimeInterval = 0.25) {
        let target = collapsedFrame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    /// Resize while already expanded — no collapse, content stays visible.
    func animateResize(contentHeight: CGFloat, duration: TimeInterval = 0.28) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(expandedFrame(contentHeight: contentHeight), display: true)
        }
    }

    /// Force-applies corner radius after orderFrontRegardless(). By that point
    /// the window server has composited the panel and all backing layers exist.
    /// Applies to both the container layer and the NSHostingView layer, covering
    /// the case where NSHostingView's layer is not a sublayer of the container.
    func applyCorners() {
        (contentView as? RoundedContainerView)?.applyRounding()
        if let host = contentView?.subviews.first {
            host.wantsLayer = true
            if let l = host.layer {
                l.cornerRadius = 12
                l.cornerCurve = .continuous
                l.masksToBounds = true
            }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// Show temporary feedback inside the notch (or a top-center pill on non-notch
/// screens). The shape grows outward from the notch; content fades in near the
/// end of the expansion so it doesn't appear to slide in from the top.
/// Call from the main actor only.
@MainActor
final class NotchFeedbackController {

    static let shared = NotchFeedbackController()
    private init() {}

    private static let contentHeight: CGFloat = 42
    private static let expandedContentHeight: CGFloat = 82
    // Delay before fading content in, relative to shape animation start (0.38 s).
    // Waiting until the shape is ~75% done avoids visible stretching of text.
    private static let contentFadeDelay: TimeInterval = 0.28

    private var panel: NotchFeedbackPanel?
    private var model = NotchFeedbackModel()
    private var dismissTask: Task<Void, Never>?
    private var sizeObserver: AnyCancellable?

    // MARK: Public API

    func showProgress(_ message: String, value: Double? = nil) {
        dismissTask?.cancel()
        dismissTask = nil
        model.isDetailExpanded = false
        model.state = .progress(message: message, value: value)
        present(contentHeight: Self.contentHeight)
    }

    func updateProgress(message: String? = nil, value: Double?) {
        guard case .progress(let current, _) = model.state else { return }
        model.state = .progress(message: message ?? current, value: value)
    }

    func showSuccess(_ message: String, autoDismissAfter seconds: TimeInterval = 2.5) {
        dismissTask?.cancel()
        model.isDetailExpanded = false
        model.state = .success(message: message)
        present(contentHeight: Self.contentHeight)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func showError(_ message: String, detail: String? = nil) {
        dismissTask?.cancel()
        dismissTask = nil
        model.isDetailExpanded = false
        model.state = .error(message: message, detail: detail)
        present(contentHeight: Self.contentHeight)

        sizeObserver = model.$isDetailExpanded
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                guard let self, let p = self.panel else { return }
                let ch = expanded ? Self.expandedContentHeight : Self.contentHeight
                p.animateResize(contentHeight: ch)
            }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        sizeObserver = nil
        guard let p = panel, p.isVisible else { return }
        model.contentVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak p] in
            p?.animateCollapse()
        }
    }

    // MARK: Private

    private func present(contentHeight: CGFloat) {
        let chosenScreen = notchScreen ?? NSScreen.main ?? NSScreen.screens[0]
        if panel?.screen !== chosenScreen {
            panel?.orderOut(nil)
            panel = NotchFeedbackPanel(model: model, targetScreen: chosenScreen)
        }
        guard let p = panel else { return }

        let alreadyExpanded = p.isVisible && model.contentVisible
        if alreadyExpanded {
            // Already open: resize without collapsing.
            p.animateResize(contentHeight: contentHeight)
        } else {
            // Fresh appearance: grow shape from notch seed, then fade content in.
            model.contentVisible = false
            p.placeCollapsed()
            p.orderFrontRegardless()
            // Apply corner radius now that the panel is on-screen and the
            // backing layer is guaranteed to exist (belt over makeBackingLayer
            // + viewDidMoveToWindow in RoundedContainerView).
            p.applyCorners()
            p.animateExpand(contentHeight: contentHeight)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.contentFadeDelay) { [weak self] in
                self?.model.contentVisible = true
            }
        }
    }

    private var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }
}
