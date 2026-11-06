import AppKit
import KorrektorCore
import SwiftUI

@main
struct Korrektor: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A plain Window, not a WindowGroup: one window, no "New Window", and
        // the shortcut always fills the window the user already knows.
        Window("Korrektor", id: "main") {
            ContentView()
                .frame(minWidth: 640, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 660)

        Settings {
            SettingsView()
        }

        MenuBarExtra("Korrektor", systemImage: "checkmark.circle") {
            MenuBarContent()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.start()
        NSApp.activate()
    }

    /// Closing the window must not stop the shortcut from working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @State private var settings = AppSettings.shared

    var body: some View {
        Text(settings.hotkeyEnabled
             ? "Shortcut: \(settings.hotkey.displayString)"
             : "Shortcut: off")
            .font(.callout)

        if settings.hotkeyEnabled, let problem = settings.hotkeyProblem {
            Text(problem)
                .font(.callout)
                .foregroundStyle(.orange)
        }

        if settings.hotkeyEnabled, !AccessibilityAccess.isTrusted {
            Text("Accessibility access missing")
                .font(.callout)
                .foregroundStyle(.orange)
        }

        Divider()

        Button("Correct selection now") {
            AppController.shared.correctSelection()
        }

        Button("Open Korrektor") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Korrektor") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
