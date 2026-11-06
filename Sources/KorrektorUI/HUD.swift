import AppKit
import SwiftUI

/// Small floating confirmation near the top of the screen, so a shortcut press
/// gives an answer even though the app is in the background.
@MainActor
final class HUD {
    static let shared = HUD()

    enum Style {
        case working, success, failure
    }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, style: Style = .success) {
        hideTask?.cancel()

        let hosting = NSHostingView(rootView: HUDContent(message: message, style: style))
        hosting.frame.size = hosting.fittingSize

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting

        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(
                NSRect(
                    x: visible.midX - size.width / 2,
                    y: visible.maxY - size.height - 24,
                    width: size.width,
                    height: size.height
                ),
                display: true
            )
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        if style == .working { return }

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in self.panel?.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        return panel
    }
}

private struct HUDContent: View {
    let message: String
    let style: HUD.Style

    var body: some View {
        HStack(spacing: 8) {
            switch style {
            case .working:
                ProgressView()
                    .controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Text(message)
                .font(.callout.weight(.medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .fixedSize()
    }
}
