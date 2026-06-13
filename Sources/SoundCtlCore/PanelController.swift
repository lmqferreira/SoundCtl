import AppKit

/// A borderless panel that can become the *key* window. Key status is required
/// for AppKit controls (the NSSlider) to render in their active appearance —
/// an NSMenu's window is never key, which is why the slider looked grey there.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Hosts the Sound content in a key panel, right-aligned-with-fallback to the
/// status item, and dismisses when it loses key (outside click).
final class PanelController {

    private let panel: KeyablePanel
    private let viewController: SoundPopoverViewController
    private var resignObserver: NSObjectProtocol?

    private(set) var isShown = false
    private var lastCloseTime: Date?

    var onVisibilityChanged: ((Bool) -> Void)?

    init(viewController: SoundPopoverViewController) {
        self.viewController = viewController
        panel = KeyablePanel(contentRect: .zero,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = viewController.view
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown {
            close()
        } else {
            if let t = lastCloseTime, Date().timeIntervalSince(t) < 0.25 { return }
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        viewController.rebind()
        let size = viewController.contentSize
        viewController.view.setFrameSize(size)
        viewController.view.layoutSubtreeIfNeeded()
        panel.setContentSize(size)

        guard let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(Self.computeOrigin(buttonFrame: buttonFrame,
                                                contentSize: size, visibleFrame: visible))

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()      // active control appearance (blue slider)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        isShown = true
        onVisibilityChanged?(true)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        guard isShown else { return }
        isShown = false
        lastCloseTime = Date()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        onVisibilityChanged?(false)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.panel.orderOut(nil) })
    }

    /// Bottom-left origin: shown to the right of the icon by default
    /// (left-aligned, extends right); flips left near the right screen edge.
    static func computeOrigin(buttonFrame: NSRect,
                              contentSize: NSSize,
                              visibleFrame: NSRect,
                              gap: CGFloat = 6,
                              margin: CGFloat = 8) -> NSPoint {
        var originX = buttonFrame.minX
        if originX + contentSize.width > visibleFrame.maxX - margin {
            originX = buttonFrame.maxX - contentSize.width
        }
        originX = min(max(originX, visibleFrame.minX + margin),
                      visibleFrame.maxX - margin - contentSize.width)
        var originY = buttonFrame.minY - gap - contentSize.height
        if originY < visibleFrame.minY + margin {
            originY = visibleFrame.minY + margin
        }
        return NSPoint(x: originX, y: originY)
    }
}
