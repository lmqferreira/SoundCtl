import AppKit
import SwiftUI

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
        if arguments.contains("--debug-popover") {
            runDebugPopover(arguments: arguments)
            return
        }
        if arguments.contains("--debug-hud") {
            runDebugHUD(arguments: arguments)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Renders the HUD content offscreen to a PNG (deterministic; avoids
    /// multi-display capture flakiness). Debug only.
    private static func runDebugHUD(arguments: [String]) {
        if arguments.contains("--screen") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            if arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
            let hud = VolumeHUD()
            DispatchQueue.main.async { hud.show(level: 0.625, muted: false) }
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.8)
                let t = Process()
                t.launchPath = "/usr/sbin/screencapture"
                // Multiple files => one per display, so we catch whichever it lands on.
                t.arguments = ["-x", "/tmp/hud_d1.png", "/tmp/hud_d2.png", "/tmp/hud_d3.png"]
                try? t.run(); t.waitUntilExit()
                exit(0)
            }
            app.run()
            return
        }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        if arguments.contains("--dark") {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        let out = arguments.first(where: { $0.hasPrefix("--out=") })?
            .replacingOccurrences(of: "--out=", with: "") ?? "/tmp/soundctl_hud.png"

        let model = HUDModel()
        model.level = 0.625
        model.muted = false
        let host = NSHostingView(rootView:
            VolumeHUDView(model: model)
                .background(Color(white: 0.12))   // stand-in for the glass, for contrast
        )
        host.appearance = NSApp.appearance
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: out))
                print("wrote \(out) size=\(host.bounds.size)")
            }
        }
    }

    /// Shows the real two-window popover at a fixed point and screenshots it, so
    /// the rendering (e.g. the slider knob) can be inspected. Debug only.
    private static func runDebugPopover(arguments: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if arguments.contains("--dark") {
            app.appearance = NSAppearance(named: .darkAqua)
        }
        let audio = AudioController()
        let ddc = DDCController()
        let coordinator = VolumeCoordinator(audio: audio, ddc: ddc)
        let model = PopoverModel(audio: audio, coordinator: coordinator)
        let panel = PanelController(model: model)

        let out = arguments.first(where: { $0.hasPrefix("--out=") })?
            .replacingOccurrences(of: "--out=", with: "") ?? "/tmp/soundctl_popover.png"

        DispatchQueue.main.async {
            panel.debugShow(at: NSPoint(x: 500, y: 500))
        }
        if arguments.contains("--cycle") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { panel.close() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { panel.debugShow(at: NSPoint(x: 500, y: 500)) }
        }
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 2.0)
            let t = Process()
            t.launchPath = "/usr/sbin/screencapture"
            t.arguments = ["-x", out]
            try? t.run(); t.waitUntilExit()
            exit(0)
        }
        app.run()
    }

    private static func runMeasure() {        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        let audio = AudioController()
        let ddc = DDCController()
        let coordinator = VolumeCoordinator(audio: audio, ddc: ddc)
        let model = PopoverModel(audio: audio, coordinator: coordinator)
        model.reload()
        let host = NSHostingView(rootView: SoundPopoverView(model: model))
        host.layoutSubtreeIfNeeded()
        print("fittingSize:", host.fittingSize)
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
