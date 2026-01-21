import SwiftUI
import SwiftData

@main
struct ZenApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // This line is the "Power Switch" for your database
        // It must include all three models: Song, Playlist, and Folder
        .modelContainer(for: [Song.self, Playlist.self, Folder.self])
    }
}
