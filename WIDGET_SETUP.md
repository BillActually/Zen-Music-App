# Widget Extension Setup Instructions

I've created the widget extension files. To complete the setup in Xcode:

## Steps to Add Widget Extension:

1. **Open the project in Xcode**

2. **Add Widget Extension Target:**
   - File → New → Target
   - Select "Widget Extension"
   - Name it "ZenWidget"
   - Make sure "Include Configuration Intent" is UNCHECKED (we're using a static widget)
   - Click Finish

3. **Replace the generated files:**
   - The widget files are already created in `/ZenWidget/` folder:
     - `ZenWidget.swift` - Main widget implementation
     - `ZenWidgetBundle.swift` - Widget bundle entry point
     - `Info.plist` - Widget extension configuration
   - Delete the auto-generated widget files Xcode created
   - Add the existing files from the ZenWidget folder to the widget extension target

4. **Configure App Groups:**
   - Select the main "Zen" target → Signing & Capabilities
   - Click "+ Capability" → Add "App Groups"
   - Create/select group: `group.Test.Zen`
   - Repeat for "ZenWidget" target with the same group name

5. **Update Bundle Identifier:**
   - Widget extension should be: `Test.Zen.ZenWidget`

6. **Build and Run:**
   - Build the project
   - Run on device/simulator
   - Long press home screen → Tap "+" → Search for "Zen" → Add widget
   - Select the Large (4x4) size

## What the Widget Does:

- **Displays:** Current song title, artist, album, and artwork
- **Shows:** Play/pause state
- **Controls:** Previous, Play/Pause, Next buttons (opens app to control)
- **Updates:** Automatically syncs with app playback state

## Deep Link URLs:

The widget uses these URL schemes to control playback:
- `zen://toggle` - Toggle play/pause
- `zen://next` - Next song
- `zen://previous` - Previous song

The app is configured to handle these deep links and control the PlayerManager accordingly.
