import SwiftUI

#if os(macOS)
    import AppKit
#endif

@main
struct CodMateApp: App {
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
            CommandMenu("CodMate") {
                Button("Refresh Sessions") {
                    Task { await listViewModel.refreshSessions(force: true) }
                }
                .keyboardShortcut("r", modifiers: [.command])
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
