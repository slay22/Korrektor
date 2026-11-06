import KorrektorCore
import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var accessibilityTrusted = AccessibilityAccess.isTrusted

    var body: some View {
        Form {
            Section("Global shortcut") {
                Toggle("Correct the selected text with a shortcut", isOn: $settings.hotkeyEnabled)

                LabeledContent("Shortcut") {
                    HotkeyRecorder(hotkey: $settings.hotkey)
                }
                .disabled(!settings.hotkeyEnabled)

                if settings.hotkeyEnabled, let problem = settings.hotkeyProblem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Picker("When the shortcut is pressed", selection: $settings.mode) {
                    ForEach(CorrectionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Fall back to ⌘C and ⌘V", isOn: $settings.clipboardFallback)
                Text("Some apps (Electron, some browsers) hide the selection from Accessibility. With this on, Korrektor copies and pastes instead — which only happens inside a text area, never in a password field, and your clipboard is put back afterwards. Off by default: the fallback can act on more than what you selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack(spacing: 8) {
                        Text(accessibilityStatusText)
                            .foregroundStyle(accessibilityStatusColor)
                        Button("Open System Settings") {
                            AccessibilityAccess.request()
                            AccessibilityAccess.openSystemSettings()
                        }
                    }
                }

                Text(accessibilityExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("macOS ties this permission to the exact build of the app. After a rebuild the switch in System Settings can look on while the new build is denied — switch it off and on again, or run “tccutil reset Accessibility de.arte.korrektor” and grant it once more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            // The permission changes behind our back while System Settings is
            // open, so keep the label honest instead of showing a stale value.
            while !Task.isCancelled {
                accessibilityTrusted = AccessibilityAccess.isTrusted
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        .onChange(of: settings.mode) { _, _ in
            accessibilityTrusted = AccessibilityAccess.isTrusted
        }
    }

    /// Only report a missing grant as a problem when the chosen mode needs one.
    private var accessibilityStatusText: String {
        guard settings.mode.needsAccessibility else { return "Not needed for this mode" }
        return accessibilityTrusted ? "Granted" : "Not granted"
    }

    private var accessibilityStatusColor: Color {
        guard settings.mode.needsAccessibility else { return .secondary }
        return accessibilityTrusted ? .green : .orange
    }

    private var accessibilityExplanation: String {
        settings.mode.needsAccessibility
            ? "“\(settings.mode.label)” reads and replaces text in other apps, so macOS has to allow Korrektor under Privacy & Security → Accessibility."
            : "“\(settings.mode.label)” needs no Accessibility access: the clipboard carries the text in and out. The switch in System Settings can stay off."
    }
}
