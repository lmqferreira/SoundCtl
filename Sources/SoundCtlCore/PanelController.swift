import AppKit

/// Hosts the Sound content in a borderless, arrow-less window that drops down
/// from the status item, right-aligned to the icon (with on-screen clamping).
/// The content view supplies the frosted material; we just provide the window,
/// shadow, positioning and dismissal.
final class PanelController {

    private let panel: NSPanel
    private let viewController: SoundPopoverViewController
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private(set) var isShown = false
    private var lastCloseTime: Date?

    /// Fired with `true` when the panel appears and `false` when it dismisses,
    /// so the owner can keep the status item highlighted while it's open.
    var onVisibilityChanged: ((Bool) -> Void)?

    init(viewController: SoundPopoverViewController) {
        self.viewController = viewController

        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = viewController.view
    }

    func toggle(relativeTo statusButton: NSStatusBarButton) {
        if isShown {
            close()
        } else {
            if let t = lastCloseTime, Date().timeIntervalSince(t) < 0.25 { return }
            show(relativeTo: statusButton)
        }
    }

    func show(relativeTo statusButton: NSStatusBarButton) {
        viewController.rebind()

        let fitting = viewController.view.fittingSize
        panel.setContentSize(fitting)

        guard let buttonWindow = statusButton.window else { return }
        let buttonFrameOnScreen = buttonWindow.convertToScreen(
            statusButton.convert(statusButton.bounds, to: nil))

        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = Self.computeOrigin(buttonFrame: buttonFrameOnScreen,
                                        contentSize: fitting,
                                        visibleFrame: visible)

        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        isShown = true
        installDismissMonitors()
        onVisibilityChanged?(true)
    }

    /// Bottom-left origin: drop the popover below the icon, shown to the RIGHT of
    /// it by default (left-aligned, extends right). Only when the icon is too
    /// close to the right screen edge, flip to the LEFT (right-aligned, extends
    /// left). Then clamp on-screen. Pure function for testing.
    static func computeOrigin(buttonFrame: NSRect,
                              contentSize: NSSize,
                              visibleFrame: NSRect,
                              gap: CGFloat = 6,
                              margin: CGFloat = 8) -> NSPoint {
        // Default: left-align to the icon so the popover extends rightward.
        var originX = buttonFrame.minX
        // Not enough room on the right -> flip so it extends leftward.
        if originX + contentSize.width > visibleFrame.maxX - margin {
            originX = buttonFrame.maxX - contentSize.width
        }
        // Final clamp fully on-screen.
        originX = min(max(originX, visibleFrame.minX + margin),
                      visibleFrame.maxX - margin - contentSize.width)

        var originY = buttonFrame.minY - gap - contentSize.height
        if originY < visibleFrame.minY + margin {
            originY = visibleFrame.minY + margin
        }
        return NSPoint(x: originX, y: originY)
    }

    func close() {
        guard isShown else { return }
        isShown = false
        lastCloseTime = Date()
        removeDismissMonitors()
        onVisibilityChanged?(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    // MARK: - Dismissal

    private func installDismissMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window != self.panel {
                self.close()
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
