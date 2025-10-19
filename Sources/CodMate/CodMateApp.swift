import SwiftUI

#if os(macOS)
    import AppKit
#endif

@main
struct CodMateApp: App {
    @StateObject private var listViewModel: SessionListViewModel
    @StateObject private var preferences: SessionPreferencesStore
    @State private var settingsSelection: SettingCategory = .general
    @Environment(\.openSettings) private var openSettings

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
                Button("About CodMate") {
                    presentSettings(for: .about)
                }
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

        Settings {
            SettingsView(preferences: preferences, selection: $settingsSelection)
                .environmentObject(listViewModel)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }

    private func presentSettings(for category: SettingCategory) {
        settingsSelection = category
        #if os(macOS)
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
        #endif
    }
}
