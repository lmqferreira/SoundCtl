import AppKit
import SwiftUI
import CoreAudio

/// Lightweight in-module test suite (the Command Line Tools ship no XCTest /
/// Testing framework). Run via `SoundCtl --self-test`; exits non-zero if any
/// check fails. Covers the popover model logic, audio behaviour, icon symbols,
/// and popover placement.
public enum SelfTests {

    @discardableResult
    public static func run() -> Int {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)

        var failures = 0
        var passes = 0
        var skips = 0

        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                passes += 1
                print("  ✓ \(name)")
            } else {
                failures += 1
                print("  ✗ FAIL: \(name)")
            }
        }
        func skip(_ name: String, _ reason: String) {
            skips += 1
            print("  – SKIP: \(name) (\(reason))")
        }

        print("SoundCtl self-test")

        let audio = AudioController()
        let coordinator = VolumeCoordinator(audio: audio, ddc: DDCController())
        let model = PopoverModel(audio: audio, coordinator: coordinator)
        model.reload()

        // MARK: Popover model
        print("[model]")
        check("renders one item per output device", model.devices.count == audio.devices.count)
        check("selected id mirrors the default output", model.selectedID == audio.defaultOutputDeviceID)
        check("right glyph is the static 3-arc speaker", model.rightGlyphSymbol == "speaker.wave.3.fill")

        // Sound Settings opens the right URL and asks to close.
        var openedURL: URL?
        var didClose = false
        model.openURLHandler = { openedURL = $0 }
        model.onRequestClose = { didClose = true }
        model.openSettings()
        check("Sound Settings opens the Sound pane URL",
              openedURL?.absoluteString == "x-apple.systempreferences:com.apple.Sound-Settings.extension")
        check("Sound Settings dismisses the popover", didClose)

        // Selecting another device switches the default output.
        let original = audio.defaultOutputDeviceID
        if let other = model.devices.first(where: { $0.id != original }) {
            model.onRequestClose = {}
            model.select(other.id)
            check("selecting a device switches default output", audio.defaultOutputDeviceID == other.id)
            if let originalDevice = audio.devices.first(where: { $0.id == original }) {
                audio.setDefaultDevice(originalDevice)
            }
        } else {
            skip("selecting a device switches default output", "needs 2+ devices")
        }

        // Volume stepping (1/10 grid).
        print("[stepping]")
        check("left speaker steps down by 1/10",
              PopoverModel.steppedVolume(current: 0.5, isLeftSpeaker: true) == 0.4)
        check("right speaker steps up by 1/10",
              PopoverModel.steppedVolume(current: 0.5, isLeftSpeaker: false) == 0.6)
        check("step clamps at max",
              PopoverModel.steppedVolume(current: 1, isLeftSpeaker: false) == 1)
        check("step clamps at min",
              PopoverModel.steppedVolume(current: 0, isLeftSpeaker: true) == 0)
        check("step snaps to the 1/10 grid",
              PopoverModel.steppedVolume(current: 0.47, isLeftSpeaker: false) == 6.0/10.0)

        if let soft = audio.devices.first(where: { audio.hasSettableVolume($0.id) }) {
            let prevDefault = audio.defaultOutputDeviceID
            let prevVol = audio.volume(soft.id) ?? 0.5
            audio.setDefaultDevice(soft)
            model.onRequestClose = {}
            model.reload()
            model.setVolume(0.5)
            model.step(isLeftSpeaker: false)
            check("stepping up raises volume", abs(model.volume - 0.6) < 0.001)
            model.step(isLeftSpeaker: true)
            check("stepping down lowers volume", abs(model.volume - 0.5) < 0.001)
            audio.setVolume(prevVol, for: soft.id)
            if let prev = audio.devices.first(where: { $0.id == prevDefault }) {
                audio.setDefaultDevice(prev)
            }
        } else {
            skip("stepping changes volume", "no software-controllable device")
        }

        // MARK: Audio + coordinator
        print("[audio]")
        check("enumerates at least one output device", !audio.devices.isEmpty)
        check("devices have names and icons",
              audio.devices.allSatisfy { !$0.name.isEmpty && !$0.iconSymbol.isEmpty })
        check("devices ordered by AudioDeviceID ascending",
              audio.devices.map { $0.id } == audio.devices.map { $0.id }.sorted())

        check("icon level: muted at 0", VolumeCoordinator.IconLevel.from(value: 0, muted: false) == .muted)
        check("icon level: muted flag wins", VolumeCoordinator.IconLevel.from(value: 0.5, muted: true) == .muted)
        check("icon level: low", VolumeCoordinator.IconLevel.from(value: 0.2, muted: false) == .low)
        check("icon level: mid", VolumeCoordinator.IconLevel.from(value: 0.5, muted: false) == .mid)
        check("icon level: high", VolumeCoordinator.IconLevel.from(value: 0.9, muted: false) == .high)

        // MARK: Speaker symbols (mute-at-zero)
        print("[icons]")
        check("status icon is mute slash when muted",
              IconSymbols.statusBar(muted: true) == "speaker.slash.fill")
        check("status icon is variable arcs when not muted",
              IconSymbols.statusBar(muted: false) == "speaker.wave.3.fill")
        check("status icon is headphones when output is headphones",
              IconSymbols.statusBar(muted: false, headphones: true) == "headphones")
        check("zero volume reads as muted",
              VolumeCoordinator.isMutedLook(value: 0, hardwareMuted: false))
        check("hardware mute reads as muted",
              VolumeCoordinator.isMutedLook(value: 0.5, hardwareMuted: true))
        check("normal volume is not muted",
              !VolumeCoordinator.isMutedLook(value: 0.5, hardwareMuted: false))

        // MARK: Hardware volume keys
        print("[hardware]")
        check("volume step is 1/16", abs(HardwareVolumeController.step - 1.0/16.0) < 0.0001)
        check("stepping up adds 1/16",
              abs(HardwareVolumeController.stepped(0.5, delta: HardwareVolumeController.step) - (0.5 + 1.0/16.0)) < 0.0001)
        check("stepping down subtracts 1/16",
              abs(HardwareVolumeController.stepped(0.5, delta: -HardwareVolumeController.step) - (0.5 - 1.0/16.0)) < 0.0001)
        check("step clamps at max", HardwareVolumeController.stepped(1, delta: HardwareVolumeController.step) == 1)
        check("step clamps at min", HardwareVolumeController.stepped(0, delta: -HardwareVolumeController.step) == 0)

        var bdRunning = BetterDisplayDetector()
        bdRunning.runningBundleIDs = { ["pro.betterdisplay.BetterDisplay", "com.apple.finder"] }
        check("detects BetterDisplay when running", bdRunning.isRunning)
        var bdAbsent = BetterDisplayDetector()
        bdAbsent.runningBundleIDs = { ["com.apple.finder", "com.apple.dock"] }
        check("BetterDisplay absent when not running", !bdAbsent.isRunning)

        // MARK: Popover placement + content sizing
        print("[placement]")
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let content = NSSize(width: 307, height: 232)
        let midIcon = NSRect(x: 600, y: 876, width: 24, height: 24)
        let oMid = PanelController.computeOrigin(buttonFrame: midIcon, contentSize: content, visibleFrame: visible)
        check("left-aligns to icon when there's room", abs(oMid.x - midIcon.minX) < 0.5)
        let rightIcon = NSRect(x: 1400, y: 876, width: 24, height: 24)
        let oRight = PanelController.computeOrigin(buttonFrame: rightIcon, contentSize: content, visibleFrame: visible)
        check("flips to right-align near the edge", abs((oRight.x + content.width) - rightIcon.maxX) < 0.5)

        let host = NSHostingView(rootView: SoundPopoverView(model: model))
        host.layoutSubtreeIfNeeded()
        check("popover content is 307pt wide", abs(host.fittingSize.width - 307) < 0.5)

        print("\nResult: \(passes) passed, \(failures) failed, \(skips) skipped")
        return failures
    }
}
