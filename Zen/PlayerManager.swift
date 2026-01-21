import Foundation
import AVFoundation
import Combine
import SwiftUI
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

class ProgressTracker: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
}

class PlayerManager: NSObject, ObservableObject {
    private var avPlayer: AVPlayer?
    private var lastClickTime: TimeInterval = 0
    @Published var isPlaying = false
    @Published var currentSong: Song?
    @Published var isScrubbing = false
    @Published var isShuffleOn = false
    @Published var currentIndex: Int = 0
    @Published var history: [Song] = []
    @Published var playedIDs: Set<URL> = []
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""
    private var toastTimer: DispatchWorkItem?
    
    private var durationWorkItem: DispatchWorkItem?
    private var currentAccessingURL: URL? // Track the currently accessed security-scoped resource
    private var playerItemStatusObserver: NSKeyValueObservation? // MEMORY FIX: Store observer to clean up
    
    // MEMORY OPTIMIZATION: Don't store full library in memory
    // Instead, we'll pass the library when needed
    // Note: We can't use weak references with arrays (value types), so we'll just not store it
    private var currentLibraryReference: [Song]?
    
    // Split Queues
    @Published var queue: [Song] = []         // The "Contextual" list
    @Published var manualQueue: [Song] = []   // The "User-added" list
    
    var upNextDisplayList: [Song] {
        // 1. Combine the user's manual "Play Next" choices
        // 2. Add the "Contextual" queue (which now starts from the next song)
        let combined = manualQueue + queue
        
        return combined
    }
    
    let progressTracker = ProgressTracker()
    private var timer: AnyCancellable?
    
    override init() {
        super.init()
        setupRemoteCommandCenter()
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default, policy: .longFormAudio)
        #endif
    }

    // MARK: - Core Playback Logic
    
    func play(song: Song, from allSongs: [Song], preserveQueue: Bool = false) {
        // 1. Activate Session (synchronously to ensure it's ready)
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to activate audio session: \(error)")
        }
        #endif
        
        // MEMORY OPTIMIZATION: Don't store full library, just keep a weak reference
        self.currentLibraryReference = allSongs
        self.currentSong = song
        
        // Don't clear manual queue - preserve "Play Next" items when playing a new song
        // The manual queue will be consumed naturally as songs play

        // 2. The Logic: Split the library (unless we're preserving the queue)
        if !preserveQueue {
            if let targetIndex = allSongs.firstIndex(where: { $0.id == song.id }) {
                
                // --- HISTORY (Everything before the tapped song) ---
                let pastSongs = allSongs[..<targetIndex]
                self.history = Array(pastSongs.reversed())
                
                // --- QUEUE (Everything AFTER the tapped song) ---
                // We start from targetIndex + 1 because 'song' is already in currentSong
                let nextIndex = targetIndex + 1
                
                if nextIndex < allSongs.count {
                    // Buffer the next 100 songs
                    self.queue = Array(allSongs[nextIndex...].prefix(100))
                } else {
                    // Tapped the last song in the list
                    self.queue = []
                }
                
                self.currentIndex = 0
            } else {
                // Fallback: If song isn't in the provided list
                self.history = []
                self.queue = []
                self.currentIndex = 0
            }
        }
        
        // 3. Load the audio
        loadAndPlay(song)
    }
    
    private var isTaskLoading = false

    private func loadAndPlay(_ song: Song) {
        // 1. Immediate Cleanup
        durationWorkItem?.cancel()
        avPlayer?.pause()
        
        // MEMORY FIX: Clean up previous observer
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
        
        // Stop accessing the previous security-scoped resource if any
        if let previousURL = currentAccessingURL {
            previousURL.stopAccessingSecurityScopedResource()
            currentAccessingURL = nil
        }
        
        // 2. Prevent overlapping loads
        guard !isTaskLoading else { 
            print("DEBUG: Already loading, skipping")
            return 
        }
        isTaskLoading = true
        
        var url = song.url
        print("DEBUG: Attempting to play song: \(song.title)")
        print("DEBUG: Original URL: \(url)")
        print("DEBUG: URL path: \(url.path)")
        print("DEBUG: URL absoluteString: \(url.absoluteString)")
        
        // Try to fix potential URL encoding issues
        // If the URL has encoded characters, try creating a new one from the Documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let filename = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let alternativeURL = documentsPath.appendingPathComponent(filename)
        
        print("DEBUG: Trying alternative URL with decoded filename: \(alternativeURL.path)")
        
        // Use the alternative URL if it's different (might fix encoding issues)
        // AVPlayer will handle errors if the file doesn't exist
        url = alternativeURL
        print("DEBUG: Using URL: \(url.path)")
        
        // Only use security-scoped resource access if the URL requires it
        // Files in Documents directory typically don't need this
        let isAccessing = url.startAccessingSecurityScopedResource()
        
        // Store the currently accessing URL so we can stop it later
        if isAccessing {
            currentAccessingURL = url
            print("DEBUG: Started security-scoped resource access")
        } else {
            // If security-scoped access isn't needed, clear any previous access
            currentAccessingURL = nil
            print("DEBUG: Security-scoped resource access not needed")
        }
        
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        
        // Reset Progress State
        // Don't set isPlaying here - wait until playback actually starts
        progressTracker.currentTime = 0
        progressTracker.duration = 0
        
        // 4. Thread-Safe Player Update
        if avPlayer == nil {
            avPlayer = AVPlayer(playerItem: playerItem)
            print("DEBUG: Created new AVPlayer")
        } else {
            avPlayer?.replaceCurrentItem(with: playerItem)
            print("DEBUG: Replaced current item")
        }
        
        // MEMORY OPTIMIZATION: Store observer to clean up properly
        // Cancel any existing observer first
        playerItemStatusObserver?.invalidate()
        
        // Observe player item status and play when ready
        playerItemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            print("DEBUG: Player item status changed to: \(item.status.rawValue)")
            
            if item.status == .readyToPlay {
                print("DEBUG: Player item is ready to play, starting playback")
                DispatchQueue.main.async {
                    self.avPlayer?.play()
                    // Update isPlaying based on actual player rate
                    self.isPlaying = (self.avPlayer?.rate ?? 0) > 0
                    if self.avPlayer?.rate == 0 {
                        print("WARNING: Player rate is 0 after play() call")
                        if let error = self.avPlayer?.error {
                            print("WARNING: Player error: \(error.localizedDescription)")
                        }
                    } else {
                        print("DEBUG: Playback started successfully, rate: \(self.avPlayer?.rate ?? 0)")
                    }
                    self.playerItemStatusObserver?.invalidate()
                    self.playerItemStatusObserver = nil
                }
            } else if item.status == .failed {
                print("ERROR: Player item failed to load")
                if let error = item.error {
                    print("ERROR: Error description: \(error.localizedDescription)")
                    print("ERROR: Error: \(error)")
                } else {
                    print("ERROR: Unknown error")
                }
                self.playerItemStatusObserver?.invalidate()
                self.playerItemStatusObserver = nil
            }
        }
        
        setupNowPlaying(song: song)
        startTimer()
        
        // 5. Async Metadata Loading
        Task {
            do {
                // iOS 18+ Metadata loading
                let duration = try await asset.load(.duration)
                let seconds = CMTimeGetSeconds(duration)
                
                if seconds.isFinite && seconds > 0 {
                    await MainActor.run {
                        self.progressTracker.duration = seconds
                        self.setupNowPlaying(song: song)
                    }
                }
            } catch {
                print("Failed to load duration: \(error)")
            }
            
            // 6. ALWAYS release the loading lock
            await MainActor.run {
                self.isTaskLoading = false
            }
        }
    }

    // MARK: - Queue Management
    
    func addToQueue(song: Song, playNext: Bool) {
        DispatchQueue.main.async {
            self.objectWillChange.send()
            
            if playNext {
                self.manualQueue.insert(song, at: 0)
                self.triggerToast(message: "Playing Next: \(song.title)")
            } else {
                self.manualQueue.append(song)
                self.triggerToast(message: "Added to Queue")
            }
            
            if self.currentSong == nil {
                self.play(song: song, from: [song])
                if !self.manualQueue.isEmpty {
                    self.manualQueue.removeFirst()
                }
            }
        }
    }

    // Play a song from the queue, keeping songs after it
    func playFromQueue(at index: Int) {
        let displayList = upNextDisplayList
        
        guard index < displayList.count else { return }
        
        let selectedSong = displayList[index]
        
        // Find which queue the song is in (manual or contextual)
        let manualCount = manualQueue.count
        let isInManualQueue = index < manualCount
        
        // Store the remaining songs after the selected one
        var remainingManualQueue: [Song] = []
        var remainingQueue: [Song] = []
        
        if isInManualQueue {
            // Song is in manual queue
            // Remove everything before it, keep everything after
            if index > 0 {
                manualQueue.removeFirst(index)
            }
            // Store remaining songs (including selected, which we'll remove)
            remainingManualQueue = Array(manualQueue)
            if !remainingManualQueue.isEmpty && remainingManualQueue.first?.id == selectedSong.id {
                remainingManualQueue.removeFirst()
            }
            // Clear contextual queue since we're jumping to manual queue
            remainingQueue = []
        } else {
            // Song is in contextual queue
            let contextualIndex = index - manualCount
            
            // Clear manual queue (we're jumping past it)
            remainingManualQueue = []
            
            // Remove everything before the selected song, keep everything after
            if contextualIndex > 0 {
                queue.removeFirst(contextualIndex)
            }
            // Store remaining songs (including selected, which we'll remove)
            remainingQueue = Array(queue)
            if !remainingQueue.isEmpty && remainingQueue.first?.id == selectedSong.id {
                remainingQueue.removeFirst()
            }
        }
        
        // Update queues to only contain songs after the selected one
        manualQueue = remainingManualQueue
        queue = remainingQueue
        
        // Play the selected song with preserveQueue=true to keep our queue
        let library = currentLibraryReference ?? []
        play(song: selectedSong, from: library.isEmpty ? displayList : library, preserveQueue: true)
    }
    
    func nextTrack(allSongs: [Song]? = nil) {
        // MEMORY OPTIMIZATION: Use provided library or current reference
        let library = allSongs ?? self.currentLibraryReference ?? []
        
        // Debounce check
        let now = Date().timeIntervalSince1970
        guard now - lastClickTime > 0.3 else { return }
        lastClickTime = now
        
        // 1. History & Cleanup
        // We record the song that is FINISHING into history
        if let current = currentSong {
            history.insert(current, at: 0)
            if history.count > 50 { history.removeLast() }
            playedIDs.insert(current.id)
        }
        
        avPlayer?.pause()

        // 2. PRIORITY 1: Manual Queue (User "Play Next")
        if !manualQueue.isEmpty {
            let nextSong = manualQueue.removeFirst()
            self.currentSong = nextSong
            loadAndPlay(nextSong)
            return // Exit: we don't touch contextual queue if user had a manual one
        }
        
        // 3. PRIORITY 2: Contextual Queue
        if let nextLibrarySong = queue.first {
            // Pop the song from the queue because it is now becoming the 'currentSong'
            queue.removeFirst()
            
            self.currentSong = nextLibrarySong
            loadAndPlay(nextLibrarySong)
            
            // Refill the buffer from the master library to keep the "sliding window" full
            refillQueueBuffer(from: library)
        } else {
            // 4. Handle End of Queue
            handleEndOfQueue(library: library)
        }
    }

    private func handleEndOfQueue(library: [Song]) {
        if isShuffleOn {
            playedIDs.removeAll()
            toggleShuffle()
        } else {
            let finalLibrary = library.isEmpty ? (currentLibraryReference ?? []) : library
            if let firstSong = finalLibrary.first {
                self.history = []
                self.queue = Array(finalLibrary.prefix(100))
                self.currentSong = firstSong
                loadAndPlay(firstSong)
            } else {
                isPlaying = false
                currentSong = nil
            }
        }
    }

    // MARK: - Controls
    
    func togglePause() {
        guard let player = avPlayer else { return }
        
        // Check actual player state, not just our flag
        let isActuallyPlaying = player.rate > 0
        
        if isActuallyPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        
        updatePlaybackRate()
    }

    private func updatePlaybackRate() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func previousTrack() {
        let now = Date().timeIntervalSince1970
        guard now - lastClickTime > 0.3 else { return }
        lastClickTime = now

        // 1. Standard Behavior: If we are deep into a song, just restart it.
        if progressTracker.currentTime > 3.0 {
            seek(to: 0)
            return
        }

        if isShuffleOn {
            // 2. SHUFFLE ON: Navigate back using the History Array
            if let prevSong = history.first {
                history.removeFirst()
                
                // Put current back in queue so 'Next' returns to where we were
                if let current = currentSong {
                        self.queue.insert(current, at: 0)
                    }
                    
                    playedIDs.remove(prevSong.id) // Allow it to be shuffled again later
                    self.currentSong = prevSong
                    loadAndPlay(prevSong)
            } else {
                seek(to: 0)
            }
        } else {
            // 3. SHUFFLE OFF: Navigate back Alphabetically (Perpetual Back)
            if let current = currentSong,
               let library = currentLibraryReference,
               let currentIndex = library.firstIndex(where: { $0.id == current.id }) {
                
                let previousIndex = currentIndex - 1
                
                if previousIndex >= 0 {
                    let prevSong = library[previousIndex]
                    
                    // Update the queue to match the new alphabetical remainder
                    // (This ensures hitting 'Next' moves you forward from this new point)
                    self.queue = Array(library[currentIndex...].prefix(100))
                    
                    self.currentSong = prevSong
                    loadAndPlay(prevSong)
                } else {
                    // We are at Song 'A'
                    seek(to: 0)
                }
            }
        }
    }
    
    func seek(to time: Double) {
        avPlayer?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        progressTracker.currentTime = time
    }

    private func startTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self,
                      let p = self.avPlayer,
                      let currentItem = p.currentItem,
                      !self.isScrubbing else { return }
                
                let current = CMTimeGetSeconds(p.currentTime())
                let duration = currentItem.duration
                let dur = (duration.isNumeric) ? CMTimeGetSeconds(duration) : self.progressTracker.duration
                
                self.progressTracker.currentTime = current
                
                // End of song detection
                if dur > 1.0 && current.isFinite && dur.isFinite {
                    if current >= dur - 0.2 { // Slight buffer to ensure transition
                        self.nextTrack()
                    }
                }
            }
    }

    func setupNowPlaying(song: Song) {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = song.album
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = progressTracker.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = progressTracker.currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        // MEMORY OPTIMIZATION: Downscale artwork for Now Playing (300x300 is sufficient)
        if let data = song.artworkContainer?.data {
            #if canImport(UIKit)
            if let image = UIImage(data: data) {
                // Downscale to 300x300 max to save memory
                let maxSize: CGFloat = 300
                let size = image.size
                let scale = min(maxSize / size.width, maxSize / size.height, 1.0)
                let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
                
                UIGraphicsBeginImageContextWithOptions(scaledSize, false, 1.0)
                defer { UIGraphicsEndImageContext() }
                image.draw(in: CGRect(origin: .zero, size: scaledSize))
                if let scaledImage = UIGraphicsGetImageFromCurrentImageContext() {
                    let artwork = MPMediaItemArtwork(boundsSize: scaledSize) { _ in
                        return scaledImage
                    }
                    nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                }
            }
            #endif
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [unowned self] _ in self.togglePause(); return .success }
        commandCenter.pauseCommand.addTarget { [unowned self] _ in self.togglePause(); return .success }
        commandCenter.nextTrackCommand.addTarget { [unowned self] _ in self.nextTrack(); return .success }
        commandCenter.previousTrackCommand.addTarget { [unowned self] _ in self.previousTrack(); return .success }
        
        // Allow scrubbing from the lock screen
        commandCenter.changePlaybackPositionCommand.addTarget { [unowned self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self.seek(to: e.positionTime)
                return .success
            }
            return .commandFailed
        }
    }

    func toggleShuffle() {
        isShuffleOn.toggle()
        
        // 1. Capture snapshots immediately
        let currentId = currentSong?.id
        let librarySnapshot = self.currentLibraryReference ?? []
        
        Task(priority: .userInitiated) {
            var processedQueue: [Song] = []
            
            if isShuffleOn {
                // 1. Filter the library to find songs that haven't been played yet
                var unplayedPool = librarySnapshot.filter { !playedIDs.contains($0.id) }
                
                // 2. If the pool is empty (or only contains the current song), reset the history
                // This allows the shuffle to "start fresh" once the whole library has been heard
                if unplayedPool.isEmpty || (unplayedPool.count == 1 && unplayedPool.first?.id == currentId) {
                    playedIDs.removeAll()
                    unplayedPool = librarySnapshot
                }
                
                // 3. Shuffle the available unplayed pool and use it for the queue
                let freshPool = unplayedPool.shuffled()
                
                // Use the shuffled pool for the queue (limit to 100 songs)
                processedQueue = Array(freshPool.prefix(100))
                
            } else {
                // SHUFFLE OFF: Restore the master alphabetical order
                if let currentId = currentId,
                       let currentIndex = librarySnapshot.firstIndex(where: { $0.id == currentId }) {
                        
                        // This restores the natural order from the NEXT song (not current) to the end
                        // Skip the current song to prevent it from playing twice
                        let nextIndex = currentIndex + 1
                        if nextIndex < librarySnapshot.count {
                            processedQueue = Array(librarySnapshot[nextIndex...].prefix(100))
                        } else {
                            processedQueue = []
                        }
                    }
            }
            
            // 3. Update the UI
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    self.queue = processedQueue
                }
            }
        }
    }
    
    // Enable shuffle and shuffle the queue (used by shuffle buttons)
    func enableShuffleAndShuffleQueue() {
        // If shuffle is off, toggle it on (which will shuffle the queue)
        if !isShuffleOn {
            toggleShuffle()
        } else {
            // Shuffle was already on, manually shuffle the current queue
            let librarySnapshot = self.currentLibraryReference ?? []
            let currentId = currentSong?.id
            
            Task(priority: .userInitiated) {
                // Filter unplayed songs
                var unplayedPool = librarySnapshot.filter { !playedIDs.contains($0.id) }
                
                // If pool is empty, reset
                if unplayedPool.isEmpty || (unplayedPool.count == 1 && unplayedPool.first?.id == currentId) {
                    playedIDs.removeAll()
                    unplayedPool = librarySnapshot
                }
                
                // Shuffle and update queue
                let freshPool = unplayedPool.shuffled()
                let processedQueue = Array(freshPool.prefix(100))
                
                await MainActor.run {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        self.queue = processedQueue
                    }
                }
            }
        }
    }
    
    func moveQueueItem(from source: IndexSet, to destination: Int) {
        objectWillChange.send()
        
        // 1. Create a snapshot of the current display list
        var combined = upNextDisplayList
        
        // 2. Perform the move
        combined.move(fromOffsets: source, toOffset: destination)
        
        // 4. Redistribute: Split based on destination position
        // If moved to top (destination 0 or very early), it becomes "Play Next"
        let originalManualCount = manualQueue.count
        let splitPoint: Int
        
        if destination == 0 {
            // Moved to very top - everything up to and including moved items goes to manualQueue
            splitPoint = max(1, originalManualCount + source.count)
        } else if destination <= originalManualCount {
            // Moved within the "Play Next" section
            splitPoint = originalManualCount
        } else {
            // Moved to regular queue section - maintain original split
            splitPoint = originalManualCount
        }
        
        // 5. Rebuild queues without duplicates
        var newManualQueue: [Song] = []
        var seenIDs = Set<URL>()
        
        for song in combined.prefix(splitPoint) {
            if !seenIDs.contains(song.id) {
                newManualQueue.append(song)
                seenIDs.insert(song.id)
            }
        }
        
        var newQueue: [Song] = []
        for song in combined.suffix(from: splitPoint) {
            if !seenIDs.contains(song.id) {
                newQueue.append(song)
                seenIDs.insert(song.id)
            }
        }
        
        // 6. Update queues
        self.manualQueue = newManualQueue
        self.queue = newQueue
    }

    func removeQueueItem(at offsets: IndexSet) {
        objectWillChange.send()
        
        // We iterate backwards through the offsets so that removing an item
        // doesn't shift the indices of the remaining items we need to delete.
        for index in offsets.reversed() {
            if index < manualQueue.count {
                // The item is in the "Play Next" manual queue
                manualQueue.remove(at: index)
            } else {
                // The item is in the regular contextual queue
                // We subtract manualQueue.count to find the correct relative index
                let contextualIndex = index - manualQueue.count
                if contextualIndex < queue.count {
                    queue.remove(at: contextualIndex)
                }
            }
        }
    }
    
    func updateProgress() {
        // 1. If the user is dragging the slider, stop updating the tracker
        guard !isScrubbing else { return }
        
        // 2. Use your private variable 'avPlayer'
        if let player = avPlayer {
            let seconds = CMTimeGetSeconds(player.currentTime())
            if seconds.isFinite {
                self.progressTracker.currentTime = seconds
            }
        }
    }
    
    private func triggerToast(message: String) {
        // Stop any existing timer so they don't overlap
        toastTimer?.cancel()
        
        // Use Haptics (Feedback)
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif

        self.toastMessage = message
        
        // Show with animation
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            self.showToast = true
        }
        
        // Hide after delay
        let workItem = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.5)) {
                self.showToast = false
            }
        }
        self.toastTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }
    
    private func refillQueueBuffer(from library: [Song]) {
        // Only refill if not shuffling and we have room in our 100-song window
        guard !isShuffleOn, queue.count < 100, let lastInQueue = queue.last else { return }
        
        if let idx = library.firstIndex(where: { $0.id == lastInQueue.id }),
           idx + 1 < library.count {
            let nextSong = library[idx + 1]
            // Prevent duplicates
            if !queue.contains(where: { $0.id == nextSong.id }) {
                self.queue.append(nextSong)
            }
        }
    }
}

struct GlobalToastOverlay: ViewModifier {
    @ObservedObject var playerManager: PlayerManager

    func body(content: Content) -> some View {
        ZStack {
            content // Your entire app

            if playerManager.showToast {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.green)
                        Text(playerManager.toastMessage)
                            .font(.system(size: 14, weight: .bold))
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 24)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                    .padding(.bottom, 130)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .zIndex(999)
            }
        }
    }
}
