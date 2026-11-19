// SwiftUI pieces: the "Now" card at the top of the dropdown and the 1-minute reminder card.

import AppKit
import SwiftUI

let accentBlue = Color(red: 0x4f / 255, green: 0x8c / 255, blue: 0xf7 / 255)
let nowRed = Color(red: 1, green: 0x5f / 255, blue: 0x57 / 255)

/// Lets a click land on a button even when the window isn't focused.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NowCard: View {
    let title: String
    let until: String        // "12:30"
    let progress: Double     // 0...1
    let timeLeft: String     // "25 min left"
    let joinLabel: String?   // "Join Google Meet", nil when there is no link
    let onJoin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(nowRed).frame(width: 6, height: 6)
                Text("NOW · UNTIL \(until)")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(accentBlue)
                            .frame(width: max(4, geo.size.width * min(max(progress, 0), 1)))
                    }
                }
                .frame(height: 4)
                Text(timeLeft)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let joinLabel {
                JoinButton(label: joinLabel, action: onJoin)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: 340, alignment: .leading)
    }
}

/// A quiet tinted button: soft blue fill, blue label, the shortcut as a small keycap.
struct JoinButton: View {
    let label: String
    let action: () -> Void
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let text = scheme == .dark ? Color(red: 0.62, green: 0.76, blue: 1.0) : accentBlue
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "video.fill").font(.system(size: 11, weight: .medium))
                Text(label).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Text("⌘J")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 5)
                    .frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(text.opacity(0.14)))
            }
            .foregroundStyle(text)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accentBlue.opacity(hover ? 0.26 : 0.17))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

struct ReminderCard: View {
    let title: String
    let subtitle: String
    let canJoin: Bool
    let onJoin: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if canJoin {
                Button(action: onJoin) {
                    Text("Join")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accentBlue))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(width: 360)
    }
}

/// A borderless glass panel that holds one reminder card under the menu bar.
final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { false }

    init(content: ReminderCard) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        setContent(content)
    }

    func setContent(_ content: ReminderCard) {
        let host = ClickThroughHostingView(rootView: content)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let glass = NSVisualEffectView(frame: host.frame)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.addSubview(host)
        contentView = glass
        setContentSize(size)
    }
}

/// Renders a SwiftUI view to a PNG, for checking the design without a screenshot.
@MainActor
func renderPNG<V: View>(_ view: V, dark: Bool, background: Color, to path: String) {
    let wrapped = view
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(20)
        .environment(\.colorScheme, dark ? .dark : .light)
    let renderer = ImageRenderer(content: wrapped)
    renderer.scale = 2
    guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}
