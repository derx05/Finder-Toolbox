import AppKit
import SwiftUI
import Combine

// MARK: - State

enum NotchFeedbackState: Equatable, Hashable {
    struct ChoiceOption: Equatable, Hashable {
        let id: String
        let label: String
    }

    case progress(message: String, value: Double?)   // value nil = indeterminate
    case success(message: String)
    case warning(message: String, detail: String?)
    case error(message: String, detail: String?)
    case choice(prompt: String, options: [ChoiceOption])
}

// MARK: - View Model

@MainActor
final class NotchFeedbackModel: ObservableObject {
    @Published var state: NotchFeedbackState = .progress(message: "", value: nil)
    @Published var isDetailExpanded: Bool = false
    /// Drives the content opacity fade; decoupled from the shape grow animation.
    @Published var contentVisible: Bool = false
    /// Set by the controller before showing a .choice state; called by the
    /// view when the user taps an option. nil = cancel / dismiss.
    var onChoiceSelected: ((String?) -> Void)?
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

    /// Actual notch width in points, derived from the auxiliary top areas Apple
    /// exposes for exactly this purpose. Falls back to 162 pt if the APIs return
    /// zero (shouldn't happen on notch screens, but safe to guard).
    /// Formula from NSScreen.auxiliaryTopLeftArea / auxiliaryTopRightArea docs:
    ///   notchWidth = screen.width − leftAuxWidth − rightAuxWidth
    private var notchNativeWidth: CGFloat {
        let left = targetScreen.auxiliaryTopLeftArea?.width ?? 0
        let right = targetScreen.auxiliaryTopRightArea?.width ?? 0
        guard left > 0, right > 0 else { return 162 }
        return targetScreen.frame.width - left - right
    }

    static let contentWidth: CGFloat = 280
    // All four corners use this radius. On notch screens the panel extends this
    // many points above the screen boundary so the rounded top corners are
    // off-screen — the display edge clips them, producing flat-looking top edges
    // without any maskedCorners tricks.
    static let cornerRadius: CGFloat = 12

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

        let inset = targetScreen.safeAreaInsets.top
        let container = RoundedContainerView(cornerRadius: Self.cornerRadius)
        container.autoresizingMask = [.width, .height]

        // On notch screens the panel extends cornerRadius pts above the screen boundary
        // so the rounded top corners fall off-screen. The display edge clips them,
        // making the top appear flat without maskedCorners. Add cornerRadius to the
        // topInset so SwiftUI content still starts just below the physical notch.
        let swiftUITopInset = inset > 0 ? inset + Self.cornerRadius : inset
        let host = NSHostingView(rootView: NotchFeedbackView(model: model, topInset: swiftUITopInset))
        // Autoresizing mask (not Auto Layout) so the host scales with the container
        // during CoreAnimation frame animations without needing a layout pass.
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
    }

    // MARK: Frame helpers

    /// Collapsed "seed" frame used as the animation start point.
    /// On notch screens: notch-width pill that extends cornerRadius pts above the
    /// screen boundary so rounded top corners are always off-screen.
    /// On non-notch: a thin 4 pt pill just below the menu bar.
    private var collapsedFrame: NSRect {
        let inset = notchInset
        if inset > 0 {
            let w = notchNativeWidth
            return NSRect(
                x: targetScreen.frame.midX - w / 2,
                y: targetScreen.frame.maxY - inset,
                width: w,
                height: inset + Self.cornerRadius
            )
        } else {
            let menuBar = NSStatusBar.system.thickness
            return NSRect(
                x: targetScreen.frame.midX - 80,
                y: targetScreen.frame.maxY - menuBar - 16 - 4,
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
                height: h + Self.cornerRadius
            )
        } else {
            let menuBar = NSStatusBar.system.thickness
            return NSRect(
                x: targetScreen.frame.midX - Self.contentWidth / 2,
                y: targetScreen.frame.maxY - menuBar - 16 - contentHeight,
                width: Self.contentWidth,
                height: contentHeight
            )
        }
    }

    // MARK: Animation API

    func placeCollapsed() {
        setFrame(collapsedFrame, display: false)
    }

    func placeExpanded(contentHeight: CGFloat) {
        setFrame(expandedFrame(contentHeight: contentHeight), display: false)
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
                l.cornerRadius = Self.cornerRadius
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
    private static let choiceContentHeight: CGFloat = 90
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
        withAnimation(.easeInOut(duration: 0.22)) { model.state = .progress(message: message, value: value) }
        present(contentHeight: Self.contentHeight)
    }

    func updateProgress(message: String? = nil, value: Double?) {
        guard case .progress(let current, _) = model.state else { return }
        withAnimation(.easeInOut(duration: 0.15)) { model.state = .progress(message: message ?? current, value: value) }
    }

    func showSuccess(_ message: String, autoDismissAfter seconds: TimeInterval = 2.5) {
        dismissTask?.cancel()
        model.isDetailExpanded = false
        withAnimation(.easeInOut(duration: 0.22)) { model.state = .success(message: message) }
        present(contentHeight: Self.contentHeight)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Present a choice prompt with labelled buttons inside the notch and return
    /// the chosen option's `id`, or `nil` if the user cancelled. The caller
    /// awaits this on the main actor; the continuation is resumed when the user
    /// taps a button or hits Cancel. Any previously pending choice is cancelled
    /// before the new one is presented.
    func askChoice(prompt: String, options: [(id: String, label: String)]) async -> String? {
        // Cancel any choice already in flight before starting a new one.
        let prev = model.onChoiceSelected
        model.onChoiceSelected = nil
        prev?(nil)

        dismissTask?.cancel()
        dismissTask = nil
        sizeObserver = nil
        model.isDetailExpanded = false

        let mapped = options.map { NotchFeedbackState.ChoiceOption(id: $0.id, label: $0.label) }
        withAnimation(.easeInOut(duration: 0.22)) { model.state = .choice(prompt: prompt, options: mapped) }
        present(contentHeight: Self.choiceContentHeight)

        return await withCheckedContinuation { continuation in
            model.onChoiceSelected = { [weak self] selected in
                self?.model.onChoiceSelected = nil
                if selected == nil { self?.dismiss() }
                continuation.resume(returning: selected)
            }
        }
    }

    func showWarning(_ message: String, detail: String? = nil) {
        dismissTask?.cancel()
        dismissTask = nil
        model.isDetailExpanded = false
        withAnimation(.easeInOut(duration: 0.22)) { model.state = .warning(message: message, detail: detail) }
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

    func showError(_ message: String, detail: String? = nil) {
        dismissTask?.cancel()
        dismissTask = nil
        model.isDetailExpanded = false
        withAnimation(.easeInOut(duration: 0.22)) { model.state = .error(message: message, detail: detail) }
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
        if p.notchInset > 0 {
            model.contentVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak p] in
                p?.animateCollapse()
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                p.animator().alphaValue = 0
            }, completionHandler: { [weak p] in
                p?.orderOut(nil)
                p?.alphaValue = 1
            })
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
            p.animateResize(contentHeight: contentHeight)
        } else if p.notchInset > 0 {
            // Notch screen: grow shape from notch seed, then fade content in.
            model.contentVisible = false
            p.placeCollapsed()
            p.orderFrontRegardless()
            p.applyCorners()
            p.animateExpand(contentHeight: contentHeight)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.contentFadeDelay) { [weak self] in
                self?.model.contentVisible = true
            }
        } else {
            // Non-notch: place at final size and fade the whole panel in.
            model.contentVisible = true
            p.alphaValue = 0
            p.placeExpanded(contentHeight: contentHeight)
            p.orderFrontRegardless()
            p.applyCorners()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1
            }
        }
    }

    private var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }
}
