import SwiftUI

@main
struct CodMateApp: App {
    @StateObject private var listViewModel: SessionListViewModel

    init() {
        let preferences = SessionPreferencesStore()
        _listViewModel = StateObject(wrappedValue: SessionListViewModel(preferences: preferences))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: listViewModel)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1200, height: 780)
    }
}
