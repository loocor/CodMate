import SwiftUI

#if os(macOS)
    import AppKit
#endif

@main
struct CodMateApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @StateObject private var listViewModel: SessionListViewModel
    @StateObject private var preferences: SessionPreferencesStore
    @State private var settingsSelection: SettingCategory = .general
    @Environment(\.openWindow) private var openWindow

    init() {
        let prefs = SessionPreferencesStore()
        _preferences = StateObject(wrappedValue: prefs)
        _listViewModel = StateObject(wrappedValue: SessionListViewModel(preferences: prefs))
        // Prepare user notifications early so banners can show while app is active
        SystemNotifier.shared.bootstrap()
        // In App Sandbox, restore security-scoped access to user-selected directories
        SecurityScopedBookmarks.shared.restoreAndStartAccess()
        // Restore all dynamic bookmarks (e.g., repository directories for Git Review)
        SecurityScopedBookmarks.shared.restoreAllDynamicBookmarks()
        // Restore and check sandbox permissions for critical directories
        Task { @MainActor in
            SandboxPermissionsManager.shared.restoreAccess()
        }
    }

    var bodyCommands: some Commands {
        Group {
            CommandGroup(replacing: .appInfo) {
                Button("About CodMate") { presentSettings(for: .about) }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { presentSettings(for: .general) }
                    .keyboardShortcut(",", modifiers: [.command])
            }
            // Integrate actions into the system View menu
            CommandGroup(after: .sidebar) {
                Button("Refresh Sessions") {
                    Task { await listViewModel.refreshSessions(force: true) }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .codMateToggleSidebar, object: nil)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Toggle Session List") {
                    NotificationCenter.default.post(name: .codMateToggleList, object: nil)
                }
                .keyboardShortcut("2", modifiers: [.command])
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: listViewModel)
                .frame(minWidth: 880, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 780)
        .commands { bodyCommands }
        WindowGroup("Settings", id: "settings") {
            SettingsWindowContainer(
                preferences: preferences,
                listViewModel: listViewModel,
                selection: $settingsSelection
            )
        }
        .defaultSize(width: 800, height: 640)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.automatic)
        .windowResizability(.contentMinSize)
    }

    private func presentSettings(for category: SettingCategory) {
        settingsSelection = category
        #if os(macOS)
            NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
        openWindow(id: "settings")
    }
}

private struct SettingsWindowContainer: View {
    let preferences: SessionPreferencesStore
    let listViewModel: SessionListViewModel
    @Binding var selection: SettingCategory

    var body: some View {
        SettingsView(preferences: preferences, selection: $selection)
            .environmentObject(listViewModel)
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        #if canImport(SwiftTerm) && !APPSTORE
            // Synchronously stop all terminal sessions to ensure clean exit
            // This prevents orphaned codex/claude processes when app quits
            let manager = TerminalSessionManager.shared

            // Use sync mode to block until all processes are killed
            // This ensures no orphaned processes when app terminates
            manager.stopAll(withPrefix: "", sync: true)

            // No sleep needed - sync mode blocks until processes are dead
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if canImport(SwiftTerm) && !APPSTORE
            // Check if there are any running terminal sessions
            let manager = TerminalSessionManager.shared
            if manager.hasAnyRunningProcesses() {
                // Show confirmation dialog
                let alert = NSAlert()
                alert.messageText = "Stop Running Sessions?"
                alert.informativeText = "There are Codex/Claude Code sessions still running. Quitting now will terminate them."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Cancel")

                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    return .terminateCancel
                }
            }
        #endif
        return .terminateNow
    }
}
#endif
