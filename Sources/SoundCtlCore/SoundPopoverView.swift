import SwiftUI
import CoreAudio

/// SwiftUI replica of the macOS 26 Sound popover body. Hosted in a transparent
/// child window layered over an NSGlassEffectView window (see PanelController),
/// so the native Slider knob renders clean (no Liquid-Glass border) while the
/// real glass shows through behind it.
struct SoundPopoverView: View {

    @ObservedObject var model: PopoverModel

    static let contentWidth: CGFloat = 307

    /// Measured flanking-speaker colour from the native popover.
    private let flankColor = Color(.sRGB, red: 0x38 / 255.0, green: 0x40 / 255.0, blue: 0x57 / 255.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sound")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.leading, 14)
                .padding(.top, 10)
                .padding(.bottom, 7)

            volumeRow

            Divider().padding(.horizontal, 13).padding(.top, 7)

            Text("Output")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.leading, 14)
                .padding(.top, 7)
                .padding(.bottom, 3)

            ForEach(model.devices) { device in
                DeviceRowView(item: device, selected: device.id == model.selectedID)
                    .onTapGesture { model.select(device.id) }
            }

            Divider().padding(.horizontal, 13).padding(.top, 4)

            SettingsRowView { model.openSettings() }
                .padding(.top, 4)
                .padding(.bottom, 1)
        }
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    private var volumeRow: some View {
        HStack(spacing: 6) {
            Image(systemName: model.leftGlyphSymbol)
                .font(.system(size: 15))
                .frame(width: 20)
                .contentShape(Rectangle())
                .onTapGesture { model.step(isLeftSpeaker: true) }

            Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }),
                   in: 0...1,
                   onEditingChanged: { editing in
                       if editing { model.beginAdjust() } else { model.endAdjust() }
                   })
                .controlSize(.small)
                .disabled(!model.enabled)

            Image(systemName: model.rightGlyphSymbol)
                .font(.system(size: 15))
                .frame(width: 24)
                .contentShape(Rectangle())
                .onTapGesture { model.step(isLeftSpeaker: false) }
        }
        .foregroundStyle(flankColor)
        .frame(height: 24)
        .padding(.horizontal, 14)
    }
}

/// One Output row: circular device glyph (accent-filled + white glyph when
/// selected, grey otherwise) + name, with the native translucent hover pill.
struct DeviceRowView: View {
    let item: PopoverModel.DeviceItem
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(selected ? AnyShapeStyle(Color.accentColor)
                                   : AnyShapeStyle(Color(white: 0.5, opacity: 0.25)))
                    .frame(width: 26, height: 26)
                Image(systemName: item.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? .white : .primary)
            }
            Text(item.name)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 32)
        .background(hoverPill(hover))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// Full-width "Sound Settings…" row with the native hover pill.
struct SettingsRowView: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack {
            Text("Sound Settings…")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 22)
        .background(hoverPill(hover))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
    }
}

/// The native translucent rounded hover highlight (inset from the row edges).
private func hoverPill(_ hover: Bool) -> some View {
    RoundedRectangle(cornerRadius: 6)
        .fill(Color(white: 0.5, opacity: hover ? 0.22 : 0))
        .padding(.horizontal, 6)
}
