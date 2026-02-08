# Xcode Settings Guide for Widget Background Audio Control

This guide outlines all the Xcode settings you need to verify to ensure Zen can be controlled via widgets even when backgrounded or when other apps are playing audio.

## 1. Target: Zen (Main App)

### Signing & Capabilities Tab

1. **App Groups**
   - ✅ Must have `group.Test.Zen` enabled
   - This allows the widget and app to share data via UserDefaults

2. **Background Modes**
   - ✅ **Audio, AirPlay, and Picture in Picture** must be checked
   - This allows the app to:
     - Continue playing audio in the background
     - Stay active when audio is playing
     - Respond to widget actions even when backgrounded

### Info Tab (or Info.plist)

**Where to find it:**
1. In Xcode's Project Navigator (left sidebar), look for a file called `Info.plist` inside the `Zen` folder
2. OR: Select the **Zen** target → Go to the **Info** tab at the top

**What to verify:**
The file should contain these keys. If you're viewing it as source code, it looks like:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

**If viewing in Xcode's Info tab (not source code):**
- Look for a row with key: `UIBackgroundModes`
- It should have a value that includes `audio`

**Note:** If you don't see `UIBackgroundModes` in the Info tab, you can add it:
1. Click the `+` button to add a new key
2. Type `UIBackgroundModes` (or select it from the dropdown)
3. Set the type to `Array`
4. Add an item with value `audio`

### Build Settings

1. **Deployment Target**
   - Should be iOS 16.0 or later (for App Intents support)

2. **Swift Language Version**
   - Should be Swift 5.9 or later

## 2. Target: ZenWidgetExtension

### Signing & Capabilities Tab

1. **App Groups**
   - ✅ Must have `group.Test.Zen` enabled (same as main app)
   - This is critical for widget-to-app communication

2. **Background Modes**
   - ❌ Widget extensions do NOT need background modes
   - Widgets run in a separate process and don't need background capabilities

### Info Tab

- Widget extensions typically don't need special Info.plist entries for this functionality

## 3. Project-Level Settings

### General Tab

1. **Deployment Info**
   - Minimum iOS version: 16.0 or later

### Build Settings (Project Level)

1. **Swift Language Version**
   - Should be consistent across all targets

## 4. Verification Checklist

Before testing, verify:

- [ ] Main app has `group.Test.Zen` App Group enabled
- [ ] Widget extension has `group.Test.Zen` App Group enabled
- [ ] Main app has "Audio, AirPlay, and Picture in Picture" background mode enabled
- [ ] `Info.plist` contains `UIBackgroundModes` with `audio` entry
- [ ] Both targets use the same App Group identifier
- [ ] Deployment target is iOS 16.0+

## 5. How to Check in Xcode

### For Main App (Zen):
1. Select the **Zen** target in the project navigator
2. Go to **Signing & Capabilities** tab
3. Verify:
   - App Groups shows `group.Test.Zen`
   - Background Modes shows "Audio, AirPlay, and Picture in Picture" checked

### For Widget Extension (ZenWidgetExtension):
1. Select the **ZenWidgetExtension** target
2. Go to **Signing & Capabilities** tab
3. Verify:
   - App Groups shows `group.Test.Zen`

### For Info.plist:
1. Open `Zen/Info.plist`
2. Verify `UIBackgroundModes` key exists with `audio` value

## 6. Background Modes Explained

### Why Only "Audio" is Needed:

**Audio Background Mode:**
- ✅ Keeps the app active when audio is playing
- ✅ Allows the polling mechanism (Timer) to continue running
- ✅ This is the ONLY background mode needed for widget control

**Background Fetch:**
- ❌ NOT needed - This is for periodically fetching data (like checking for new content)
- ❌ Doesn't help with widget control
- ❌ Would waste battery checking for widget actions on a schedule

**Background Processing:**
- ❌ NOT needed - This is for running scheduled background tasks
- ❌ Doesn't help with widget control
- ❌ Widget actions should be immediate, not scheduled

**How Widget Control Works:**
1. When audio is playing: App stays active (via Audio background mode) → Polling catches widget actions
2. When audio is paused: App can be suspended → Widget's `OpensIntent` wakes the app → App processes action immediately

The `OpensIntent` in the widget is what wakes the app when it's suspended. You don't need Background Fetch or Background Processing for this.

## 7. Common Issues

### Widget actions not working when app is backgrounded:
- ✅ Ensure Background Modes > Audio is enabled
- ✅ Ensure App Groups are configured correctly
- ✅ Check that `Info.plist` has `UIBackgroundModes` with `audio`

### App crashes when switching between audio apps:
- ✅ Ensure audio session is only activated when needed (not at startup)
- ✅ Use `.notifyOthersOnDeactivation` option when activating audio session

### Widget can't communicate with app:
- ✅ Verify both targets have the same App Group identifier
- ✅ Check that App Groups are enabled in Signing & Capabilities
- ✅ Ensure the App Group identifier matches in code: `group.Test.Zen`

## 8. Testing

After verifying settings:

1. Build and run the app
2. Play a song in Zen
3. Background the app (don't force quit)
4. Start playing audio in another app (e.g., Overcast)
5. Tap the Zen widget play button
6. Zen should take over and start playing

If it doesn't work:
- Check Xcode console for error messages
- Verify all settings match this guide
- Ensure the app is backgrounded (not force quit)
- Try restarting the device (sometimes iOS needs a restart after capability changes)
