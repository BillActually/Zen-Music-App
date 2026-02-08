//
//  ZenWidget.swift
//  ZenWidget
//
//  Created by William Barrios on 1/27/26.
//

import WidgetKit
import SwiftUI
import AppIntents

struct ZenWidget: Widget {
    let kind: String = "ZenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ZenWidgetProvider()) { entry in
            if #available(iOS 17.0, *) {
                ZenWidgetEntryView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                ZenWidgetEntryView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("Zen Music Player")
        .description("Control your music and see what's playing")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ZenWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ZenWidgetEntry {
        ZenWidgetEntry(
            date: Date(),
            songTitle: "Sample Song",
            songArtist: "Sample Artist",
            songAlbum: "Sample Album",
            isPlaying: false,
            artworkData: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ZenWidgetEntry) -> ()) {
        let entry = loadCurrentSongState()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let entry = loadCurrentSongState()
        // Update every 5 seconds to keep widget in sync
        let timeline = Timeline(entries: [entry], policy: .after(Calendar.current.date(byAdding: .second, value: 5, to: Date())!))
        completion(timeline)
    }
    
    /// Max artwork size to decode in widget (bytes). Widget extensions have tight memory limits;
    /// decoding large images can get the process killed.
    private static let maxArtworkBytes = 200_000
    
    private func loadCurrentSongState() -> ZenWidgetEntry {
        // Load from shared UserDefaults via App Group
        let sharedDefaults = UserDefaults(suiteName: "group.com.williambarrios.zen")
        
        let songTitle = sharedDefaults?.string(forKey: "currentSongTitle") ?? "No song playing"
        let songArtist = sharedDefaults?.string(forKey: "currentSongArtist") ?? ""
        let songAlbum = sharedDefaults?.string(forKey: "currentSongAlbum") ?? ""
        let isPlaying = sharedDefaults?.bool(forKey: "isPlaying") ?? false
        let rawArtwork = sharedDefaults?.data(forKey: "currentSongArtwork")
        // Only pass artwork if small enough to decode without risking memory kill
        let artworkData = rawArtwork.flatMap { $0.count <= Self.maxArtworkBytes ? $0 : nil }
        
        return ZenWidgetEntry(
            date: Date(),
            songTitle: songTitle,
            songArtist: songArtist,
            songAlbum: songAlbum,
            isPlaying: isPlaying,
            artworkData: artworkData
        )
    }
}

struct ZenWidgetEntry: TimelineEntry {
    let date: Date
    let songTitle: String
    let songArtist: String
    let songAlbum: String
    let isPlaying: Bool
    let artworkData: Data?
}

struct ZenWidgetEntryView: View {
    var entry: ZenWidgetProvider.Entry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        switch family {
        case .systemSmall:
            smallWidgetView
        case .systemMedium:
            mediumWidgetView
        case .systemLarge:
            largeWidgetView
        default:
            smallWidgetView
        }
    }
    
    // MARK: - Small Widget (2x2)
    private var smallWidgetView: some View {
        ZStack {
            // Background
            widgetBackground

            VStack(alignment: .leading, spacing: 0) {
                // Top section - tappable to open app
                Link(destination: URL(string: "zen://open")!) {
                    HStack(alignment: .top, spacing: 0) {
                        // Artwork - top-left
                        if let artworkData = entry.artworkData,
                           let uiImage = UIImage(data: artworkData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 80, height: 80)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 80, height: 80)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.system(size: 28))
                                        .foregroundColor(.gray)
                                )
                        }

                        Spacer()

                        // App logo in top-right
                        Image("AppLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28)
                            .opacity(0.8)
                    }
                }
                .padding(.top, 6)
                .padding(.horizontal, 6)

                Spacer()

                // Bottom section with title and button
                HStack(alignment: .bottom, spacing: 8) {
                    // Song Title - tappable to open app
                    Link(destination: URL(string: "zen://open")!) {
                        Text(entry.songTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Play/Pause Button - using Button with intent (no app open)
                    Button(intent: TogglePlaybackIntent()) {
                        Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.yellow)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    // MARK: - Medium Widget (2x4)
    private var mediumWidgetView: some View {
        HStack(spacing: 12) {
            // Artwork - tappable to open app
            Link(destination: URL(string: "zen://open")!) {
                if let artworkData = entry.artworkData,
                   let uiImage = UIImage(data: artworkData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 100, height: 100)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 100, height: 100)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 30))
                                .foregroundColor(.gray)
                        )
                }
            }

            // Song Info and Controls
            VStack(alignment: .leading, spacing: 8) {
                // Song Info - tappable to open app
                Link(destination: URL(string: "zen://open")!) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.songTitle)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text(entry.songArtist)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Controls Section - using Button with intents (no app open)
                HStack(spacing: 12) {
                    // Previous
                    Button(intent: PreviousTrackIntent()) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.yellow)
                            .frame(width: 42, height: 42)
                            .background(Color.black.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    // Play/Pause - Larger
                    Button(intent: TogglePlaybackIntent()) {
                        Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .frame(width: 52, height: 52)
                            .background(Color.yellow)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    // Next
                    Button(intent: NextTrackIntent()) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.yellow)
                            .frame(width: 42, height: 42)
                            .background(Color.black.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(widgetBackground)
    }
    
    // MARK: - Large Widget (4x4)
    private var largeWidgetView: some View {
        VStack(spacing: 0) {
            // Artwork and Info Section - tappable to open app
            Link(destination: URL(string: "zen://open")!) {
                HStack(spacing: 16) {
                    // Artwork - zoomed in to fill without black bars
                    if let artworkData = entry.artworkData,
                       let uiImage = UIImage(data: artworkData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 140, height: 140)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 140, height: 140)
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 40))
                                    .foregroundColor(.gray)
                            )
                    }

                    // Song Info
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.songTitle)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(2)

                        Text(entry.songArtist)
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        Text(entry.songAlbum)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }

            Divider()

            // Controls Section - using Button with intents (no app open)
            HStack(spacing: 20) {
                // Previous
                Button(intent: PreviousTrackIntent()) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.yellow)
                        .frame(width: 56, height: 56)
                        .background(Color.black.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                // Play/Pause - Larger
                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                        .frame(width: 80, height: 80)
                        .background(Color.yellow)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                // Next
                Button(intent: NextTrackIntent()) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.yellow)
                        .frame(width: 56, height: 56)
                        .background(Color.black.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
        .background(widgetBackground)
    }
    
    // MARK: - Shared Background
    private var widgetBackground: some View {
        // Use clear so container background shows through uniformly
        Color.clear
    }
}

@available(iOS 17.0, *)
#Preview(as: .systemSmall) {
    ZenWidget()
} timeline: {
    ZenWidgetEntry(
        date: Date(),
        songTitle: "Sample Song Title",
        songArtist: "Sample Artist",
        songAlbum: "Sample Album",
        isPlaying: true,
        artworkData: nil
    )
}

@available(iOS 17.0, *)
#Preview(as: .systemMedium) {
    ZenWidget()
} timeline: {
    ZenWidgetEntry(
        date: Date(),
        songTitle: "Sample Song Title",
        songArtist: "Sample Artist",
        songAlbum: "Sample Album",
        isPlaying: true,
        artworkData: nil
    )
}

@available(iOS 17.0, *)
#Preview(as: .systemLarge) {
    ZenWidget()
} timeline: {
    ZenWidgetEntry(
        date: Date(),
        songTitle: "Sample Song Title",
        songArtist: "Sample Artist",
        songAlbum: "Sample Album",
        isPlaying: true,
        artworkData: nil
    )
}
