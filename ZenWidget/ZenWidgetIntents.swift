//
//  ZenWidgetIntents.swift
//  ZenWidget
//
//  Created by William Barrios on 1/27/26.
//

import AppIntents
import Foundation

struct TogglePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Playback"
    static var description = IntentDescription("Play or pause the current song")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // Send Darwin notification to the main app (works when app is in background playing audio)
        let notificationName = "com.williambarrios.zen.toggle" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName),
            nil,
            nil,
            true
        )
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description = IntentDescription("Play the next song")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let notificationName = "com.williambarrios.zen.next" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName),
            nil,
            nil,
            true
        )
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description = IntentDescription("Play the previous song")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let notificationName = "com.williambarrios.zen.previous" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName),
            nil,
            nil,
            true
        )
        return .result()
    }
}
