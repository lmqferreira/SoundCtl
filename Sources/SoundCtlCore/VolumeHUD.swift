import AppKit
import SwiftUI

/// Observable state for the volume HUD.
final class HUDModel: ObservableObject {
    @Published var level: Double = 0     // 0...1
    @Published var muted: Bool = false
}

/// A compact, native-style volume overlay: a speaker glyph whose waves track the
/// level, plus a 16-segment bar, on the Liquid Glass material.
struct VolumeHUDView: View {
    @ObservedObject var model: HUDModel
    private let segments = 16

    // Explicit (non-vibrant) colours — a semantic `.primary` shape fill gets
    // desaturated by the glass material, so use opaque white/black per appearance.
    private let filledColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    })
    private let emptyColor = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.22)
    })

    private var filled: Int {
        model.muted ? 0 : Int((model.level * Double(segments)).rounded())
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                  variableValue: model.muted ? 0 : model.level)
                .font(.system(size: 24))
                .foregroundStyle(.primary)
                .frame(width: 30, alignment: .center)

            HStack(spacing: 3) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < filled ? filledColor : emptyColor)
                        .frame(width: 9, height: 12)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .noFocusEffect()
    }
}

/// Borderless, click-through glass panel that shows `VolumeHUDView` near the
/// bottom-centre of the active screen and fades out after a short delay.
final class VolumeHUD {

    private let panel: NSPanel
    private let model = HUDModel()
    private var hideWork: DispatchWorkItem?

    init() {
        let hosting = NSHostingView(rootView: VolumeHUDView(model: model))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.contentView = hosting
            backdrop = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 18
            hosting.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            backdrop = effect
        }

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.alphaValue = 0
        panel.contentView = backdrop
    }

    /// Show the HUD with the given level/mute and (re)start the auto-hide timer.
    func show(level: Float, muted: Bool) {
        model.level = Double(max(0, min(1, level)))
        model.muted = muted

        let size = panel.frame.size
        let screen = (NSScreen.main ?? NSScreen.screens.first)
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.minY + 140)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }
    }
}
