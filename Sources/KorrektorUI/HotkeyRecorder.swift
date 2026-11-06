import AppKit
import KorrektorCore
import SwiftUI

/// Owns the event monitor and the app-level side effects around recording.
/// The decision of *what* a key press means lives in `HotkeyRecordingSession`,
/// where it can be tested.
@MainActor
@Observable
final class HotkeyRecorderModel {
    private(set) var isRecording = false
    private(set) var hint: String?

    /// Held in a box so `deinit` can still remove the monitor.
    @ObservationIgnored private let monitorBox = EventMonitorBox()
    private var session: HotkeyRecordingSession?
    private var activationObservers: [NSObjectProtocol] = []

    private static let modifierHint = "Hold ⌘, ⌃ or ⌥ as well — a bare key would intercept your typing."
    private static let focusHint = "Korrektor is not the frontmost app — the keys go elsewhere."

    func start(onCapture: @escaping (Hotkey) -> Void) {
        guard !isRecording else { return }

        session = HotkeyRecordingSession(onCapture: onCapture)
        isRecording = true
        hint = NSApp.isActive ? nil : Self.focusHint

        // Carbon swallows the combination that is currently registered, so it
        // could never be recorded again — and no action should fire half way
        // through recording a new one.
        AppController.shared.suspendHotkey()
        observeActivation()

        monitorBox.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isRecording, let session = self.session else { return event }

            let captured = session.handle(event)

            if !session.isActive {
                // Recorded (the session already handed it on) or cancelled.
                self.stop(captured: captured != nil)
            } else {
                self.hint = Self.modifierHint
            }
            return nil
        }
    }

    func stop(captured: Bool = false) {
        if let monitor = monitorBox.monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitorBox.monitor = nil
        session?.cancel()
        session = nil
        stopObservingActivation()
        isRecording = false
        if !captured { hint = nil }
        AppController.shared.resumeHotkey()
    }

    /// The focus moves on its own on this Mac (another tool follows the user's
    /// head), so say so instead of waiting silently for keys that never arrive.
    private func observeActivation() {
        let center = NotificationCenter.default
        activationObservers.append(
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRecording else { return }
                    self.hint = Self.focusHint
                }
            }
        )
        activationObservers.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRecording else { return }
                    self.hint = nil
                }
            }
        )
    }

    private func stopObservingActivation() {
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activationObservers = []
    }

    deinit {
        if let monitor = monitorBox.monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

/// A non-isolated holder for the event monitor, so cleanup does not need the
/// main actor.
private final class EventMonitorBox: @unchecked Sendable {
    var monitor: Any?
}

struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var recorder = HotkeyRecorderModel()

    var body: some View {
        HStack(spacing: 8) {
            Text(recorder.isRecording ? "press keys…" : hotkey.displayString)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(recorder.isRecording ? .secondary : .primary)
                .frame(minWidth: 74)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                )

            if recorder.isRecording {
                Button("Cancel") { recorder.stop() }
            } else {
                Button("Change") {
                    recorder.start { captured in hotkey = captured }
                }
            }
        }
        .onDisappear {
            // Closing the pane mid-recording must not leave the shortcut
            // suspended and silently unregistered.
            recorder.stop()
        }
        .overlay(alignment: .bottomLeading) {
            if let hint = recorder.hint, recorder.isRecording {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .offset(y: 20)
            }
        }
    }
}
