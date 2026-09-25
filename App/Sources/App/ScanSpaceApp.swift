import SwiftUI

@main
struct ScanSpaceApp: App {
    @State private var store = ScanStore()
    @State private var processing = ProcessingCenter()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(store)
                .environment(processing)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
    }
}
