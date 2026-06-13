import AppKit

/// Entry point for the SoundCtl menu-bar agent. Lives in the library target so
/// the executable stays a one-liner and all logic remains unit-testable.
public enum AppMain {

    public static func run(arguments: [String] = CommandLine.arguments) {
        if arguments.contains("--self-test") {
            let failures = SelfTests.run()
            exit(failures == 0 ? 0 : 1)
        }
        if arguments.contains("--measure") {
            runMeasure()
            return
        }
        if arguments.contains("--ddc-test") {
            runDDCTest(arguments: arguments)
            return
        }
        if arguments.contains("--debug-menu") {
            runDebugMenu(arguments: arguments)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Renders the popover inside a real NSMenu and screenshots it (via a
    /// background thread, since popUp blocks) so the layout can be measured with
    /// the menu's own insets. Debug only.
    private static func runDebugMenu(arguments: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let audio = AudioController()
        let ddc = DDCController()
        let coordinator = VolumeCoordinator(audio: audio, ddc: ddc)
        let vc = SoundPopoverViewController(audio: audio, coordinator: coordinator)
        _ = vc.view
        vc.rebind()
        let size = vc.view.fittingSize
        vc.view.setFrameSize(size)
        vc.view.layoutSubtreeIfNeeded()

        let menu = NSMenu()
        let item = NSMenuItem()
        item.view = vc.view
        menu.addItem(item)

        let out = arguments.first(where: { $0.hasPrefix("--out=") })?
            .replacingOccurrences(of: "--out=", with: "") ?? "/tmp/ours_menu.png"
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 1.0)
            let t = Process()
            t.launchPath = "/usr/sbin/screencapture"
            t.arguments = ["-x", out]
            try? t.run(); t.waitUntilExit()
            exit(0)
        }
        let w = NSWindow(contentRect: NSRect(x: 400, y: 700, width: 40, height: 24),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.orderFrontRegardless()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: w.contentView)
        exit(0)
    }

    private static func runMeasure() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let audio = AudioController()
        let ddc = DDCController()
        let coordinator = VolumeCoordinator(audio: audio, ddc: ddc)
        let vc = SoundPopoverViewController(audio: audio, coordinator: coordinator)
        _ = vc.view
        vc.rebind()
        vc.view.layoutSubtreeIfNeeded()
        print("fittingSize:", vc.view.fittingSize)
        print("devices:", audio.devices.map { "\($0.name)[\($0.iconSymbol)]" })
    }

    private static func runDDCTest(arguments: [String]) {
        let ddc = DDCController()
        let displays = ddc.debugDisplays()
        print("Discovered external DDC services: \(displays.count)")
        for (name, display) in displays {
            let label = name.isEmpty ? "<unnamed>" : name
            if let v = display.readVolume() {
                print("  • \(label): VCP 0x62 volume = \(Int((v * 100).rounded()))%")
            } else {
                print("  • \(label): VCP 0x62 read FAILED")
            }
        }
        if let target = arguments.first(where: { $0.hasPrefix("--set=") }),
           let pct = Float(target.dropFirst("--set=".count)), let (_, display) = displays.first {
            print("Setting volume to \(Int(pct))% ...")
            display.writeVolume(pct / 100)
            usleep(300000)
            if let v = display.readVolume() {
                print("Read back: \(Int((v * 100).rounded()))%")
            }
        }
    }
}
