import SwiftUI
import SwiftData
import AVFoundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject var playerManager = PlayerManager()
    @StateObject private var serverManager = TelegraphServerManager()
    @Query(sort: \Song.title) private var allSongs: [Song]
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    
    @State private var isPlayerExpanded = false
    @State private var selectedTab = 0 // 0: Library, 1: Artists, 2: Albums, 3: Playlists
    @State private var searchQuery: String = ""
    @State private var isSyncing = false
    @State private var syncProgress: Double = 0.0
    @State private var syncTotal: Int = 0
    @State private var currentlySyncingName: String = ""
    @State private var songToDelete: Song? = nil
    @State private var artistToNavigate: String? = nil
    @State private var albumToNavigate: String? = nil
    @State private var showSettings = false
    @State private var hasFixedStaleSongURLsThisLaunch = false
    @State private var keyboardHeight: CGFloat = 0

    // Timer to check for widget actions while app is active
    private let widgetActionTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    // MARK: - Widget Deep Link Handling
    private func checkForPendingWidgetAction() {
        guard let sharedDefaults = UserDefaults(suiteName: "group.com.williambarrios.zen") else {
            #if DEBUG
            print("Widget: Failed to access shared UserDefaults")
            #endif
            return
        }
        if let action = sharedDefaults.string(forKey: "widgetAction"),
           let timestamp = sharedDefaults.object(forKey: "widgetActionTimestamp") as? TimeInterval {
            let now = Date().timeIntervalSince1970
            if now - timestamp < 10.0 { // Process actions from last 10 seconds
                #if DEBUG
                print("Widget: Found pending action '\(action)' from \(now - timestamp) seconds ago")
                #endif
                // Clear the action
                sharedDefaults.removeObject(forKey: "widgetAction")
                sharedDefaults.removeObject(forKey: "widgetActionTimestamp")

                // Handle the action immediately
                handleWidgetAction(action)
            } else {
                #if DEBUG
                print("Widget: Action '\(action)' is too old (\(now - timestamp) seconds)")
                #endif
            }
        } else {
            #if DEBUG
            print("Widget: No pending action found")
            #endif
        }
    }
    
    private func handleWidgetAction(_ action: String) {
        #if DEBUG
        print("Widget: Handling action '\(action)'")
        #endif
        switch action {
        case "toggle":
            #if DEBUG
            print("Widget: Calling togglePauseOrStartRandom with \(allSongs.count) songs")
            #endif
            playerManager.togglePauseOrStartRandom(allSongs: allSongs)
        case "next":
            playerManager.nextTrack()
        case "previous":
            playerManager.previousTrack()
        default:
            #if DEBUG
            print("Widget: Unknown action '\(action)'")
            #endif
            break
        }
    }
    
    /// After an app update the container path can change; stored song URLs may point to the old path.
    /// Fix any song whose file isn't at the stored path by resolving from the current Documents directory.
    /// Run once per launch so playback works without the user having to hit Refresh.
    private func fixStaleSongURLsIfNeeded() {
        let fileManager = FileManager.default
        guard let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        var didFixAny = false
        for song in allSongs {
            let path = song.url.path
            if fileManager.fileExists(atPath: path) { continue }
            
            let filename = song.url.lastPathComponent
            let resolvedPath = docsURL.appendingPathComponent(filename).path
            if fileManager.fileExists(atPath: resolvedPath) {
                song.url = URL(fileURLWithPath: resolvedPath)
                didFixAny = true
            }
        }
        if didFixAny {
            try? modelContext.save()
        }
    }
    
    // MARK: - Delete Song Function
    func confirmDelete(_ song: Song) {
        songToDelete = song
    }
    
    func deleteSong(_ song: Song) {
        // 1. Stop playback if this is the current song
        if playerManager.currentSong?.id == song.id {
            if playerManager.isPlaying {
                playerManager.togglePause()
            }
            playerManager.currentSong = nil
        }
        
        // 2. Remove from queues if present
        playerManager.manualQueue.removeAll { $0.id == song.id }
        playerManager.queue.removeAll { $0.id == song.id }
        
        // 3. Delete the file from filesystem
        let fileManager = FileManager.default
        let fileURL = song.url
        
        // Start accessing security-scoped resource if needed
        let accessGranted = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        // Check if file exists before trying to delete
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.removeItem(at: fileURL)
                #if DEBUG
                print("Successfully deleted file: \(fileURL.lastPathComponent)")
                #endif
            } catch {
                #if DEBUG
                print("Error deleting file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                #endif
                // Continue with database deletion even if file delete fails
                // (file might have been moved/deleted externally)
            }
        } else {
            #if DEBUG
            print("File does not exist at path: \(fileURL.path), removing from database only")
            #endif
        }
        
        // 4. Remove from all playlists (SwiftData relationship will handle this automatically)
        // But we should also explicitly remove it to be safe
        if let playlists = song.playlists {
            for playlist in playlists {
                playlist.songs?.removeAll { $0.id == song.id }
                removeSongFromPlaylistOrder(playlist: playlist, song: song)
            }
        }
        
        // 5. Record history then delete from SwiftData
        recordHistory(context: modelContext, action: "deleted_from_library", songTitle: song.title, songArtist: song.artist)
        modelContext.delete(song)
        
        // 6. Save the context
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("Error saving after delete: \(error.localizedDescription)")
            #endif
        }
    }
    
    // Helper function to pass to child views
    func deleteSongHandler(_ song: Song) {
        deleteSong(song)
    }

    private func syncLocalFiles() {
        // Set initial state on main thread
        Task { @MainActor in
            isSyncing = true
            syncProgress = 0
            syncTotal = 0
            currentlySyncingName = "Checking for new music..."
        }

        Task(priority: .userInitiated) {
            // Use standardized URLs for reliable comparison
            // Note: @Query already loads songs, but accessing it here avoids blocking UI
            let existingURLs = await MainActor.run {
                Set(allSongs.map { $0.url.standardized })
            }
            // 1. THE SAFETY SWITCH:
            // No matter how this task finishes, dismiss the overlay.
            defer {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000) // Brief delay before closing
                    withAnimation(.spring()) {
                        self.isSyncing = false
                    }
                }
            }

            let fileManager = FileManager.default
            guard let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                await MainActor.run {
                    self.currentlySyncingName = "Error: Could not access documents"
                }
                return
            }

            // Recursively scan for audio files with progress updates
            await MainActor.run {
                self.currentlySyncingName = "Scanning for music files..."
                self.syncTotal = 0 // Show we're scanning
            }
            
            let supported = ["mp3", "m4a", "wav", "flac", "aac", "m4p"]
            var audioURLs: [URL] = []
            
            // Recursively find all audio files
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
            let enumerator = fileManager.enumerator(
                at: docsURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles],
                errorHandler: { url, error -> Bool in
                    #if DEBUG
                    print("Error accessing \(url): \(error.localizedDescription)")
                    #endif
                    return true // Continue on error
                }
            )
            
            var fileCount = 0
            while let fileURL = enumerator?.nextObject() as? URL {
                fileCount += 1
                
                // Yield every 50 files (more frequent) to prevent blocking and update UI
                if fileCount % 50 == 0 {
                    await Task.yield()
                    await MainActor.run {
                        self.currentlySyncingName = "Scanning... (\(fileCount) files checked)"
                    }
                }
                
                let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
                let isDirectory = resourceValues?.isDirectory ?? false
                
                if !isDirectory {
                    let ext = fileURL.pathExtension.lowercased()
                    if supported.contains(ext) {
                        audioURLs.append(fileURL)
                    }
                }
            }
            
            // Update UI with scan results immediately
            await MainActor.run {
                if audioURLs.isEmpty {
                    self.currentlySyncingName = "No audio files found in Documents"
                    self.syncTotal = 0
                } else {
                    self.currentlySyncingName = "Found \(audioURLs.count) audio file(s)"
                    self.syncTotal = audioURLs.count
                }
            }
            
            // Use standardized URLs for comparison
            let newAudioURLs = audioURLs.filter { !existingURLs.contains($0.standardized) }

            // Update total for the progress bar
            await MainActor.run {
                self.syncTotal = newAudioURLs.count
                self.syncProgress = 0
            }

            // 2. If no new songs, update UI with helpful message and return early
            if newAudioURLs.isEmpty {
                let message: String
                if audioURLs.isEmpty {
                    message = "No audio files found in Documents folder"
                } else if audioURLs.count == allSongs.count {
                    message = "All \(audioURLs.count) song(s) already imported"
                } else {
                    message = "\(audioURLs.count) song(s) found, all already imported"
                }
                
                await MainActor.run {
                    self.syncProgress = 0
                    self.currentlySyncingName = message
                }
                // Small delay to show the message before closing (defer will handle closing)
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                return
            }

            // 3. Import logic
            let container = modelContext.container
            let importer = SongImporter(modelContainer: container)

            await importer.importSongs(from: newAudioURLs) { current, total in
                // Always update UI immediately
                Task { @MainActor in
                    self.syncProgress = Double(current)
                    self.syncTotal = total
                    if current > 0 && current <= newAudioURLs.count {
                        self.currentlySyncingName = newAudioURLs[current - 1].lastPathComponent
                    } else if current == 0 && total > 0 {
                        self.currentlySyncingName = "Starting import..."
                    } else if total == 0 {
                        self.currentlySyncingName = "No files to import"
                    } else if current == total && total > 0 {
                        // Import complete
                        self.currentlySyncingName = "Import complete! (\(total) songs)"
                    }
                }
            }
            
            // Ensure UI is updated after import completes
            await MainActor.run {
                if syncProgress < Double(newAudioURLs.count) {
                    syncProgress = Double(newAudioURLs.count)
                    syncTotal = newAudioURLs.count
                    currentlySyncingName = "Import complete! (\(newAudioURLs.count) songs)"
                }
            }
            
            // Brief delay to show completion message
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            // Task reaches the end here -> defer block triggers -> isSyncing becomes false
        }
    }

    /// Import only the given URLs (e.g. from server upload). No full-disk scan.
    private func importUploadedFilesOnly(_ urls: [URL]) {
        let container = modelContext.container
        Task { @MainActor in
            isSyncing = true
            syncProgress = 0
            syncTotal = 0
            currentlySyncingName = "Checking uploaded files..."
        }

        Task(priority: .userInitiated) {
            defer {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    withAnimation(.spring()) { self.isSyncing = false }
                }
            }

            let existingURLs = await MainActor.run {
                Set(allSongs.map { $0.url.standardized })
            }
            let newURLs = urls.filter { !existingURLs.contains($0.standardized) }

            await MainActor.run {
                if newURLs.isEmpty {
                    currentlySyncingName = "All \(urls.count) file(s) already in library"
                    syncTotal = 0
                    syncProgress = 0
                } else {
                    syncTotal = newURLs.count
                    syncProgress = 0
                    currentlySyncingName = "Importing \(newURLs.count) new file(s)..."
                }
            }

            if newURLs.isEmpty {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return
            }

            let importer = SongImporter(modelContainer: container)
            await importer.importSongs(from: newURLs) { current, total in
                Task { @MainActor in
                    self.syncProgress = Double(current)
                    self.syncTotal = total
                    if current > 0, current <= newURLs.count {
                        self.currentlySyncingName = newURLs[current - 1].lastPathComponent
                    } else if current == total, total > 0 {
                        self.currentlySyncingName = "Import complete! (\(total) song\(total == 1 ? "" : "s"))"
                    }
                }
            }

            await MainActor.run {
                syncProgress = Double(newURLs.count)
                syncTotal = newURLs.count
                currentlySyncingName = "Import complete! (\(newURLs.count) song\(newURLs.count == 1 ? "" : "s"))"
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // LAYER 1: The Main Navigation
            TabView(selection: $selectedTab) {
                // Tab 0: Library
                NavigationStack {
                    LibraryTab(
                        playerManager: playerManager,
                        serverManager: serverManager,
                        selectedTab: $selectedTab,
                        searchQuery: $searchQuery,
                        artistToNavigate: $artistToNavigate,
                        albumToNavigate: $albumToNavigate,
                        onOpenSettings: { showSettings = true }
                    )
                }
                .tag(0)
                .tabItem { Label("Library", systemImage: "music.note.list") }
                
                // Tab 1: Artists (NEEDS NavigationStack for Detail views)
                NavigationStack {
                    ArtistsTab(
                        playerManager: playerManager,
                        allSongs: allSongs,
                        searchQuery: $searchQuery,
                        selectedTab: $selectedTab,
                        artistToNavigate: $artistToNavigate,
                        albumToNavigate: $albumToNavigate,
                        onOpenSettings: { showSettings = true }
                    )
                }
                .tag(1)
                .tabItem { Label("Artists", systemImage: "music.mic") }
                
                // Tab 2: Albums (NEEDS NavigationStack for Detail views)
                NavigationStack {
                    AlbumsTab(
                        playerManager: playerManager,
                        allSongs: allSongs,
                        searchQuery: $searchQuery,
                        selectedTab: $selectedTab,
                        albumToNavigate: $albumToNavigate,
                        artistToNavigate: $artistToNavigate,
                        onOpenSettings: { showSettings = true }
                    )
                }
                .tag(2)
                .tabItem { Label("Albums", systemImage: "rectangle.stack") }
                
                // Tab 3: Playlists
                NavigationStack {
                    PlaylistsTab(
                        playerManager: playerManager,
                        allSongs: allSongs,
                        onRefresh: { syncLocalFiles() },
                        onOpenSettings: { showSettings = true }
                    )
                }
                .tag(3)
                .tabItem { Label("Playlists", systemImage: "music.note.house") }
            }

            // LAYER 2: The Floating Mini Player
            if !isPlayerExpanded {
                miniPlayerOverlay
                    .zIndex(1)
            }

            // LAYER 3: The Global Import Overlay
            if isSyncing {
                importOverlayView
                    .zIndex(2)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = frame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .confirmationDialog(
            "Delete Song",
            isPresented: .constant(songToDelete != nil),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let song = songToDelete {
                    deleteSong(song)
                    songToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                songToDelete = nil
            }
        } message: {
            if let song = songToDelete {
                Text("Are you sure you want to delete \"\(song.title)\" by \(song.artist)? This will permanently delete the file from your device.")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(serverManager: serverManager, playerManager: playerManager)
        }
        // This places the Toast at the absolute top of the visual stack
        .modifier(GlobalToastOverlay(playerManager: playerManager))
        // Set model container for server manager
        .onAppear {
            serverManager.setModelContainer(modelContext.container)
            playerManager.onPlayRecord = { [modelContext] song in
                recordPlay(context: modelContext, song: song)
            }
            // Check for pending widget actions when app appears (with delay to ensure everything is ready)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.checkForPendingWidgetAction()
            }
            // After an app update the container path can change; fix stale song URLs once per launch
            // so playback works without the user having to hit Refresh (which wipes and re-imports).
            if !hasFixedStaleSongURLsThisLaunch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    fixStaleSongURLsIfNeeded()
                    hasFixedStaleSongURLsThisLaunch = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ZenWidgetAction"))) { notification in
            if let action = notification.userInfo?["action"] as? String {
                #if DEBUG
                print("Widget: ContentView received ZenWidgetAction notification for '\(action)'")
                #endif
                // Process immediately - PlayerManager should be ready
                self.handleWidgetAction(action)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ZenWidgetToggleAction"))) { _ in
            // Handle toggle action with access to allSongs immediately
            #if DEBUG
            print("Widget: ContentView received ZenWidgetToggleAction notification")
            #endif
            self.handleWidgetAction("toggle")
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Check for pending widget actions when app becomes active
            // Check immediately and also after a short delay to catch race conditions
            #if DEBUG
            print("Widget: ContentView - App became active, checking for pending actions")
            #endif
            self.checkForPendingWidgetAction()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.checkForPendingWidgetAction()
            }
        }
        #endif
        // Poll for widget actions while app is in foreground
        .onReceive(widgetActionTimer) { _ in
            self.checkForPendingWidgetAction()
        }
        // Auto-sync when files are uploaded via server
        .onChange(of: serverManager.filesUploaded) { _, uploaded in
            if uploaded {
                let urls = serverManager.recentlyUploadedAudioURLs
                serverManager.recentlyUploadedAudioURLs = []
                if !urls.isEmpty {
                    importUploadedFilesOnly(urls)
                } else {
                    syncLocalFiles()
                }
            }
        }
        // -----------------------------
        .fullScreenCover(isPresented: $isPlayerExpanded) {
            if let currentSong = playerManager.currentSong {
                FullPlayerView(
                    playerManager: playerManager,
                    song: currentSong,
                    allPlaylists: playlists,
                    onNavigateToArtist: { artistName in
                        // 1. Close the player
                        isPlayerExpanded = false
                        
                        // 2. Wait for the slide-down animation to finish
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            // 3. Switch to the Artists Tab (tag 1)
                            self.selectedTab = 1
                            // 4. Set the search query to filter the list automatically
                            self.searchQuery = artistName
                        }
                    },
                    onNavigateToAlbum: { albumName in
                        isPlayerExpanded = false
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            // 3. Switch to the Albums Tab (tag 2)
                            self.selectedTab = 2
                            self.searchQuery = albumName
                        }
                    }
                )
            }
        }
        .confirmationDialog(
            "Delete Song",
            isPresented: .constant(songToDelete != nil),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let song = songToDelete {
                    deleteSong(song)
                    songToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                songToDelete = nil
            }
        } message: {
            if let song = songToDelete {
                Text("Are you sure you want to delete \"\(song.title)\" by \(song.artist)? This will permanently delete the file from your device.")
            }
        }
        // Temporarily disabled automatic import - songs are already imported
        // .onAppear { syncLocalFiles() }
    }
    // --- EXTRACTED COMPONENTS TO FIX COMPILER TIMEOUT ---

    @ViewBuilder
    private var miniPlayerOverlay: some View {
        if playerManager.currentSong != nil {
            MiniPlayerView(
                playerManager: playerManager,
                progressTracker: playerManager.progressTracker,
                onTap: {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                        isPlayerExpanded = true
                    }
                }
            )
            .padding(.horizontal, 8)
            .padding(.bottom, keyboardHeight > 0 ? keyboardHeight * 0.03 + 1 : 54)
            .transition(AnyTransition.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var fullPlayerSheet: some View {
        if let current = playerManager.currentSong {
            FullPlayerView(
                playerManager: playerManager,
                song: current,
                allPlaylists: playlists,
                onNavigateToArtist: { artistName in
                    self.searchQuery = artistName
                    self.selectedTab = 1
                    self.isPlayerExpanded = false
                },
                onNavigateToAlbum: { albumName in
                    self.searchQuery = albumName
                    self.selectedTab = 2
                    self.isPlayerExpanded = false
                }
            )
        }
    }
    
    private var importOverlayView: some View {
            VStack(spacing: 20) {
                ProgressView(value: syncProgress, total: Double(syncTotal))
                    .progressViewStyle(.linear)
                    .tint(.yellow)
                    .padding()

                Text("Importing \(Int(syncProgress)) of \(syncTotal)")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text(currentlySyncingName)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.85))
            .transition(.opacity)
            .zIndex(100)
        }
}

// MARK: - SHARED COMPONENTS
struct IndexBar: View {
    let letters: [String]
    let proxy: ScrollViewProxy
    
    // Feedback generator for that native tactile "click" as you slide
    #if os(iOS)
    private let feedback = UISelectionFeedbackGenerator()
    #endif
    
    // Track the last letter to prevent redundant scrolling/haptics
    @State private var lastLetter: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.yellow)
                    .frame(width: 30, height: 16) // Height must match the calculation below
                    .contentShape(Rectangle())
            }
        }
        // background(Color.black.opacity(0.01)) is critical—it makes the
        // empty spaces between letters draggable while staying transparent.
        .background(Color.black.opacity(0.01))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Logic: location.y / itemHeight
                    let index = Int(value.location.y / 16)
                    
                    if index >= 0 && index < letters.count {
                        let letter = letters[index]
                        
                        if letter != lastLetter {
                            lastLetter = letter
                            
                            // Prepare and trigger haptic feedback
                            #if os(iOS)
                            feedback.prepare()
                            feedback.selectionChanged()
                            #endif
                            
                            // Native-feel scroll: use a very short animation or none at all
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(letter, anchor: .top)
                            }
                        }
                    }
                }
                .onEnded { _ in
                    // Reset so if the user taps the same letter twice,
                    // the haptic still triggers.
                    lastLetter = ""
                }
        )
        // Ensure the entire bar has a fixed width so it doesn't expand
        .frame(width: 30)
    }
}

struct SongRow: View {
    let song: Song
    let isCurrent: Bool
    let action: () -> Void
    
    // NEW: Controls the right-side padding for the A-Z IndexBar
    var showIndexGap: Bool = false
    
    // Optional closures for the context menu
    var onQueueNext: (() -> Void)? = nil
    var onGoToArtist: (() -> Void)? = nil
    var onGoToAlbum: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onRemoveFromPlaylist: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // 1. Using our unified view for consistency
                SongArtworkView(song: song, size: 48)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.body)
                        .fontWeight(isCurrent ? .bold : .regular)
                        .foregroundColor(isCurrent ? .yellow : .primary)
                        .lineLimit(1)
                    
                    Text(song.artist)
                        .font(.caption)
                        .foregroundColor(isCurrent ? .yellow.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
                
                Spacer() // This creates the gap
                
                if isCurrent {
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                }
            }
            .padding(.vertical, 4)
            .padding(.leading, 8) // Optional: adds a little breathing room on the left
            .padding(.trailing, showIndexGap ? 35 : 8)
            // 2. THIS IS THE KEY: Makes the entire HStack (including the Spacer) tappable
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain) // Keeps text colors exactly as you defined them
        .listRowBackground(Color.clear)
        
        // Unified Context Menu
        .contextMenu {
            if let onQueueNext = onQueueNext {
                Button { onQueueNext() } label: {
                    Label("Play Next", systemImage: "text.badge.plus")
                }
            }
            
            if let onGoToArtist = onGoToArtist {
                Button { onGoToArtist() } label: {
                    Label("Go to Artist", systemImage: "person.circle")
                }
            }
            
            if let onGoToAlbum = onGoToAlbum {
                Button { onGoToAlbum() } label: {
                    Label("Go to Album", systemImage: "rectangle.stack")
                }
            }
            
            if let onAddToPlaylist = onAddToPlaylist {
                Button { onAddToPlaylist() } label: {
                    Label("Add to Playlist", systemImage: "music.note.list")
                }
            }
            
            if let onRemoveFromPlaylist = onRemoveFromPlaylist {
                Button { onRemoveFromPlaylist() } label: {
                    Label("Remove from Playlist", systemImage: "minus.circle")
                }
            }
            
            if let onDelete = onDelete {
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

struct LibraryTab: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var playerManager: PlayerManager
    @ObservedObject var serverManager: TelegraphServerManager
    @Query(sort: \Song.title) var allSongs: [Song]
    @Query(sort: \Playlist.name) var allPlaylists: [Playlist]
    @Binding var selectedTab: Int
    @Binding var searchQuery: String
    @Binding var artistToNavigate: String?
    @Binding var albumToNavigate: String?
    var onOpenSettings: (() -> Void)? = nil
    @State private var searchText = ""
    @State private var showQueueToast = false
    @State private var showPlaylistToast = false
    @State private var playlistToastMessage = ""
    @State private var keyboardHeight: CGFloat = 0
    @State private var songToAddToPlaylist: Song?
    @State private var songToDelete: Song? = nil
    @State private var selectedArtist: ArtistNavigationItem? = nil
    @State private var selectedAlbum: AlbumNavigationItem? = nil
    @State private var isSelectionMode = false
    @State private var selectedSongIDs: Set<URL> = []
    @State private var showHiddenSongs = false
    
    /// Cached visible list and count to avoid O(n) filter on every body evaluation (e.g. 6000+ songs).
    @State private var cachedVisibleSongs: [Song] = []
    @State private var cachedHiddenCount: Int = 0
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var allSongsDebounceTask: Task<Void, Never>?
    
    private func updateVisibleCache() {
        let vis = allSongs.filter { !$0.hiddenFromLibrary }
        cachedVisibleSongs = vis
        cachedHiddenCount = allSongs.count - vis.count
    }
    
    // Optimize for large libraries: cache computed properties
    @State private var cachedGroupedSongs: [String: [Song]] = [:]
    @State private var cachedSectionHeaders: [String] = []
    @State private var isProcessing = false
    
    // MARK: - Delete Song Function
    func deleteSong(_ song: Song) {
        // 1. Stop playback if this is the current song
        if playerManager.currentSong?.id == song.id {
            if playerManager.isPlaying {
                playerManager.togglePause()
            }
            playerManager.currentSong = nil
        }
        
        // 2. Remove from queues if present
        playerManager.manualQueue.removeAll { $0.id == song.id }
        playerManager.queue.removeAll { $0.id == song.id }
        
        // 3. Delete the file from filesystem
        let fileManager = FileManager.default
        let fileURL = song.url
        
        // Start accessing security-scoped resource if needed
        let accessGranted = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        // Check if file exists before trying to delete
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.removeItem(at: fileURL)
                #if DEBUG
                print("Successfully deleted file: \(fileURL.lastPathComponent)")
                #endif
            } catch {
                #if DEBUG
                print("Error deleting file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                #endif
                // Continue with database deletion even if file delete fails
                // (file might have been moved/deleted externally)
            }
        } else {
            #if DEBUG
            print("File does not exist at path: \(fileURL.path), removing from database only")
            #endif
        }
        
        // 4. Remove from all playlists (SwiftData relationship will handle this automatically)
        // But we should also explicitly remove it to be safe
        if let playlists = song.playlists {
            for playlist in playlists {
                playlist.songs?.removeAll { $0.id == song.id }
                removeSongFromPlaylistOrder(playlist: playlist, song: song)
            }
        }
        
        // 5. Record history then delete from SwiftData
        recordHistory(context: modelContext, action: "deleted_from_library", songTitle: song.title, songArtist: song.artist)
        modelContext.delete(song)
        
        // 6. Save the context
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("Error saving after delete: \(error.localizedDescription)")
            #endif
        }
    }
    
    private func bulkHideSelected() {
        for id in selectedSongIDs {
            if let song = allSongs.first(where: { $0.id == id }) {
                song.hiddenFromLibrary = true
            }
        }
        try? modelContext.save()
        selectedSongIDs.removeAll()
        isSelectionMode = false
        updateVisibleCache()
        processSongs(cachedVisibleSongs, searchText: searchText)
    }
    
    private func toggleSelection(_ song: Song) {
        if selectedSongIDs.contains(song.id) {
            selectedSongIDs.remove(song.id)
        } else {
            selectedSongIDs.insert(song.id)
        }
    }
    
    // MARK: - Computed Properties (Optimized for 6,000+ songs)
    
    private func processSongs(_ songs: [Song], searchText: String) {
        // Process in background to avoid blocking UI
        Task(priority: .userInitiated) {
            isProcessing = true
            defer { isProcessing = false }
            
            // MEMORY OPTIMIZATION: Process in batches for large libraries
            let batchSize = 1000
            var filtered: [Song] = []
            
            if searchText.isEmpty {
                // No filtering needed, use all songs but process in batches
                filtered = songs
            } else {
                // Filter in batches to reduce memory pressure
                for i in stride(from: 0, to: songs.count, by: batchSize) {
                    let endIndex = min(i + batchSize, songs.count)
                    let batch = songs[i..<endIndex]
                    let batchFiltered = batch.filter { song in
                        song.title.localizedCaseInsensitiveContains(searchText) ||
                        song.artist.localizedCaseInsensitiveContains(searchText)
                    }
                    filtered.append(contentsOf: batchFiltered)
                    
                    // Yield periodically
                    if i % (batchSize * 2) == 0 {
                        await Task.yield()
                    }
                }
            }
            
            // Sort with optimized logic
            let sorted = filtered.sorted { (a: Song, b: Song) -> Bool in
                let punctuation = CharacterSet.punctuationCharacters
                let whitespaces = CharacterSet.whitespaces
                let combinedSet = punctuation.union(whitespaces)
                
                // Remove "The" prefix for sorting
                let cleanA = removeThePrefix(a.title).trimmingCharacters(in: combinedSet)
                let cleanB = removeThePrefix(b.title).trimmingCharacters(in: combinedSet)
                
                let finalA = cleanA.isEmpty ? removeThePrefix(a.title) : cleanA
                let finalB = cleanB.isEmpty ? removeThePrefix(b.title) : cleanB
                
                let aFirst = String(finalA.prefix(1)).uppercased()
                let bFirst = String(finalB.prefix(1)).uppercased()
                
                let aIsLetter = aFirst.rangeOfCharacter(from: CharacterSet.letters) != nil
                let bIsLetter = bFirst.rangeOfCharacter(from: CharacterSet.letters) != nil
                
                if !aIsLetter && bIsLetter { return true }
                if aIsLetter && !bIsLetter { return false }
                
                return finalA.localizedCaseInsensitiveCompare(finalB) == .orderedAscending
            }
            
            // Group into sections
            let grouped = Dictionary(grouping: sorted) { (song: Song) -> String in
                var cleaned = song.title.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
                
                // Remove "The" prefix for grouping
                cleaned = removeThePrefix(cleaned)
                
                // Remove dollar signs (they should be treated as if they don't exist)
                cleaned = cleaned.replacingOccurrences(of: "$", with: "")
                
                // Normalize accented characters to their base form (é -> e, ç -> c, etc.)
                let normalized = cleaned.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                
                guard let firstChar = normalized.first else { return "Ω" }
                let letter = String(firstChar).uppercased()
                
                // Check if it's an English letter (A-Z) after normalization
                if letter.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")) != nil {
                    return letter
                }
                // Check if it's a number (0-9)
                else if letter.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil {
                    return "#"
                }
                // Everything else (non-English characters, symbols, etc.) goes to omega
                else {
                    return "Ω"
                }
            }
            
            let headers = grouped.keys.sorted { a, b in
                // Sort: # first, then A-Z, then Ω last
                if a == "#" { return true }
                if b == "#" { return false }
                if a == "Ω" { return false }
                if b == "Ω" { return true }
                return a < b
            }
            
            // Update UI on main thread
            await MainActor.run {
                withAnimation(.default) {
                    self.cachedGroupedSongs = grouped
                    self.cachedSectionHeaders = headers
                }
            }
        }
    }
    
    private var groupedSongs: [String: [Song]] {
        cachedGroupedSongs
    }
    
    private var sectionHeaders: [String] {
        cachedSectionHeaders
    }
    
    @ViewBuilder
    private func songRowView(song: Song) -> some View {
        SongRow(
            song: song,
            isCurrent: playerManager.currentSong?.id == song.id,
            action: { playContextualSong(song) },
            showIndexGap: searchText.isEmpty,
            onQueueNext: {
                playerManager.addToQueue(song: song, playNext: true)
            },
            onGoToArtist: {
                // Navigate within the same NavigationStack to preserve back button
                selectedArtist = ArtistNavigationItem(artist: song.artist)
            },
            onGoToAlbum: {
                // Navigate within the same NavigationStack to preserve back button
                selectedAlbum = AlbumNavigationItem(album: song.album)
            },
            onAddToPlaylist: {
                songToAddToPlaylist = song
            },
            onDelete: {
                confirmDelete(song)
            }
        )
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                playerManager.addToQueue(song: song, playNext: true)
            } label: {
                Label("Queue", systemImage: "text.badge.plus")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmDelete(song)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }
    
    @ViewBuilder
    private func librarySongRowSelectable(song: Song) -> some View {
        Button {
            toggleSelection(song)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedSongIDs.contains(song.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selectedSongIDs.contains(song.id) ? .yellow : .secondary)
                    .font(.title2)
                SongArtworkView(song: song, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.body)
                        .foregroundColor(.primary)
                    Text(song.artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.leading, 8)
            .padding(.trailing, searchText.isEmpty ? 35 : 8)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ZStack {
                    List {
                        Text("\(cachedVisibleSongs.count) Songs")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .listRowBackground(Color.clear)

                        if isProcessing && groupedSongs.isEmpty {
                            ProgressView("Processing songs...")
                                .frame(maxWidth: .infinity)
                                .padding()
                        } else {
                            ForEach(sectionHeaders, id: \.self) { key in
                                Section(header: Text(key)
                                    .foregroundColor(.yellow)
                                    .font(.headline)
                                    .id(key)) {
                                    ForEach(groupedSongs[key] ?? []) { song in
                                        if isSelectionMode {
                                            librarySongRowSelectable(song: song)
                                        } else {
                                            songRowView(song: song)
                                        }
                                    }
                                }
                            }
                        }
                        
                        Color.clear
                            .frame(height: 80)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden) // Ensures no separator line appears in the empty space
                    }
                    .listStyle(.plain)
                    
                    if searchText.isEmpty {
                        HStack {
                            Spacer()
                            IndexBar(letters: sectionHeaders, proxy: proxy)
                                .padding(.trailing, 8)
                        }
                    }
                    
                    if showQueueToast {
                        VStack {
                            Spacer()
                            glassToastView
                                .padding(.bottom, 110)
                        }
                        .zIndex(100)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    
                    if showPlaylistToast {
                        VStack {
                            Spacer()
                            playlistToastView
                                .padding(.bottom, 90 + keyboardHeight)
                        }
                        .zIndex(100)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                    if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                        keyboardHeight = frame.height
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    keyboardHeight = 0
                }
                .navigationTitle("Library")
                .searchable(text: $searchText)
                .onAppear {
                    updateVisibleCache()
                    // Initial processing (only visible songs in Library tab)
                    if cachedGroupedSongs.isEmpty {
                        processSongs(cachedVisibleSongs, searchText: searchText)
                    }
                }
                .onChange(of: allSongs) { oldValue, newValue in
                    updateVisibleCache()
                    allSongsDebounceTask?.cancel()
                    if cachedGroupedSongs.isEmpty {
                        processSongs(cachedVisibleSongs, searchText: searchText)
                    } else {
                        allSongsDebounceTask = Task {
                            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                processSongs(cachedVisibleSongs, searchText: searchText)
                            }
                        }
                    }
                }
                .onChange(of: searchText) { _, newValue in
                    searchQuery = newValue
                    searchDebounceTask?.cancel()
                    searchDebounceTask = Task {
                        let value = newValue
                        try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            processSongs(cachedVisibleSongs, searchText: value)
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            onOpenSettings?()
                        } label: {
                            Image(systemName: "gearshape")
                                .foregroundColor(.yellow)
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 12) {
                            // Shuffle Button (from visible songs in Library)
                            Button {
                                if let randomSong = cachedVisibleSongs.randomElement() {
                                    playerManager.play(song: randomSong, from: cachedVisibleSongs)
                                    playerManager.enableShuffleAndShuffleQueue()
                                }
                            } label: {
                                Image(systemName: "shuffle")
                                    .foregroundColor(.yellow)
                            }
                            
                            if !isSelectionMode {
                                Button {
                                    isSelectionMode = true
                                    selectedSongIDs.removeAll()
                                } label: {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundColor(.yellow)
                                }
                            }
                        }
                    }
                    if isSelectionMode {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Cancel") {
                                isSelectionMode = false
                                selectedSongIDs.removeAll()
                            }
                            .foregroundColor(.yellow)
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Hide (\(selectedSongIDs.count))") {
                                bulkHideSelected()
                            }
                            .foregroundColor(.yellow)
                            .disabled(selectedSongIDs.isEmpty)
                        }
                    }
                }
                .sheet(item: $songToAddToPlaylist) { song in
                    PlaylistPickerSheet(
                        song: song,
                        onDismiss: {
                            songToAddToPlaylist = nil
                        },
                        onAddedToPlaylist: { playlistName in
                            playlistToastMessage = "Added to \(playlistName)"
                            withAnimation(.spring()) {
                                showPlaylistToast = true
                            }
                        }
                    )
                    .presentationDetents([.medium, .large])
                }
                .navigationDestination(item: $selectedArtist) { item in
                    ArtistDetailView(
                        artist: item.artist,
                        allSongs: allSongs,
                        allPlaylists: allPlaylists,
                        playerManager: playerManager,
                        selectedTab: $selectedTab,
                        searchQuery: $searchQuery,
                        modelContext: modelContext,
                        songToAddToPlaylist: $songToAddToPlaylist,
                        albumToNavigate: $albumToNavigate
                    )
                }
                .navigationDestination(item: $selectedAlbum) { item in
                    AlbumDetailView(
                        album: item.album,
                        allSongs: allSongs,
                        allPlaylists: allPlaylists,
                        playerManager: playerManager,
                        selectedTab: $selectedTab,
                        searchQuery: $searchQuery,
                        modelContext: modelContext,
                        songToAddToPlaylist: $songToAddToPlaylist,
                        artistToNavigate: $artistToNavigate
                    )
                }
            }
        }
        .confirmationDialog(
            "Delete Song",
            isPresented: .constant(songToDelete != nil),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let song = songToDelete {
                    deleteSong(song)
                    songToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                songToDelete = nil
            }
        } message: {
            if let song = songToDelete {
                Text("Are you sure you want to delete \"\(song.title)\" by \(song.artist)? This will permanently delete the file from your device.")
            }
        }
    }
    
    // MARK: - Delete Song Function
    func confirmDelete(_ song: Song) {
        songToDelete = song
    }

    // MARK: - Extracted UI Components
    private var glassToastView: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.badge.plus")
                .foregroundColor(.primary)
            Text("Added to Queue")
                .font(.subheadline.bold())
                .foregroundColor(.primary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.spring()) { showQueueToast = false }
            }
        }
    }
    
    private var playlistToastView: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .foregroundColor(.primary)
            Text(playlistToastMessage)
                .font(.subheadline.bold())
                .foregroundColor(.primary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.spring()) { showPlaylistToast = false }
            }
        }
    }

    private func playContextualSong(_ song: Song) {
        let sortedList = sectionHeaders.flatMap { key in
            groupedSongs[key] ?? []
        }
        playerManager.play(song: song, from: sortedList.isEmpty ? cachedVisibleSongs : sortedList)
    }
}

/// Lists songs hidden from the Library tab; supports select mode and bulk unhide.
struct HiddenSongsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Song.title) private var allSongs: [Song]
    var onUnhide: (() -> Void)? = nil
    
    @State private var isSelectionMode = false
    @State private var selectedSongIDs: Set<URL> = []
    
    private var hiddenSongs: [Song] {
        allSongs.filter { $0.hiddenFromLibrary }
    }
    
    var body: some View {
        List {
            if hiddenSongs.isEmpty {
                Text("No hidden songs.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(hiddenSongs, id: \.id) { song in
                    if isSelectionMode {
                        Button {
                            toggleSelection(song)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedSongIDs.contains(song.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedSongIDs.contains(song.id) ? .yellow : .secondary)
                                    .font(.title2)
                                SongArtworkView(song: song, size: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(song.artist)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack(spacing: 12) {
                            SongArtworkView(song: song, size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .font(.body)
                                Text(song.artist)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Hidden from library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hiddenSongs.isEmpty == false {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSelectionMode {
                        Button("Done") {
                            isSelectionMode = false
                            selectedSongIDs.removeAll()
                        }
                        .foregroundColor(.yellow)
                    } else {
                        Button {
                            isSelectionMode = true
                            selectedSongIDs.removeAll()
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(.yellow)
                        }
                    }
                }
                if isSelectionMode {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Unhide (\(selectedSongIDs.count))") {
                            bulkUnhideSelected()
                        }
                        .foregroundColor(.yellow)
                        .disabled(selectedSongIDs.isEmpty)
                    }
                }
            }
        }
    }
    
    private func toggleSelection(_ song: Song) {
        if selectedSongIDs.contains(song.id) {
            selectedSongIDs.remove(song.id)
        } else {
            selectedSongIDs.insert(song.id)
        }
    }
    
    private func bulkUnhideSelected() {
        for id in selectedSongIDs {
            if let song = allSongs.first(where: { $0.id == id }) {
                song.hiddenFromLibrary = false
            }
        }
        try? modelContext.save()
        selectedSongIDs.removeAll()
        isSelectionMode = false
        onUnhide?()
    }
}

struct ArtistNavigationItem: Identifiable, Hashable {
    let id: String
    let artist: String
    
    init(artist: String) {
        self.artist = artist
        self.id = artist
    }
}

struct ArtistsTab: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var playerManager: PlayerManager
    var allSongs: [Song]
    @Query(sort: \Playlist.name) var allPlaylists: [Playlist]
    @Binding var searchQuery: String
    @Binding var selectedTab: Int
    @Binding var artistToNavigate: String?
    @Binding var albumToNavigate: String?
    var onOpenSettings: (() -> Void)? = nil
    @State private var songToAddToPlaylist: Song?
    @State private var showPlaylistToast = false
    @State private var playlistToastMessage = ""
    @State private var keyboardHeight: CGFloat = 0
    @State private var selectedArtist: ArtistNavigationItem? = nil
    
    @StateObject private var viewModel = ArtistViewModel()

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                artistsList
                
                if searchQuery.isEmpty {
                    IndexBar(letters: viewModel.headers, proxy: proxy)
                        .frame(width: 30)
                }
            }
            .navigationTitle("Artists")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { onOpenSettings?() } label: {
                        Image(systemName: "gearshape")
                            .foregroundColor(.yellow)
                    }
                }
            }
            .searchable(text: $searchQuery)
            .sheet(item: $songToAddToPlaylist) { song in
                PlaylistPickerSheet(
                    song: song,
                    onDismiss: {
                        songToAddToPlaylist = nil
                    },
                    onAddedToPlaylist: { playlistName in
                        playlistToastMessage = "Added to \(playlistName)"
                        withAnimation(.spring()) {
                            showPlaylistToast = true
                        }
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .overlay {
                if showPlaylistToast {
                    VStack {
                        Spacer()
                        playlistToastView
                            .padding(.bottom, 90 + keyboardHeight)
                    }
                    .zIndex(100)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    keyboardHeight = frame.height
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardHeight = 0
            }
            .onChange(of: searchQuery) { _, newValue in
                viewModel.update(with: allSongs, searchText: newValue)
            }
            .onChange(of: artistToNavigate) { _, newValue in
                if let artist = newValue {
                    selectedArtist = ArtistNavigationItem(artist: artist)
                    artistToNavigate = nil // Clear after navigation
                }
            }
            .onAppear {
                viewModel.update(with: allSongs, searchText: searchQuery)
                // Check if we need to navigate on appear
                if let artist = artistToNavigate {
                    selectedArtist = ArtistNavigationItem(artist: artist)
                    artistToNavigate = nil
                }
            }
        }
    }
    
    @ViewBuilder
    private var artistsList: some View {
        List {
            ForEach(viewModel.headers, id: \.self) { key in
                Section(header: Text(key).foregroundColor(.yellow).font(.headline)) {
                    ForEach(viewModel.groupedArtists[key] ?? [], id: \.self) { artist in
                        Button {
                            selectedArtist = ArtistNavigationItem(artist: artist)
                        } label: {
                            HStack {
                                Text(artist)
                                    .font(.body)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle()) // Makes entire row tappable
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 50))
                    }
                }
                .id(key)
            }
        }
        .listStyle(.plain)
        .navigationDestination(item: $selectedArtist) { item in
            artistDetailView(for: item.artist)
        }
    }
    
    private func artistDetailView(for artist: String) -> ArtistDetailView {
        ArtistDetailView(
            artist: artist,
            allSongs: allSongs,
            allPlaylists: allPlaylists,
            playerManager: playerManager,
            selectedTab: $selectedTab,
            searchQuery: $searchQuery,
            modelContext: modelContext,
            songToAddToPlaylist: $songToAddToPlaylist,
            albumToNavigate: $albumToNavigate
        )
    }
    
    private var playlistToastView: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .foregroundColor(.primary)
            Text(playlistToastMessage)
                .font(.subheadline.bold())
                .foregroundColor(.primary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.spring()) { showPlaylistToast = false }
            }
        }
    }
    
}

// Helper function to remove "The" prefix for sorting/grouping
private func removeThePrefix(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.lowercased().hasPrefix("the ") {
        return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
    }
    return trimmed
}

// Helper function to extract primary artist name (handles commas and feat/ft variations)
private func extractPrimaryArtist(_ artistString: String) -> String {
    // First, try splitting by comma
    if let commaIndex = artistString.firstIndex(of: ",") {
        return String(artistString[..<commaIndex]).trimmingCharacters(in: .whitespaces)
    }
    
    // Then check for feat/ft variations (case insensitive, with spaces)
    let lowercased = artistString.lowercased()
    let patterns = [" feat. ", " feat ", " ft. ", " ft "]
    
    for pattern in patterns {
        if let range = lowercased.range(of: pattern) {
            // Convert the range from lowercased string to original string
            let patternStart = range.lowerBound
            let offset = lowercased.distance(from: lowercased.startIndex, to: patternStart)
            let originalIndex = artistString.index(artistString.startIndex, offsetBy: offset)
            return String(artistString[..<originalIndex]).trimmingCharacters(in: .whitespaces)
        }
    }
    
    // No separator found, return as-is
    return artistString.trimmingCharacters(in: .whitespaces)
}

@MainActor
class ArtistViewModel: ObservableObject {
    @Published var headers: [String] = []
    @Published var groupedArtists: [String: [String]] = [:]

    func update(with songs: [Song], searchText: String) {
        let query = searchText.lowercased()

        // Move to background thread
        Task(priority: .userInitiated) {
            // MEMORY OPTIMIZATION: Process in batches and use Set to avoid duplicates early
            var uniqueArtists = Set<String>()
            let batchSize = 500
            
            // Process songs in batches to reduce memory pressure
            for i in stride(from: 0, to: songs.count, by: batchSize) {
                let endIndex = min(i + batchSize, songs.count)
                let batch = songs[i..<endIndex]
                
                // Extract primary artist name from each song in batch (handles commas and feat/ft)
                for song in batch {
                    let primaryArtist = extractPrimaryArtist(song.artist)
                    uniqueArtists.insert(primaryArtist)
                }
                
                // Yield every batch to prevent blocking
                if i % (batchSize * 2) == 0 {
                    await Task.yield()
                }
            }
            
            // Convert to sorted array (ignore "The" prefix for sorting)
            let allArtists = Array(uniqueArtists).sorted { a, b in
                let aWithoutThe = removeThePrefix(a)
                let bWithoutThe = removeThePrefix(b)
                return aWithoutThe.localizedCaseInsensitiveCompare(bWithoutThe) == .orderedAscending
            }
            
            // 2. Filter based on query
            let filtered = query.isEmpty ? allArtists : allArtists.filter {
                $0.localizedCaseInsensitiveContains(query)
            }
            
            // 3. Group by First Letter of Primary Artist Name (handles commas and feat/ft)
            let grouped = Dictionary(grouping: filtered) { artist in
                // Extract primary artist name (already extracted, but normalize for grouping)
                var primaryArtist = extractPrimaryArtist(artist)
                
                // Remove "The" prefix for grouping
                primaryArtist = removeThePrefix(primaryArtist)
                
                // Normalize accented characters
                let normalized = primaryArtist.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                
                // Remove dollar signs
                let cleaned = normalized.replacingOccurrences(of: "$", with: "")
                
                guard let firstChar = cleaned.first else { return "Ω" }
                let firstLetter = String(firstChar).uppercased()
                
                // Check if it's an English letter (A-Z) after normalization
                if firstLetter.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")) != nil {
                    return firstLetter
                }
                // Check if it's a number (0-9)
                else if firstLetter.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil {
                    return "#"
                }
                // Everything else goes to omega
                else {
                    return "Ω"
                }
            }
            
            // 4. Sort Headers (Custom sort: # first, then A-Z, then Ω last)
            let sortedHeaders = grouped.keys.sorted { a, b in
                if a == "#" { return true }
                if b == "#" { return false }
                if a == "Ω" { return false }
                if b == "Ω" { return true }
                return a < b
            }

            // 5. Update UI properties on the Main Thread
            await MainActor.run {
                withAnimation(.default) {
                    self.groupedArtists = grouped
                    self.headers = sortedHeaders
                }
            }
        }
    }
}

struct ArtistDetailView: View {
    let artist: String
    let allSongs: [Song]
    let allPlaylists: [Playlist]
    @ObservedObject var playerManager: PlayerManager
    @Binding var selectedTab: Int
    @Binding var searchQuery: String
    let modelContext: ModelContext
    @Binding var songToAddToPlaylist: Song?
    @Binding var albumToNavigate: String?
    @State private var songToDelete: Song? = nil
    @State private var selectedAlbum: AlbumNavigationItem? = nil

    var artistSongs: [Song] {
        // Match songs where primary artist matches (handles commas and feat/ft variations)
        // This handles consolidated artists (e.g., "Drake" matches "Drake feat. WizKid & Kyla")
        allSongs.filter { song in
            let primaryArtist = extractPrimaryArtist(song.artist)
            return primaryArtist == artist
        }
    }
    
    // Group songs by album
    var songsByAlbum: [String: [Song]] {
        Dictionary(grouping: artistSongs) { $0.album }
    }
    
    // Get sorted album names
    var sortedAlbums: [String] {
        songsByAlbum.keys.sorted()
    }
    
    // Get songs in the order they appear on the page (grouped by album, sorted within albums)
    var artistSongsInDisplayOrder: [Song] {
        sortedAlbums.flatMap { album in
            // Sort songs within each album by title (ignoring "The" prefix)
            (songsByAlbum[album] ?? []).sorted { a, b in
                let aTitle = removeThePrefix(a.title)
                let bTitle = removeThePrefix(b.title)
                return aTitle.localizedCaseInsensitiveCompare(bTitle) == .orderedAscending
            }
        }
    }
    
    @ViewBuilder
    private func artistSongRow(song: Song) -> some View {
        SongRow(
            song: song,
            isCurrent: playerManager.currentSong?.id == song.id,
            action: {
                // Use the display order so queue matches what user sees
                playerManager.play(song: song, from: artistSongsInDisplayOrder)
            },
            showIndexGap: false,
            onQueueNext: {
                playerManager.addToQueue(song: song, playNext: true)
            },
            onGoToArtist: {
                // Already on artist page, do nothing
            },
            onGoToAlbum: {
                albumToNavigate = song.album
                selectedTab = 2
            },
            onAddToPlaylist: {
                songToAddToPlaylist = song
            },
            onDelete: {
                confirmDelete(song)
            }
        )
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                playerManager.addToQueue(song: song, playNext: true)
            } label: {
                Label("Queue", systemImage: "text.badge.plus")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmDelete(song)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }
    
    // MARK: - Delete Song Function
    func confirmDelete(_ song: Song) {
        songToDelete = song
    }
    
    func deleteSong(_ song: Song) {
        // 1. Stop playback if this is the current song
        if playerManager.currentSong?.id == song.id {
            if playerManager.isPlaying {
                playerManager.togglePause()
            }
            playerManager.currentSong = nil
        }
        
        // 2. Remove from queues if present
        playerManager.manualQueue.removeAll { $0.id == song.id }
        playerManager.queue.removeAll { $0.id == song.id }
        
        // 3. Delete the file from filesystem
        let fileManager = FileManager.default
        let fileURL = song.url
        
        // Start accessing security-scoped resource if needed
        let accessGranted = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        // Check if file exists before trying to delete
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.removeItem(at: fileURL)
                #if DEBUG
                print("Successfully deleted file: \(fileURL.lastPathComponent)")
                #endif
            } catch {
                #if DEBUG
                print("Error deleting file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                #endif
                // Continue with database deletion even if file delete fails
                // (file might have been moved/deleted externally)
            }
        } else {
            #if DEBUG
            print("File does not exist at path: \(fileURL.path), removing from database only")
            #endif
        }
        
        // 4. Remove from all playlists (SwiftData relationship will handle this automatically)
        // But we should also explicitly remove it to be safe
        if let playlists = song.playlists {
            for playlist in playlists {
                playlist.songs?.removeAll { $0.id == song.id }
                removeSongFromPlaylistOrder(playlist: playlist, song: song)
            }
        }
        
        // 5. Record history then delete from SwiftData
        recordHistory(context: modelContext, action: "deleted_from_library", songTitle: song.title, songArtist: song.artist)
        modelContext.delete(song)
        
        // 6. Save the context
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("Error saving after delete: \(error.localizedDescription)")
            #endif
        }
    }

    var body: some View {
        List {
            ForEach(sortedAlbums, id: \.self) { album in
                Section(header: 
                    Button {
                        selectedAlbum = AlbumNavigationItem(album: album)
                    } label: {
                        Text(album)
                            .foregroundColor(.yellow)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                ) {
                    ForEach(songsByAlbum[album] ?? []) { song in
                        artistSongRow(song: song)
                    }
                }
            }
            
            // Add bottom padding so mini player doesn't cover last song
            Color.clear
                .frame(height: 80)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .navigationTitle(artist)
        .navigationDestination(item: $selectedAlbum) { item in
            AlbumDetailView(
                album: item.album,
                allSongs: allSongs,
                allPlaylists: allPlaylists,
                playerManager: playerManager,
                selectedTab: $selectedTab,
                searchQuery: $searchQuery,
                modelContext: modelContext,
                songToAddToPlaylist: $songToAddToPlaylist,
                artistToNavigate: Binding<String?>(
                    get: { artist },
                    set: { _ in }
                )
            )
        }
        .confirmationDialog(
            "Delete Song",
            isPresented: .constant(songToDelete != nil),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let song = songToDelete {
                    deleteSong(song)
                    songToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                songToDelete = nil
            }
        } message: {
            if let song = songToDelete {
                Text("Are you sure you want to delete \"\(song.title)\" by \(song.artist)? This will permanently delete the file from your device.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if let randomSong = artistSongsInDisplayOrder.randomElement() {
                        playerManager.play(song: randomSong, from: artistSongsInDisplayOrder)
                        playerManager.enableShuffleAndShuffleQueue()
                    }
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundColor(.yellow)
                }
            }
        }
    }
}

struct AlbumsTab: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var playerManager: PlayerManager
    var allSongs: [Song]
    @Query(sort: \Playlist.name) var allPlaylists: [Playlist]
    @Binding var searchQuery: String
    @Binding var selectedTab: Int
    @Binding var albumToNavigate: String?
    @Binding var artistToNavigate: String?
    var onOpenSettings: (() -> Void)? = nil
    @State private var songToAddToPlaylist: Song?
    @State private var showPlaylistToast = false
    @State private var playlistToastMessage = ""
    @State private var keyboardHeight: CGFloat = 0
    @State private var selectedAlbum: AlbumNavigationItem?
    
    @StateObject private var viewModel = AlbumViewModel()

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                albumsList
                
                if searchQuery.isEmpty {
                    IndexBar(letters: viewModel.headers, proxy: proxy)
                        .frame(width: 30)
                }
            }
            .navigationTitle("Albums")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { onOpenSettings?() } label: {
                        Image(systemName: "gearshape")
                            .foregroundColor(.yellow)
                    }
                }
            }
            .searchable(text: $searchQuery)
            .sheet(item: $songToAddToPlaylist) { song in
                PlaylistPickerSheet(
                    song: song,
                    onDismiss: {
                        songToAddToPlaylist = nil
                    },
                    onAddedToPlaylist: { playlistName in
                        playlistToastMessage = "Added to \(playlistName)"
                        withAnimation(.spring()) {
                            showPlaylistToast = true
                        }
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .overlay {
                if showPlaylistToast {
                    VStack {
                        Spacer()
                        playlistToastView
                            .padding(.bottom, 90 + keyboardHeight)
                    }
                    .zIndex(100)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    keyboardHeight = frame.height
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardHeight = 0
            }
            .onChange(of: searchQuery) { _, newValue in
                viewModel.update(with: allSongs, searchText: newValue)
            }
            .onChange(of: albumToNavigate) { _, newValue in
                if let album = newValue {
                    selectedAlbum = AlbumNavigationItem(album: album)
                    albumToNavigate = nil // Clear after navigation
                }
            }
            .onAppear {
                viewModel.update(with: allSongs, searchText: searchQuery)
                // Check if we need to navigate on appear
                if let album = albumToNavigate {
                    selectedAlbum = AlbumNavigationItem(album: album)
                    albumToNavigate = nil
                }
            }
        }
    }
    
    @ViewBuilder
    private var albumsList: some View {
        List {
            ForEach(viewModel.headers, id: \.self) { key in
                Section(header: Text(key).foregroundColor(.yellow)) {
                    // MEMORY OPTIMIZATION: Use LazyVStack-like behavior by limiting initial render
                    // For omega section, render in smaller chunks to prevent memory crash
                    if key == "Ω" {
                        // For omega, render albums with onAppear to lazy load
                        ForEach(Array((viewModel.groupedAlbums[key] ?? []).enumerated()), id: \.element) { index, album in
                            albumRow(for: album)
                                .onAppear {
                                    // Trigger view model update in batches if needed
                                    // This helps SwiftUI manage memory better
                                }
                        }
                    } else {
                        // For other sections, render normally
                        ForEach(viewModel.groupedAlbums[key] ?? [], id: \.self) { album in
                            albumRow(for: album)
                        }
                    }
                }
                .id(key)
            }
        }
        .listStyle(.plain)
        .navigationDestination(item: $selectedAlbum) { item in
            AlbumDetailView(
                album: item.album,
                allSongs: allSongs,
                allPlaylists: allPlaylists,
                playerManager: playerManager,
                selectedTab: $selectedTab,
                searchQuery: $searchQuery,
                modelContext: modelContext,
                songToAddToPlaylist: $songToAddToPlaylist,
                artistToNavigate: $artistToNavigate
            )
        }
    }
    
    private func albumRow(for album: String) -> AlbumRow {
        AlbumRow(
            album: album,
            artist: viewModel.albumArtists[album] ?? "Unknown Artist",
            albumSong: viewModel.albumSongs[album], // MEMORY OPTIMIZATION: Pass pre-computed song
            playerManager: playerManager,
            allSongs: allSongs,
            allPlaylists: allPlaylists,
            selectedTab: $selectedTab,
            searchQuery: $searchQuery,
            modelContext: modelContext,
            songToAddToPlaylist: $songToAddToPlaylist,
            onTap: { selectedAlbum = AlbumNavigationItem(album: album) }
        )
    }
    
    private var playlistToastView: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .foregroundColor(.primary)
            Text(playlistToastMessage)
                .font(.subheadline.bold())
                .foregroundColor(.primary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.spring()) { showPlaylistToast = false }
            }
        }
    }
    
}

// Separate view to prevent the main list from re-rendering
struct AlbumRow: View {
    let album: String
    let artist: String // Receive artist here
    let albumSong: Song? // MEMORY OPTIMIZATION: Pre-computed first song for artwork
    let playerManager: PlayerManager
    let allSongs: [Song]
    let allPlaylists: [Playlist]
    @Binding var selectedTab: Int
    @Binding var searchQuery: String
    let modelContext: ModelContext
    @Binding var songToAddToPlaylist: Song?
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Album artwork - use pre-computed song
                if let song = albumSong {
                    SongArtworkView(song: song, size: 48)
                } else {
                    // Placeholder if no song found
                    ZStack {
                        Color.gray.opacity(0.2)
                        Image(systemName: "music.note")
                            .foregroundColor(.gray)
                    }
                    .frame(width: 48, height: 48)
                    .cornerRadius(4)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(album)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    
                    Text(artist)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.leading, 8)
            .padding(.trailing, 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }
}

// Wrapper struct for album navigation
struct AlbumNavigationItem: Identifiable, Hashable {
    let id: String
    let album: String
    
    init(album: String) {
        self.album = album
        self.id = album
    }
}

@MainActor
class AlbumViewModel: ObservableObject {
    @Published var headers: [String] = []
    @Published var groupedAlbums: [String: [String]] = [:]
    @Published var albumArtists: [String: String] = [:]
    @Published var albumSongs: [String: Song] = [:] // MEMORY OPTIMIZATION: Pre-compute album to first song mapping

    func update(with songs: [Song], searchText: String) {
        let query = searchText.lowercased()

        Task(priority: .userInitiated) {
            // --- Background Thread ---
            
            // MEMORY OPTIMIZATION: Process in batches
            var artistMapping: [String: String] = [:]
            var albumSongMapping: [String: Song] = [:] // Pre-compute first song per album
            var uniqueAlbums = Set<String>()
            let batchSize = 500
            
            // Process songs in batches to reduce memory pressure
            for i in stride(from: 0, to: songs.count, by: batchSize) {
                let endIndex = min(i + batchSize, songs.count)
                let batch = songs[i..<endIndex]
                
                for song in batch {
                    if artistMapping[song.album] == nil {
                        artistMapping[song.album] = song.artist
                    }
                    // Store first song for each album (for artwork)
                    if albumSongMapping[song.album] == nil {
                        albumSongMapping[song.album] = song
                    }
                    uniqueAlbums.insert(song.album)
                }
                
                // Yield every batch to prevent blocking
                if i % (batchSize * 2) == 0 {
                    await Task.yield()
                }
            }
            
            // 2. Get unique albums and filter (ignore "The" prefix for sorting)
            let allAlbums = Array(uniqueAlbums).sorted { a, b in
                let aWithoutThe = removeThePrefix(a)
                let bWithoutThe = removeThePrefix(b)
                return aWithoutThe.localizedCaseInsensitiveCompare(bWithoutThe) == .orderedAscending
            }
            let filtered = query.isEmpty ? allAlbums : allAlbums.filter { albumName in
                let artistName = artistMapping[albumName] ?? ""
                return albumName.localizedCaseInsensitiveContains(query) ||
                       artistName.localizedCaseInsensitiveContains(query)
            }
            
            // 3. Group by First Letter (with normalization and omega support)
            let grouped = Dictionary(grouping: filtered) { album in
                // Remove "The" prefix for grouping
                let albumName = removeThePrefix(album)
                
                // Normalize accented characters
                let normalized = albumName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                
                // Remove dollar signs
                let cleaned = normalized.replacingOccurrences(of: "$", with: "")
                
                guard let firstChar = cleaned.first else { return "Ω" }
                let firstLetter = String(firstChar).uppercased()
                
                // Check if it's an English letter (A-Z) after normalization
                if firstLetter.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")) != nil {
                    return firstLetter
                }
                // Check if it's a number (0-9)
                else if firstLetter.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil {
                    return "#"
                }
                // Everything else goes to omega
                else {
                    return "Ω"
                }
            }
            
            // 4. Sort Headers (Custom sort: # first, then A-Z, then Ω last)
            let sortedHeaders = grouped.keys.sorted { a, b in
                if a == "#" { return true }
                if b == "#" { return false }
                if a == "Ω" { return false }
                if b == "Ω" { return true }
                return a < b
            }

            // 5. Update UI properties
            await MainActor.run {
                withAnimation(.default) {
                    self.albumArtists = artistMapping
                    self.albumSongs = albumSongMapping // MEMORY OPTIMIZATION: Pre-computed mapping
                    self.groupedAlbums = grouped
                    self.headers = sortedHeaders
                }
            }
        }
    }
}

struct AddSongsToPlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var playlist: Playlist
    var allSongs: [Song]
    
    @State private var searchText = ""
    @State private var searchResults: [Song] = []
    @State private var searchTask: Task<Void, Never>? = nil

    // IMPROVEMENT: Pre-calculate added IDs for buttery smooth scrolling
    private var addedSongIDs: Set<PersistentIdentifier> {
        let songs: [Song] = playlist.songs ?? []
        return Set(songs.map { $0.persistentModelID })
    }

    var body: some View {
        NavigationStack {
            List(currentList) { song in
                PlaylistSelectionRow(
                    song: song,
                    // Lookups in a Set are near-instant (O(1))
                    isAdded: addedSongIDs.contains(song.persistentModelID),
                    onToggle: { toggle(song) }
                )
            }
            .listStyle(.plain)
            .navigationTitle("Add Songs")
            .searchable(text: $searchText)
            .onChange(of: searchText) { _, newValue in
                performDebouncedSearch(query: newValue)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.bold)
                        .foregroundColor(.yellow)
                }
            }
        }
    }

    private var currentList: [Song] {
        searchText.isEmpty ? allSongs : searchResults
    }

    private func performDebouncedSearch(query: String) {
        searchTask?.cancel()
        searchTask = Task {
            // 300ms delay to let typing finish
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }

            let filtered = allSongs.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.artist.localizedCaseInsensitiveContains(query)
            }
            
            await MainActor.run {
                self.searchResults = filtered
            }
        }
    }

    private func toggle(_ song: Song) {
        if playlist.songs == nil { playlist.songs = [] }
        
        // Use PersistentID for the most reliable SwiftData check
        if let index = playlist.songs?.firstIndex(where: { $0.persistentModelID == song.persistentModelID }) {
            playlist.songs?.remove(at: index)
            removeSongFromPlaylistOrder(playlist: playlist, song: song)
            recordHistory(context: modelContext, action: "removed_from_playlist", songTitle: song.title, songArtist: song.artist, playlistName: playlist.name)
        } else {
            playlist.songs?.append(song)
            appendSongToPlaylistOrder(playlist: playlist, song: song)
            recordHistory(context: modelContext, action: "added_to_playlist", songTitle: song.title, songArtist: song.artist, playlistName: playlist.name)
        }
        
        try? modelContext.save()
    }
}

// MARK: - Sub-view for the Row
// This is the key to fixing the "Type-check" error!
struct PlaylistSelectionRow: View {
    let song: Song
    let isAdded: Bool
    let onToggle: () -> Void

    var body: some View {
        // 1. Wrap everything in a Button to fix the ScrollView conflict
        Button(action: {
            // Haptic feedback
            #if os(iOS)
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            #endif
            onToggle()
        }) {
            HStack(spacing: 12) {
                SongArtworkView(song: song, size: 48)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.body)
                        .foregroundColor(.primary) // .primary is safer for dark/light mode
                    Text(song.artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer() // Fills space so the click works everywhere

                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundColor(isAdded ? .yellow : .gray)
                    .padding(.trailing, 4)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle()) // Ensures the whole area, including Spacer, is clickable
        }
        .buttonStyle(.plain) // 2. CRITICAL: Prevents the row from flashing gray/blue
        .listRowBackground(Color.clear)
    }
}

struct PlaylistDetailView: View {
    var playlist: Playlist
    @ObservedObject var playerManager: PlayerManager
    var allSongs: [Song]
    @Environment(\.modelContext) private var modelContext
    @State private var songToDelete: Song? = nil
    @State private var songToAddToPlaylist: Song? = nil
    @State private var showPlaylistToast = false
    @State private var playlistToastMessage = ""
    @State private var sortMode: PlaylistSortMode = .custom
    /// When sort is Custom, this holds the order so we can reorder and persist; synced from stored order when entering custom.
    @State private var customOrderedSongs: [Song] = []

    private func displayedSongs() -> [Song] {
        let raw = playlist.songs ?? []
        switch sortMode {
        case .aToZ:
            return raw.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .zToA:
            return raw.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .artist:
            return raw.sorted {
                let artistCompare = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                if artistCompare == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return artistCompare == .orderedAscending
            }
        case .album:
            return raw.sorted {
                let albumCompare = $0.album.localizedCaseInsensitiveCompare($1.album)
                if albumCompare == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return albumCompare == .orderedAscending
            }
        case .dateAdded:
            return orderedPlaylistSongsByDateAdded(playlist: playlist, songs: raw)
        case .custom:
            return orderedPlaylistSongs(playlist: playlist, songs: raw)
        }
    }

    private var playlistSongs: [Song] {
        sortMode == .custom ? customOrderedSongs : displayedSongs()
    }

    private func playlistSongRow(_ song: Song) -> some View {
        SongRow(
            song: song,
            isCurrent: playerManager.currentSong?.id == song.id,
            action: { playContextualSong(song, in: playlistSongs) },
            onQueueNext: { playerManager.addToQueue(song: song, playNext: true) },
            onAddToPlaylist: { songToAddToPlaylist = song },
            onRemoveFromPlaylist: { removeSongFromPlaylist(song) },
            onDelete: { confirmDelete(song) }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { removeSongFromPlaylist(song) } label: {
                Label("Remove from Playlist", systemImage: "minus.circle")
            }
            .tint(.orange)
            Button { playerManager.addToQueue(song: song, playNext: true) } label: {
                Label("Queue", systemImage: "text.badge.plus")
            }
            .tint(.blue)
            Button(role: .destructive) { confirmDelete(song) } label: {
                Label("Delete from Library", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private var playlistList: some View {
        let count = playlistSongs.count
        return List {
            Section {
                ForEach(playlistSongs) { song in
                    playlistSongRow(song)
                }
                .onMove(perform: movePlaylistSong)
                .moveDisabled(sortMode != .custom)
            } header: {
                Text("\(count) song\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if playerManager.currentSong != nil {
                Color.clear
                    .frame(height: 120)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }

    var body: some View {
        playlistList
            .navigationTitle(playlist.name)
        .listStyle(.plain)
        .onAppear {
            sortMode = getPlaylistSortMode(for: playlist)
            if sortMode == .custom {
                customOrderedSongs = orderedPlaylistSongs(playlist: playlist, songs: playlist.songs ?? [])
            }
        }
        .onChange(of: sortMode) { _, newMode in
            setPlaylistSortMode(for: playlist, mode: newMode)
            if newMode == .custom {
                customOrderedSongs = orderedPlaylistSongs(playlist: playlist, songs: playlist.songs ?? [])
            }
        }
        .onChange(of: playlist.songs?.count ?? 0) { _, _ in
            if sortMode == .custom {
                customOrderedSongs = orderedPlaylistSongs(playlist: playlist, songs: playlist.songs ?? [])
            }
        }
        .confirmationDialog(
            "Delete Song",
            isPresented: .constant(songToDelete != nil),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let song = songToDelete {
                    deleteSong(song)
                    songToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                songToDelete = nil
            }
        } message: {
            if let song = songToDelete {
                Text("Are you sure you want to delete \"\(song.title)\" by \(song.artist)? This will permanently delete the file from your device.")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    ForEach(PlaylistSortMode.allCases, id: \.self) { mode in
                        Button {
                            sortMode = mode
                            if mode == .custom {
                                customOrderedSongs = orderedPlaylistSongs(playlist: playlist, songs: playlist.songs ?? [])
                            }
                        } label: {
                            HStack {
                                Text(mode.rawValue)
                                if sortMode == mode { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .foregroundColor(.yellow)
                }
                
                Button {
                    if let randomSong = playlistSongs.randomElement() {
                        playerManager.play(song: randomSong, from: playlistSongs)
                        playerManager.enableShuffleAndShuffleQueue()
                    }
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundColor(.yellow)
                }
                
                NavigationLink(destination: AddSongsToPlaylistView(playlist: playlist, allSongs: allSongs)) {
                    Image(systemName: "plus")
                        .foregroundColor(.yellow)
                }
            }
            if sortMode == .custom {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                        .foregroundColor(.yellow)
                }
            }
        }
        .sheet(item: $songToAddToPlaylist) { song in
            PlaylistPickerSheet(
                song: song,
                onDismiss: {
                    songToAddToPlaylist = nil
                },
                onAddedToPlaylist: { playlistName in
                    playlistToastMessage = "Added to \(playlistName)"
                    withAnimation(.spring()) { showPlaylistToast = true }
                }
            )
            .presentationDetents([.medium, .large])
        }
        .overlay {
            if showPlaylistToast {
                VStack {
                    Spacer()
                    playlistToastView
                        .padding(.bottom, 90)
                }
                .zIndex(100)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
    }
    
    private var playlistToastView: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .foregroundColor(.primary)
            Text(playlistToastMessage)
                .font(.subheadline.bold())
                .foregroundColor(.primary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.spring()) { showPlaylistToast = false }
            }
        }
    }
    
    /// Reorder in Custom sort mode; updates local state and persisted order.
    private func movePlaylistSong(from source: IndexSet, to destination: Int) {
        customOrderedSongs.move(fromOffsets: source, toOffset: destination)
        setPlaylistOrderFromSongs(playlist: playlist, songs: customOrderedSongs)
    }

    /// Removes the song from this playlist only; does not delete from library.
    private func removeSongFromPlaylist(_ song: Song) {
        if playlist.songs == nil { playlist.songs = [] }
        playlist.songs?.removeAll { $0.id == song.id }
        removeSongFromPlaylistOrder(playlist: playlist, song: song)
        recordHistory(context: modelContext, action: "removed_from_playlist", songTitle: song.title, songArtist: song.artist, playlistName: playlist.name)
        try? modelContext.save()
    }
    
    // MARK: - Delete Song Function
    func confirmDelete(_ song: Song) {
        songToDelete = song
    }
    
    func deleteSong(_ song: Song) {
        // 1. Stop playback if this is the current song
        if playerManager.currentSong?.id == song.id {
            if playerManager.isPlaying {
                playerManager.togglePause()
            }
            playerManager.currentSong = nil
        }
        
        // 2. Remove from queues if present
        playerManager.manualQueue.removeAll { $0.id == song.id }
        playerManager.queue.removeAll { $0.id == song.id }
        
        // 3. Delete the file from filesystem
        let fileManager = FileManager.default
        let fileURL = song.url
        
        // Start accessing security-scoped resource if needed
        let accessGranted = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        // Check if file exists before trying to delete
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.removeItem(at: fileURL)
                #if DEBUG
                print("Successfully deleted file: \(fileURL.lastPathComponent)")
                #endif
            } catch {
                #if DEBUG
                print("Error deleting file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                #endif
                // Continue with database deletion even if file delete fails
                // (file might have been moved/deleted externally)
            }
        } else {
            #if DEBUG
            print("File does not exist at path: \(fileURL.path), removing from database only")
            #endif
        }
        
        // 4. Remove from all playlists (SwiftData relationship will handle this automatically)
        // But we should also explicitly remove it to be safe
        if let playlists = song.playlists {
            for playlist in playlists {
                playlist.songs?.removeAll { $0.id == song.id }
                removeSongFromPlaylistOrder(playlist: playlist, song: song)
            }
        }
        
        // 5. Record history then delete from SwiftData
        recordHistory(context: modelContext, action: "deleted_from_library", songTitle: song.title, songArtist: song.artist)
        modelContext.delete(song)
        
        // 6. Save the context
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("Error saving after delete: \(error.localizedDescription)")
            #endif
        }
    }

    // --- ADD THIS HELPER FUNCTION HERE ---
    private func playContextualSong(_ song: Song, in collection: [Song]) {
        if let currentIndex = collection.firstIndex(where: { $0.id == song.id }) {
            // Take a slice of the playlist for the queue
            let upperLimit = min(currentIndex + 20, collection.count)
            let queueSlice = Array(collection[currentIndex..<upperLimit])
            playerManager.play(song: song, from: queueSlice)
        }
    }
}

// MARK: - PLAYER UI
struct MiniPlayerView: View {
    @ObservedObject var playerManager: PlayerManager
    @ObservedObject var progressTracker: ProgressTracker
    var onTap: () -> Void

    var body: some View {
        if let song = playerManager.currentSong {
            VStack(spacing: 0) {
                // 1. Progress Bar
                ProgressView(value: progressTracker.currentTime, total: progressTracker.duration)
                    .progressViewStyle(.linear)
                    .tint(.yellow)
                    .frame(height: 2)

                HStack(spacing: 12) {
                    // 2. Artwork & Info (Wrapped in a Button to trigger the expand)
                    Button(action: onTap) {
                        HStack(spacing: 12) {
                            SongArtworkView(song: song, size: 40)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title).font(.subheadline).fontWeight(.medium).lineLimit(1)
                                Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            
                            // This pushes the "tap zone" to fill the whole left/middle area
                            Spacer()
                        }
                        .contentShape(Rectangle()) // Makes the entire Spacer area tappable
                    }
                    .buttonStyle(.plain) // Keeps text colors from turning blue
                    
                    // 3. Control Group
                    HStack(spacing: 20) {
                        Button { playerManager.previousTrack() } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 18))
                        }

                        Button {
                            #if os(iOS)
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred(intensity: 0.6)
                            #endif
                            playerManager.togglePause()
                        } label: {
                            Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 24))
                        }
                        .buttonStyle(.plain)

                        Button {
                            playerManager.nextTrack() // No parameter needed anymore!
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 18))
                        }
                    }
                    .foregroundStyle(.yellow)
                    .padding(.trailing, 8)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .background(.ultraThinMaterial)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
            .padding(.horizontal, 8)
        }
    }
}

struct LiveSlider: View {
    @ObservedObject var tracker: ProgressTracker
    var isScrubbing: (Bool) -> Void
    var onSeek: (Double) -> Void

    @State private var scrubValue: Double = 0
    @State private var internalIsScrubbing: Bool = false
    @State private var sliderValue: Double = 0
    @State private var lastUpdateTime: Date = Date()

    var body: some View {
        VStack {
            Slider(
                value: $sliderValue,
                in: 0...(tracker.duration > 0 ? tracker.duration : 1),
                onEditingChanged: { editing in
                    if editing {
                        // User started dragging - capture current time immediately
                        let currentTime = tracker.currentTime
                        scrubValue = currentTime
                        sliderValue = currentTime
                        internalIsScrubbing = true
                        isScrubbing(true)
                        lastUpdateTime = Date()
                    } else {
                        // User released - exit scrubbing mode and seek
                        internalIsScrubbing = false
                        isScrubbing(false)
                        onSeek(scrubValue)
                        lastUpdateTime = Date()
                    }
                }
            )
            .accentColor(.yellow)
            .onChange(of: sliderValue) { oldValue, newValue in
                // Update scrub value as user drags - only if we're scrubbing
                if internalIsScrubbing {
                    scrubValue = newValue
                    lastUpdateTime = Date()
                }
            }
            
            HStack {
                Text(formatTime(internalIsScrubbing ? scrubValue : tracker.currentTime))
                Spacer()
                Text(formatTime(tracker.duration))
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .onChange(of: tracker.currentTime) { oldValue, newValue in
            // Update slider value when not scrubbing
            // Only update if enough time has passed since last user interaction
            let timeSinceLastUpdate = Date().timeIntervalSince(lastUpdateTime)
            if !internalIsScrubbing && timeSinceLastUpdate > 0.05 {
                sliderValue = newValue
                scrubValue = newValue
            }
        }
        .onAppear {
            sliderValue = tracker.currentTime
            scrubValue = tracker.currentTime
            lastUpdateTime = Date()
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct FullPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    // Properties passed from parent
    let playerManager: PlayerManager
    let song: Song // Initial song (fallback)
    let allPlaylists: [Playlist] // Pass this in instead of @Query
    
    var onNavigateToArtist: ((String) -> Void)? = nil
    var onNavigateToAlbum: ((String) -> Void)? = nil

    @State private var dragOffset: CGFloat = 0
    @State private var showingQueue = false
    
    // Use currentSong from playerManager, fallback to initial song
    private var currentSong: Song {
        playerManager.currentSong ?? song
    }

    var body: some View {
        VStack(spacing: 20) {
            headerSection
            artworkSection
            
            Spacer()

            infoSection
            controlsSection // The Slider is in here
            
            Spacer()

            utilitySection
        }
        .offset(y: dragOffset)
        .background(backgroundView)
        .contentShape(Rectangle())
        .gesture(dismissGesture)
        .sheet(isPresented: $showingQueue) {
            queueSheet
        }
    }

    // MARK: - Extracted Sub-views
    
    private var headerSection: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.gray.opacity(0.5))
                .frame(width: 35, height: 5)
                .padding(.top, 8)
            
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.title2)
                        .foregroundColor(.gray)
                }
                Spacer()
            }
            .padding(.horizontal, 25)
        }
    }

    private var artworkSection: some View {
        ZStack {
            if let data = currentSong.artworkContainer?.data {
                // MEMORY OPTIMIZATION: Downscale large artwork for display
                ArtworkImageView(data: data, maxSize: 380)
            } else {
                ZStack {
                    Color.gray.opacity(0.2)
                    Image(systemName: "music.note")
                        .font(.system(size: 100))
                        .foregroundColor(.gray)
                }
            }
        }
        .frame(width: 380, height: 380)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.4), radius: 30, x: 0, y: 15)
        .scaleEffect(1.0 - (dragOffset / 1000))
        .padding(.top, 20)
        .id(currentSong.id) // Force view refresh when song changes
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(currentSong.title)
                .font(.title2).bold()
                .foregroundColor(.white)
            
            Text(currentSong.artist)
                .font(.title3)
                .foregroundColor(.yellow)
                .onTapGesture {
                    onNavigateToArtist?(currentSong.artist)
                }
            
            // Suggestion: Add Album Navigation too!
            Text(currentSong.album)
                .font(.subheadline)
                .foregroundColor(.gray)
                .onTapGesture {
                    onNavigateToAlbum?(currentSong.album)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 35)
        .id(currentSong.id) // Force view refresh when song changes
    }

    private var controlsSection: some View {
        VStack(spacing: 25) {
            LiveSlider(
                tracker: playerManager.progressTracker,
                isScrubbing: { editing in playerManager.isScrubbing = editing },
                onSeek: { time in playerManager.seek(to: time) }
            )
            .padding(.horizontal, 25)
            
            HStack(spacing: 50) {
                // Previous Track
                Button { playerManager.previousTrack() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 28)) // Fixed size
                }
                .frame(width: 44, height: 44) // Consistent tap area
                
                // Play/Pause (The "Centerpiece")
                PlayPauseButton(playerManager: playerManager)
                    .font(.system(size: 54)) // Keep this one larger
                    .frame(width: 70, height: 70)
                
                // Next Track
                Button { playerManager.nextTrack() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 28)) // Fixed size to match backward
                }
                .frame(width: 44, height: 44) // Consistent tap area
            }
            .foregroundColor(.white)
        }
    }

    private var utilitySection: some View {
        HStack {
            Button(action: { playerManager.toggleShuffle() }) {
                Image(systemName: "shuffle")
                    .font(.title2)
                    .foregroundColor(playerManager.isShuffleOn ? .yellow : .white)
            }
            Spacer()
            Menu {
                ForEach(allPlaylists) { playlist in
                    Button(playlist.name) { addToPlaylist(playlist) }
                }
            } label: {
                Image(systemName: "plus.circle").font(.title2)
            }
            Spacer()
            Button { showingQueue.toggle() } label: {
                Image(systemName: "list.bullet").font(.title2)
            }
        }
        .foregroundColor(.yellow)
        .padding(.horizontal, 40)
        .padding(.bottom, 30)
    }

    private var backgroundView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let data = currentSong.artworkContainer?.data {
                // MEMORY OPTIMIZATION: Use smaller image for blur background (blur hides detail anyway)
                ArtworkImageView(data: data, maxSize: 200)
                    .blur(radius: 60)
                    .opacity(0.3)
                    .ignoresSafeArea()
            }
        }
        .id(currentSong.id) // Force view refresh when song changes
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 5) // Lower distance for faster recognition
            .onChanged { value in
                // 1. Calculate the "Angle" of the swipe
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                
                // 2. STICKY FIX: Only move the sheet if the swipe is CLEARLY vertical.
                // If horizontal movement is high, we assume they are scrubbing.
                if vertical > (horizontal * 2) && value.translation.height > 0 {
                    dragOffset = value.translation.height
                } else {
                    // If they move sideways at all, "lock" the sheet at 0
                    dragOffset = 0
                }
            }
            .onEnded { value in
                if value.translation.height > 150 {
                    withAnimation(.spring()) { dismiss() }
                } else {
                    withAnimation(.spring()) { dragOffset = 0 }
                }
            }
    }
    
    private var queueSheet: some View {
        NavigationStack {
            List {
                if let current = playerManager.currentSong {
                    Section("Now Playing") {
                        QueueRow(song: current)
                            .listRowBackground(Color.yellow.opacity(0.1))
                    }
                }
                Section("Up Next") {
                    ForEach(Array(playerManager.upNextDisplayList.enumerated()), id: \.element.id) { index, song in
                        QueueRow(song: song) {
                            playerManager.playFromQueue(at: index)
                        }
                    }
                    .onMove(perform: playerManager.moveQueueItem)
                    .onDelete(perform: playerManager.removeQueueItem)
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { showingQueue = false }
                }
            }
        }
    }

    private func addToPlaylist(_ playlist: Playlist) {
        if let songs = playlist.songs {
            if !songs.contains(where: { $0.id == currentSong.id }) {
                playlist.songs?.append(currentSong)
                appendSongToPlaylistOrder(playlist: playlist, song: currentSong)
                recordHistory(context: modelContext, action: "added_to_playlist", songTitle: currentSong.title, songArtist: currentSong.artist, playlistName: playlist.name)
            }
        } else {
            playlist.songs = [currentSong]
            appendSongToPlaylistOrder(playlist: playlist, song: currentSong)
            recordHistory(context: modelContext, action: "added_to_playlist", songTitle: currentSong.title, songArtist: currentSong.artist, playlistName: playlist.name)
        }
        try? modelContext.save()
    }
}

struct PlayPauseButton: View {
    @ObservedObject var playerManager: PlayerManager
    
    var body: some View {
        Button {
            #if os(iOS)
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred(intensity: 0.6)
            #endif
            playerManager.togglePause()
        } label: {
            Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 80))
        }
        .buttonStyle(.plain)
    }
}

struct QueueRow: View {
    let song: Song
    let onTap: (() -> Void)?
    
    init(song: Song, onTap: (() -> Void)? = nil) {
        self.song = song
        self.onTap = onTap
    }

    var body: some View {
        Button(action: {
            onTap?()
        }) {
            HStack {
                Text(song.title)
                    .lineLimit(1)
                Spacer()
                Text(song.artist)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AlbumDetailView: View {
    let album: String
    let allSongs: [Song]
    let allPlaylists: [Playlist]
    @ObservedObject var playerManager: PlayerManager
    @Binding var selectedTab: Int
    @Binding var searchQuery: String
    let modelContext: ModelContext
    @Binding var songToAddToPlaylist: Song?
    @Binding var artistToNavigate: String?
    @State private var songToDelete: Song? = nil
    @State private var selectedArtist: ArtistNavigationItem? = nil

    var albumSongs: [Song] {
        allSongs.filter { $0.album == album }
    }
    
    // Get artist name from first song in album
    var albumArtist: String {
        albumSongs.first?.artist ?? "Unknown Artist"
    }
    
    // Get artwork from first song in album
    var albumArtwork: (data: Data?, song: Song?) {
        if let firstSong = albumSongs.first,
           let artworkData = firstSong.artworkContainer?.data {
            return (artworkData, firstSong)
        }
        return (nil, albumSongs.first)
    }
    
    @ViewBuilder
    private var albumArtworkView: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                // Album name - larger than artist, left-aligned, appears under back arrow
                Text(album)
                    .font(.title)
                    .fontWeight(.bold)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                
                // Artist name (tappable) - smaller than album, left-aligned
                // Use NavigationLink to maintain navigation stack
                Button {
                    selectedArtist = ArtistNavigationItem(artist: albumArtist)
                } label: {
                    Text(albumArtist)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundColor(.yellow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 8)
                
                // Centered artwork
                Group {
                    if let artworkData = albumArtwork.data {
                        // MEMORY OPTIMIZATION: Use downscaled image component
                        ArtworkImageView(data: artworkData, maxSize: geometry.size.width * 0.67)
                    } else {
                        ZStack {
                            Color.gray.opacity(0.2)
                            Image(systemName: "music.note")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                        }
                    }
                }
                .frame(width: geometry.size.width * 0.67)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity) // Centers the artwork
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
        }
        .frame(height: 450) // Increased height to accommodate album name
    }
    
    @ViewBuilder
    private func albumSongRow(song: Song) -> some View {
        SongRow(
            song: song,
            isCurrent: playerManager.currentSong?.id == song.id,
            action: {
                playerManager.play(song: song, from: albumSongs)
            },
            showIndexGap: false,
            onQueueNext: {
                playerManager.addToQueue(song: song, playNext: true)
            },
            onGoToArtist: {
                artistToNavigate = song.artist
                selectedTab = 1
            },
            onGoToAlbum: {
                // Already on album page, do nothing
            },
            onAddToPlaylist: {
                songToAddToPlaylist = song
            },
            onDelete: {
                confirmDelete(song)
            }
        )
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                playerManager.addToQueue(song: song, playNext: true)
            } label: {
                Label("Queue", systemImage: "text.badge.plus")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmDelete(song)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }
    
    // MARK: - Delete Song Function
    func confirmDelete(_ song: Song) {
        songToDelete = song
    }
    
    func deleteSong(_ song: Song) {
        // 1. Stop playback if this is the current song
        if playerManager.currentSong?.id == song.id {
            if playerManager.isPlaying {
                playerManager.togglePause()
            }
            playerManager.currentSong = nil
        }
        
        // 2. Remove from queues if present
        playerManager.manualQueue.removeAll { $0.id == song.id }
        playerManager.queue.removeAll { $0.id == song.id }
        
        // 3. Delete the file from filesystem
        let fileManager = FileManager.default
        let fileURL = song.url
        
        // Start accessing security-scoped resource if needed
        let accessGranted = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        // Check if file exists before trying to delete
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.removeItem(at: fileURL)
                #if DEBUG
                print("Successfully deleted file: \(fileURL.lastPathComponent)")
                #endif
            } catch {
                #if DEBUG
                print("Error deleting file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                #endif
                // Continue with database deletion even if file delete fails
                // (file might have been moved/deleted externally)
            }
        } else {
            #if DEBUG
            print("File does not exist at path: \(fileURL.path), removing from database only")
            #endif
        }
        
        // 4. Remove from all playlists (SwiftData relationship will handle this automatically)
        // But we should also explicitly remove it to be safe
        if let playlists = song.playlists {
            for playlist in playlists {
                playlist.songs?.removeAll { $0.id == song.id }
                removeSongFromPlaylistOrder(playlist: playlist, song: song)
            }
        }
        
        // 5. Record history then delete from SwiftData
        recordHistory(context: modelContext, action: "deleted_from_library", songTitle: song.title, songArtist: song.artist)
        modelContext.delete(song)
        
        // 6. Save the context
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("Error saving after delete: \(error.localizedDescription)")
            #endif
        }
    }

    var body: some View {
        List {
            // Full-size artwork header
            Section {
                albumArtworkView
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            
            // Tracklist
            Section {
                ForEach(albumSongs) { song in
                    albumSongRow(song: song)
                }
            }
            
            // Add bottom padding so mini player doesn't cover last song
            Color.clear
                .frame(height: 80)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Hide the default title since we're showing it in the content
            ToolbarItem(placement: .principal) {
                Text("")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if let randomSong = albumSongs.randomElement() {
                        playerManager.play(song: randomSong, from: albumSongs)
                        playerManager.enableShuffleAndShuffleQueue()
                    }
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundColor(.yellow)
                }
            }
        }
        .navigationDestination(item: $selectedArtist) { item in
            ArtistDetailView(
                artist: item.artist,
                allSongs: allSongs,
                allPlaylists: allPlaylists,
                playerManager: playerManager,
                selectedTab: $selectedTab,
                searchQuery: $searchQuery,
                modelContext: modelContext,
                songToAddToPlaylist: $songToAddToPlaylist,
                albumToNavigate: Binding<String?>(
                    get: { album },
                    set: { _ in }
                )
            )
        }
        .listStyle(.plain)
        .confirmationDialog(
            "Delete Song",
            isPresented: .constant(songToDelete != nil),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let song = songToDelete {
                    deleteSong(song)
                    songToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                songToDelete = nil
            }
        } message: {
            if let song = songToDelete {
                Text("Are you sure you want to delete \"\(song.title)\" by \(song.artist)? This will permanently delete the file from your device.")
            }
        }
    }
}

// MEMORY OPTIMIZATION: Reusable component for downscaled artwork images
struct ArtworkImageView: View {
    let data: Data
    let maxSize: CGFloat
    @State private var image: UIImage?
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.clear
                    .onAppear {
                        loadAndDownscale()
                    }
            }
        }
    }
    
    private func loadAndDownscale() {
        #if canImport(UIKit)
        Task { @MainActor in
            guard let originalImage = UIImage(data: data) else { return }
            let size = originalImage.size
            let scale = min(maxSize / size.width, maxSize / size.height, 1.0)
            
            if scale < 1.0 {
                let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
                UIGraphicsBeginImageContextWithOptions(scaledSize, false, 1.0)
                defer { UIGraphicsEndImageContext() }
                originalImage.draw(in: CGRect(origin: .zero, size: scaledSize))
                image = UIGraphicsGetImageFromCurrentImageContext()
            } else {
                image = originalImage
            }
        }
        #endif
    }
}

struct SongArtworkView: View {
    let song: Song
    var size: CGFloat = 50
    
    // MEMORY OPTIMIZATION: Cache downscaled images and only load when visible
    @State private var cachedImage: UIImage?
    @State private var artworkData: Data?
    @State private var hasAppeared = false
    
    // Extract artwork data in initializer to avoid accessing invalidated objects later
    init(song: Song, size: CGFloat = 50) {
        self.song = song
        self.size = size
        // Extract data immediately when view is created, before object might be invalidated
        _artworkData = State(initialValue: {
            // Safely extract data by accessing it once at initialization
            if let container = song.artworkContainer {
                return container.data
            }
            return nil
        }())
    }
    
    var body: some View {
        ZStack {
            // Check if data exists, otherwise show placeholder
            if let image = cachedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let data = artworkData {
                // Load and downscale image
                Color.clear
                    .onAppear {
                        hasAppeared = true
                        loadAndDownscaleImage(data: data, targetSize: size)
                    }
                    .onChange(of: song.id) { oldId, newId in
                        // Reload image when song changes
                        cachedImage = nil
                        // Re-extract data when song changes - safely access the new song's artwork
                        // The new song should be valid since we're responding to its id change
                        artworkData = nil
                        // Use a local variable to safely extract data
                        let container = song.artworkContainer
                        artworkData = container?.data
                        if let newData = artworkData {
                            loadAndDownscaleImage(data: newData, targetSize: size)
                        }
                    }
            } else {
                // Show placeholder if no artwork data
                ZStack {
                    Color.gray.opacity(0.2)
                    Image(systemName: "music.note")
                        .foregroundColor(.gray)
                }
                .onAppear {
                    hasAppeared = true
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onChange(of: song.id) { oldId, newId in
            // Reset cache when song changes (handles case where artwork data might change)
            cachedImage = nil
            // Re-extract data when song changes - safely access the new song's artwork
            artworkData = nil
            let container = song.artworkContainer
            artworkData = container?.data
        }
    }
    
    // MEMORY OPTIMIZATION: Downscale images to target size
    private func loadAndDownscaleImage(data: Data, targetSize: CGFloat) {
        #if canImport(UIKit)
        Task { @MainActor in
            guard let image = UIImage(data: data) else { return }
            
            // Downscale to target size + 20% buffer for retina displays
            let targetSizeWithBuffer = targetSize * 1.2
            let imageSize = image.size
            let scale = min(targetSizeWithBuffer / imageSize.width, targetSizeWithBuffer / imageSize.height, 1.0)
            
            // Only downscale if needed
            if scale < 1.0 {
                let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                UIGraphicsBeginImageContextWithOptions(scaledSize, false, 1.0)
                defer { UIGraphicsEndImageContext() }
                image.draw(in: CGRect(origin: .zero, size: scaledSize))
                cachedImage = UIGraphicsGetImageFromCurrentImageContext()
            } else {
                cachedImage = image
            }
        }
        #endif
    }
}

struct PlaylistPickerSheet: View {
    let song: Song
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    @Query(sort: \Folder.sortOrder) private var allFolders: [Folder]
    let onDismiss: () -> Void
    var onAddedToPlaylist: ((String) -> Void)? = nil
    
    /// Which folders are expanded (collapsed when not in set). Start empty = all collapsed for easier scrolling.
    @State private var expandedFolderIDs: Set<PersistentIdentifier> = []
    
    private func isExpanded(_ folder: Folder) -> Bool {
        expandedFolderIDs.contains(folder.persistentModelID)
    }
    
    private func bindingForFolder(_ folder: Folder) -> Binding<Bool> {
        Binding(
            get: { isExpanded(folder) },
            set: { new in
                if new { expandedFolderIDs.insert(folder.persistentModelID) }
                else { expandedFolderIDs.remove(folder.persistentModelID) }
            }
        )
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                if playlists.isEmpty && allFolders.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text("No Playlists")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Create a playlist in the Playlists tab first")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else {
                    List {
                        // Top-level playlists
                        let topLevelPlaylists = playlists.filter { $0.parentFolder == nil }
                        if !topLevelPlaylists.isEmpty {
                            Section {
                                ForEach(topLevelPlaylists) { playlist in
                                    playlistRow(for: playlist, folderPath: nil)
                                }
                            }
                        }
                        
                        // Collapsible folders with their playlists and sub-folders
                        let topLevelFolders = allFolders.filter { $0.parent == nil }
                        ForEach(topLevelFolders.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.persistentModelID) { folder in
                            folderDisclosureGroup(folder: folder)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        onDismiss()
                    }
                }
            }
        }
    }
    
    /// One collapsible row per folder: label shows folder name; content shows playlists and nested sub-folders.
    private func folderDisclosureGroup(folder: Folder) -> some View {
        let folderPlaylists = playlists.filter { $0.parentFolder?.persistentModelID == folder.persistentModelID }
        let subFolders = folder.subFolders.sorted(by: { $0.sortOrder < $1.sortOrder })
        
        return DisclosureGroup(isExpanded: bindingForFolder(folder)) {
            // Playlists directly in this folder
            ForEach(folderPlaylists) { playlist in
                playlistRow(for: playlist, folderPath: folderPath(for: folder))
            }
            // Sub-folders (each is a collapsible DisclosureGroup)
            ForEach(subFolders, id: \.persistentModelID) { sub in
                AnyView(folderDisclosureGroup(folder: sub))
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 16))
                Text(folder.name)
                    .font(.headline)
            }
        }
    }
    
    private func isPlaylistInSubFolder(_ playlistFolder: Folder, parentFolder: Folder) -> Bool {
        var current: Folder? = playlistFolder.parent
        while let folder = current {
            if folder.persistentModelID == parentFolder.persistentModelID {
                return true
            }
            current = folder.parent
        }
        return false
    }
    
    @ViewBuilder
    private func playlistRow(for playlist: Playlist, folderPath: String?) -> some View {
        Button {
            addToPlaylist(playlist)
        } label: {
            HStack(spacing: 12) {
                // Playlist icon
                Image(systemName: "music.note.list")
                    .foregroundColor(.yellow)
                    .font(.system(size: 16))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .foregroundColor(.primary)
                    
                    if let folderPath = folderPath {
                        Text(folderPath)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if let songs = playlist.songs, songs.contains(where: { $0.id == song.id }) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.yellow)
                }
            }
        }
    }
    
    private func folderPath(for folder: Folder) -> String {
        var pathComponents: [String] = []
        var current: Folder? = folder
        while let folder = current {
            pathComponents.insert(folder.name, at: 0)
            current = folder.parent
        }
        return pathComponents.joined(separator: " › ")
    }
    
    private func addToPlaylist(_ playlist: Playlist) {
        let wasAlreadyInPlaylist = playlist.songs?.contains(where: { $0.id == song.id }) ?? false
        
        if !wasAlreadyInPlaylist {
            if playlist.songs != nil {
                playlist.songs?.append(song)
            } else {
                playlist.songs = [song]
            }
            appendSongToPlaylistOrder(playlist: playlist, song: song)
            recordHistory(context: modelContext, action: "added_to_playlist", songTitle: song.title, songArtist: song.artist, playlistName: playlist.name)
            try? modelContext.save()
            onAddedToPlaylist?(playlist.name)
        }
        onDismiss()
    }
}
