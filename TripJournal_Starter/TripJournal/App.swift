import SwiftUI

@main
struct TripJournalApp: App {
    var body: some Scene {
        WindowGroup {
            // ⚠️ TESTING MODE: Using LiveJournalService for auth testing
            // Trip/Event/Media endpoints NOT implemented yet - will crash if used!
            RootView(service: LiveJournalService())
        }
    }
}
