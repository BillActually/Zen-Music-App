import Foundation
import SwiftData
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

actor SongImporter {
    private let modelContext: ModelContext
    
    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
    }
    
    func importSongs(from urls: [URL], progress: @escaping (Int, Int) -> Void) async {
        let totalToProcess = urls.count
        
        // Handle empty array case
        guard totalToProcess > 0 else {
            await MainActor.run {
                progress(0, 0)
            }
            return
        }
        
        // Call progress immediately to show we've started
        await MainActor.run {
            progress(0, totalToProcess)
        }
        
        var currentCount = 0
        
        // Yield to allow UI to update
        await Task.yield()
        
        // MEMORY OPTIMIZATION: Fetch only URLs using a lightweight query
        // This avoids loading full Song objects (which include artwork data) into memory
        var existingURLs = Set<URL>()
        do {
            // Fetch all songs but only access the URL property (lightweight)
            // SwiftData will lazy-load properties, so accessing only URL is efficient
            let descriptor = FetchDescriptor<Song>()
            let allSongs = try modelContext.fetch(descriptor)
            
            // Extract URLs in batches to yield control and reduce memory pressure
            var processedCount = 0
            for song in allSongs {
                existingURLs.insert(song.url.standardized)
                processedCount += 1
                
                // Yield every 500 songs to prevent blocking
                if processedCount % 500 == 0 {
                    await Task.yield()
                }
            }
            
            // Clear the array reference to help with memory (allSongs will be deallocated)
            // The existingURLs Set now contains all we need
        } catch {
            print("Error fetching existing songs: \(error)")
        }
        
        // Yield again after fetch to prevent blocking
        await Task.yield()
        
        // Update progress after initial fetch
        await MainActor.run {
            progress(0, totalToProcess)
        }
        
        for url in urls {
            currentCount += 1
            
            // Normalize URL for comparison (handles symlinks, trailing slashes, etc.)
            let standardizedURL = url.standardized
            
            // Skip if already imported - fast set lookup
            if existingURLs.contains(standardizedURL) {
                // Update progress more frequently for skipped items
                let countForSkip = currentCount
                if countForSkip % 5 == 0 || countForSkip == totalToProcess {
                    await MainActor.run {
                        progress(countForSkip, totalToProcess)
                    }
                }
                continue
            }
            
            // 1. Start Security Access
            let accessGranted = url.startAccessingSecurityScopedResource()
            
            // 2. Load Metadata with a timeout/safety
            let asset = AVURLAsset(url: url)
            var title = url.lastPathComponent
            var artist = "Unknown Artist"
            var album = "Unknown Album"
            var artworkData: Data? = nil
            
            do {
                // Load metadata with timeout protection
                let metadata = try await withTimeout(seconds: 5) {
                    try await asset.load(.metadata)
                }
                
                if let extractedTitle = await extractValue(from: metadata, for: .commonIdentifierTitle) {
                    title = extractedTitle
                }
                artist = await extractValue(from: metadata, for: .commonIdentifierArtist) ?? "Unknown Artist"
                album = await extractValue(from: metadata, for: .commonIdentifierAlbumName) ?? "Unknown Album"
                
                // Extract Artwork with size limit to prevent memory issues
                let artworkItems = AVMetadataItem.metadataItems(from: metadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common)
                if let artworkItem = artworkItems.first {
                    if let rawData = try? await artworkItem.load(.dataValue) {
                        // Downscale artwork to max 500x500 to save memory
                        artworkData = downscaleImageData(rawData, maxDimension: 500)
                    }
                }
            } catch {
                print("DEBUG: Could not load metadata for \(url.lastPathComponent), using filename.")
            }

            // 3. Create and Insert
            // Use standardized URL to ensure consistency
            let songURL = url.standardized
            let newSong = Song(title: title, artist: artist, album: album, url: songURL)
            if let data = artworkData {
                newSong.artworkContainer = SongArtwork(data: data)
            }
            
            modelContext.insert(newSong)
            existingURLs.insert(standardizedURL)
            
            // 4. Cleanup & UI update
            if accessGranted { url.stopAccessingSecurityScopedResource() }
            
            // Yield frequently to prevent blocking and reduce memory pressure
            if currentCount % 5 == 0 {
                await Task.yield()
            }
            
            // Update progress frequently for UI responsiveness
            let countForProgress = currentCount
            if countForProgress % 10 == 0 {
                await MainActor.run {
                    progress(countForProgress, totalToProcess)
                }
            }
            
            // Batch save less frequently to reduce database lock contention
            // Save every 50 songs or at the end for better performance with large libraries
            let countForSave = currentCount
            if countForSave % 50 == 0 || countForSave == totalToProcess {
                do {
                    try modelContext.save()
                } catch {
                    print("Error saving batch: \(error)")
                }
            }
        }
        
        // Final save and progress update
        try? modelContext.save()
        await MainActor.run {
            progress(totalToProcess, totalToProcess)
        }
    }

    private func extractValue(from items: [AVMetadataItem], for identifier: AVMetadataIdentifier) async -> String? {
        let filtered = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
        guard let item = filtered.first else { return nil }
        return try? await withTimeout(seconds: 2) {
            try await item.load(.stringValue)
        }
    }
    
    // Helper to add timeout to async operations
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "TimeoutError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation timed out"])
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    // Downscale image data to reduce memory usage
    private func downscaleImageData(_ data: Data, maxDimension: CGFloat) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return data }
        
        let size = image.size
        let maxSize = max(size.width, size.height)
        
        // Only downscale if image is larger than maxDimension
        guard maxSize > maxDimension else { return data }
        
        let scale = maxDimension / maxSize
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        image.draw(in: CGRect(origin: .zero, size: newSize))
        guard let resizedImage = UIGraphicsGetImageFromCurrentImageContext() else { return data }
        
        // Compress to JPEG with 0.8 quality to further reduce size
        return resizedImage.jpegData(compressionQuality: 0.8)
        #else
        return data
        #endif
    }
}
