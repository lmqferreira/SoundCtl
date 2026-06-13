import AppKit
import CoreAudio

/// Lightweight in-module test suite (the Command Line Tools ship no XCTest /
/// Testing framework). Run via `SoundCtl --self-test`; exits non-zero if any
/// check fails. Covers the regressions we have hit: device-row clicks,
/// Sound-Settings clicks, popover placement, and core audio behaviour.
public enum SelfTests {

    /// Runs all checks, prints a report, and returns the number of failures.
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

        // MARK: Popover placement (right-of-icon by default; flip near the edge)
        print("[placement]")
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let content = NSSize(width: 307, height: 232)

        // Icon with room to the right -> popover left-aligns to the icon.
        let midIcon = NSRect(x: 600, y: 876, width: 24, height: 24)
        let oMid = PanelController.computeOrigin(buttonFrame: midIcon,
                                                 contentSize: content, visibleFrame: visible)
        check("left-aligns to icon when there's room (extends right)",
              abs(oMid.x - midIcon.minX) < 0.5)
        check("drops below the icon", abs(oMid.y - (midIcon.minY - 6 - content.height)) < 0.5)

        // Icon near the right edge -> flip so the popover extends left.
        let rightIcon = NSRect(x: 1400, y: 876, width: 24, height: 24) // maxX = 1424
        let oRight = PanelController.computeOrigin(buttonFrame: rightIcon,
                                                   contentSize: content, visibleFrame: visible)
        check("flips to right-align near the right edge (extends left)",
              abs((oRight.x + content.width) - rightIcon.maxX) < 0.5)
        check("stays on-screen at the right edge",
              oRight.x + content.width <= visible.maxX - 8 + 0.001)

        // MARK: Click handling (device switch + settings regressions)
        print("[clicks]")
        let row = OutputDeviceRow(deviceID: 42, symbol: "speaker.fill", name: "Test", selected: false)
        row.frame = NSRect(x: 0, y: 0, width: 307, height: 32)
        row.layoutSubtreeIfNeeded()
        var rowFired = false
        row.onClick = { rowFired = true }
        row.handleMouseUp(atLocalPoint: NSPoint(x: row.bounds.midX, y: row.bounds.midY))
        check("device row click inside fires onClick", rowFired)

        var rowFiredOutside = false
        row.onClick = { rowFiredOutside = true }
        row.handleMouseUp(atLocalPoint: NSPoint(x: 5000, y: 5000))
        check("device row click outside is ignored", !rowFiredOutside)

        let settings = TextHoverRow(title: "Sound Settings…", action: {})
        settings.frame = NSRect(x: 0, y: 0, width: 307, height: 32)
        settings.layoutSubtreeIfNeeded()
        var settingsFired = false
        let settings2 = TextHoverRow(title: "Sound Settings…") { settingsFired = true }
        settings2.frame = NSRect(x: 0, y: 0, width: 307, height: 32)
        settings2.layoutSubtreeIfNeeded()
        settings2.handleMouseUp(atLocalPoint: NSPoint(x: settings2.bounds.midX, y: settings2.bounds.midY))
        check("Sound Settings row click fires action", settingsFired)

        // MARK: View controller integration
        print("[popover]")
        let audio = AudioController()
        let coordinator = VolumeCoordinator(audio: audio, ddc: DDCController())
        let vc = SoundPopoverViewController(audio: audio, coordinator: coordinator)
        _ = vc.view
        vc.rebind()
        vc.view.frame = NSRect(origin: .zero, size: vc.view.fittingSize)
        vc.view.layoutSubtreeIfNeeded()

        check("popover width is 307pt", abs(vc.view.fittingSize.width - 307) < 0.5)
        let rows = vc.devicesStack.arrangedSubviews.compactMap { $0 as? OutputDeviceRow }
        check("renders one row per output device", rows.count == audio.devices.count)
        check("variable speaker glyph is set", vc.rightGlyph.image != nil)

        // Typography / colour (must match native).
        check("title is 13pt bold", vc.titleLabel.font?.pointSize == 13
              && vc.titleLabel.font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        check("title uses label colour", vc.titleLabel.textColor == .labelColor)
        check("Output header is 11pt bold", vc.outputHeader.font?.pointSize == 11
              && vc.outputHeader.font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        check("Output header uses label colour (not grey)", vc.outputHeader.textColor == .labelColor)

        // Sound Settings opens the right URL and asks to close.
        var openedURL: URL?
        var didClose = false
        vc.openURLHandler = { openedURL = $0 }
        vc.onRequestClose = { didClose = true }
        let sr = vc.settingsRow!
        sr.handleMouseUp(atLocalPoint: NSPoint(x: sr.bounds.midX, y: sr.bounds.midY))
        check("Sound Settings opens the Sound pane URL",
              openedURL?.absoluteString == "x-apple.systempreferences:com.apple.Sound-Settings.extension")
        check("Sound Settings dismisses the panel", didClose)

        // Clicking an alternate device row switches the default output.
        let original = audio.defaultOutputDeviceID
        if let targetRow = rows.first(where: { $0.deviceID != original }) {
            targetRow.handleMouseUp(atLocalPoint: NSPoint(x: targetRow.bounds.midX, y: targetRow.bounds.midY))
            check("clicking a device row switches default output",
                  audio.defaultOutputDeviceID == targetRow.deviceID)
            if let originalDevice = audio.devices.first(where: { $0.id == original }) {
                audio.setDefaultDevice(originalDevice)
            }
        } else {
            skip("clicking a device row switches default output", "needs 2+ devices")
        }

        // Clicking the speaker glyphs nudges the volume by one step (1/10).
        check("left speaker steps down by 1/10",
              SoundPopoverViewController.steppedVolume(current: 0.5, isLeftSpeaker: true) == 0.4)
        check("right speaker steps up by 1/10",
              SoundPopoverViewController.steppedVolume(current: 0.5, isLeftSpeaker: false) == 0.6)
        check("step clamps at max",
              SoundPopoverViewController.steppedVolume(current: 1, isLeftSpeaker: false) == 1)
        check("step clamps at min",
              SoundPopoverViewController.steppedVolume(current: 0, isLeftSpeaker: true) == 0)
        check("step snaps to the 1/10 grid",
              SoundPopoverViewController.steppedVolume(current: 0.47, isLeftSpeaker: false) == 6.0/10.0)

        if let soft = audio.devices.first(where: { audio.hasSettableVolume($0.id) }) {
            let prevDefault = audio.defaultOutputDeviceID
            let prevVol = audio.volume(soft.id) ?? 0.5
            audio.setDefaultDevice(soft)
            vc.rebind()
            vc.slider.value = 0.5

            vc.handleSpeakerGlyphClick(isLeftSpeaker: false)
            check("clicking right speaker steps volume up", abs(vc.slider.value - 0.6) < 0.001)

            vc.handleSpeakerGlyphClick(isLeftSpeaker: true)
            check("clicking left speaker steps volume down", abs(vc.slider.value - 0.5) < 0.001)

            // Restore previous state.
            audio.setVolume(prevVol, for: soft.id)
            if let prev = audio.devices.first(where: { $0.id == prevDefault }) {
                audio.setDefaultDevice(prev)
            }
        } else {
            skip("speaker glyph click changes volume", "no software-controllable device")
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
        check("left glyph is mute slash when muted",
              IconSymbols.leftFlank(muted: true) == "speaker.slash.fill")
        check("left glyph is plain speaker when not muted",
              IconSymbols.leftFlank(muted: false) == "speaker.fill")
        // Regression: zero volume must read as muted even without the hardware
        // mute flag, so the slash persists after releasing the slider at 0.
        check("zero volume reads as muted",
              VolumeCoordinator.isMutedLook(value: 0, hardwareMuted: false))
        check("hardware mute reads as muted",
              VolumeCoordinator.isMutedLook(value: 0.5, hardwareMuted: true))
        check("normal volume is not muted",
              !VolumeCoordinator.isMutedLook(value: 0.5, hardwareMuted: false))

        // MARK: Status-item highlight persists while the panel is open
        print("[highlight]")
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let panel = PanelController(viewController: vc)
            var visibility: [Bool] = []
            panel.onVisibilityChanged = { shown in
                button.highlight(shown)
                visibility.append(shown)
            }
            panel.show(relativeTo: button)
            check("panel reports shown + highlights icon", button.isHighlighted && visibility.last == true)
            panel.close()
            check("panel reports hidden on close", visibility.last == false)
        } else {
            skip("status item highlight", "no status button")
        }
        NSStatusBar.system.removeStatusItem(statusItem)

        // MARK: Frosted material with rounded corners (vibrancy preserved)
        print("[material]")
        check("content root is a visual-effect view", vc.view is NSVisualEffectView)
        if let effect = vc.view as? NSVisualEffectView {
            check("uses the popover material", effect.material == .popover)
            check("blends behind window (vibrant)", effect.blendingMode == .behindWindow)
            check("rounds corners via cornerRadius, no opaque maskImage (keeps vibrancy)",
                  effect.layer?.cornerRadius == 13 && effect.maskImage == nil)
        }

        print("\nResult: \(passes) passed, \(failures) failed, \(skips) skipped")
        return failures
    }
}
