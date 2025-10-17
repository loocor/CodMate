import SwiftUI

@main
struct CodMateApp: App {
    @StateObject private var listViewModel: SessionListViewModel
    @StateObject private var preferences: SessionPreferencesStore

    init() {
        let prefs = SessionPreferencesStore()
        _preferences = StateObject(wrappedValue: prefs)
        _listViewModel = StateObject(wrappedValue: SessionListViewModel(preferences: prefs))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: listViewModel)
                .frame(minWidth: 880, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 780)

        Settings {
            SettingsView(preferences: preferences)
        }
    }
}
