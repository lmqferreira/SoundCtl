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

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static func runMeasure() {
        _ = NSApplication.shared
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
