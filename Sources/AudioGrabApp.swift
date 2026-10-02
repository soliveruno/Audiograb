import SwiftUI

@main
struct AudioGrabApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                LibraryView()
                    .tabItem { Label("Library", systemImage: "music.note.list") }
                ConvertView()
                    .tabItem { Label("Convert", systemImage: "film") }
            }
            .preferredColorScheme(.dark)
            .tint(.orange)
        }
    }
}
