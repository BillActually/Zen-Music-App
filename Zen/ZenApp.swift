import SwiftUI
import SwiftData

@main
struct ZenApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    handleWidgetDeepLink(url: url)
                }
        }
        // Database: include all models so schema is stable across updates.
        // Do not delete the app when updating — update in place to preserve playlists and library.
        .modelContainer(for: [Song.self, Playlist.self, Folder.self, SongArtwork.self, HistoryEntry.self, PlayRecord.self])
    }

    private func handleWidgetDeepLink(url: URL) {
        guard url.scheme == "zen" else { return }

        #if DEBUG
        print("Widget: Deep link received: \(url)")
        #endif

        // Get the action from the URL host
        let action = url.host ?? "open"

        #if DEBUG
        print("Widget: Action from URL: \(action)")
        #endif

        // Post notification to ContentView with the action
        // Use a small delay to ensure ContentView is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(
                name: NSNotification.Name("ZenWidgetAction"),
                object: nil,
                userInfo: ["action": action]
            )
        }
    }
}
