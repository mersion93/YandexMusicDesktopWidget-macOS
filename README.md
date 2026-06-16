# YandexMusicDesktopWidget

macOS 14+ desktop widget for Yandex Music with full playback controls.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later
- Apple Developer account (for App Groups and signing)
- Yandex Music for macOS installed (`ru.yandex.desktop.music`)

---

## Project Structure

```
YandexMusicDesktopWidget/
├── Shared/                                    ← Shared between app and extension
│   ├── SharedModels.swift                     ← TrackInfo, PlaybackCommand, WidgetSyncStatus
│   ├── Constants.swift                        ← All app constants
│   └── AppGroupManager.swift                  ← App Group UserDefaults bridge
│
├── YandexMusicDesktopWidget/                  ← Main application target
│   ├── YandexMusicDesktopWidgetApp.swift      ← @main entry point + AppDelegate
│   ├── ContentView.swift                      ← Diagnostics window UI
│   ├── MediaKeyController.swift               ← CGEvent media key sender
│   ├── NowPlayingService.swift                ← MPNowPlayingInfoCenter polling
│   ├── WidgetDataStore.swift                  ← High-level storage API
│   ├── Info.plist                             ← App Info.plist
│   └── YandexMusicDesktopWidget.entitlements  ← App sandbox + App Groups
│
└── YandexMusicDesktopWidgetExtension/         ← Widget extension target
    ├── DesktopMusicWidgetBundle.swift         ← @main WidgetBundle
    ├── DesktopMusicWidget.swift               ← Small/Medium/Large widget views
    ├── WidgetProvider.swift                   ← AppIntentTimelineProvider
    ├── PlaybackIntents.swift                  ← PlayPause/Next/Previous AppIntents
    ├── Info.plist                             ← Extension Info.plist
    └── YandexMusicDesktopWidgetExtension.entitlements
```

---

## Step 1 — Create the Xcode Project

1. Open Xcode → **File → New → Project**
2. Choose **macOS → App**
3. Set:
   - **Product Name**: `YandexMusicDesktopWidget`
   - **Bundle Identifier**: `com.yandexmusic.widget`
   - **Interface**: SwiftUI
   - **Language**: Swift
   - **Minimum Deployment**: macOS 14.0
4. Click **Next**, choose save location, click **Create**

---

## Step 2 — Add Widget Extension Target

1. **File → New → Target**
2. Choose **macOS → Widget Extension**
3. Set:
   - **Product Name**: `YandexMusicDesktopWidgetExtension`
   - **Bundle Identifier**: `com.yandexmusic.widget.extension`
   - **Include Configuration Intent**: ✓ (check this)
4. Click **Finish**
5. When asked "Activate scheme?", click **Activate**

---

## Step 3 — Add Files to the Project

### Delete auto-generated files

Delete from main target:
- `ContentView.swift` (replace with ours)

Delete from extension target:
- All auto-generated widget files

### Add Shared group

1. **File → New → Group without Folder** → name it `Shared`
2. Add these files to the group, targeting **both** main app and extension:
   - `Shared/Constants.swift`
   - `Shared/SharedModels.swift`
   - `Shared/AppGroupManager.swift`

### Add main app files

Add to **YandexMusicDesktopWidget** target only:
- `YandexMusicDesktopWidgetApp.swift`
- `ContentView.swift`
- `MediaKeyController.swift`
- `NowPlayingService.swift`
- `WidgetDataStore.swift`

### Add extension files

Add to **YandexMusicDesktopWidgetExtension** target only:
- `DesktopMusicWidgetBundle.swift`
- `DesktopMusicWidget.swift`
- `WidgetProvider.swift`
- `PlaybackIntents.swift`

---

## Step 4 — Configure Signing & Capabilities

### For the main app target:

1. Select **YandexMusicDesktopWidget** target → **Signing & Capabilities**
2. Set your **Team**
3. Confirm Bundle ID: `com.yandexmusic.widget`
4. Click **+ Capability** → add **App Groups**
5. Click **+** under App Groups → enter: `group.com.yandexmusic.widget`
6. Click **+ Capability** → add **App Sandbox**

### For the widget extension target:

1. Select **YandexMusicDesktopWidgetExtension** target → **Signing & Capabilities**
2. Set the **same Team**
3. Confirm Bundle ID: `com.yandexmusic.widget.extension`
4. Click **+ Capability** → add **App Groups**
5. Add the **same** App Group: `group.com.yandexmusic.widget`
6. Click **+ Capability** → add **App Sandbox**

---

## Step 5 — Configure Entitlements

Replace auto-generated entitlement files with the provided ones:

**YandexMusicDesktopWidget.entitlements**:
```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key>
<array><string>group.com.yandexmusic.widget</string></array>
```

**YandexMusicDesktopWidgetExtension.entitlements**:
```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key>
<array><string>group.com.yandexmusic.widget</string></array>
```

---

## Step 6 — Configure Build Settings

For **both targets**, in **Build Settings**:

| Setting | Value |
|---------|-------|
| `MACOSX_DEPLOYMENT_TARGET` | `14.0` |
| `SWIFT_VERSION` | `5.0` |
| `ENABLE_HARDENED_RUNTIME` | `YES` |
| `CODE_SIGN_STYLE` | `Automatic` |

For the **main app target** additionally:
| Setting | Value |
|---------|-------|
| `ENABLE_APP_SANDBOX` | `YES` |

---

## Step 7 — Add Frameworks

### Main app target → Build Phases → Link Binary With Libraries:

- `MediaPlayer.framework`
- `CoreGraphics.framework` (usually auto-linked)
- `WidgetKit.framework`
- `AppIntents.framework`

### Widget extension target → Link Binary With Libraries:

- `WidgetKit.framework`
- `AppIntents.framework`
- `CoreGraphics.framework`

---

## Step 8 — Build and Run

1. Select scheme **YandexMusicDesktopWidget**
2. Press **⌘R** to build and run
3. The diagnostics window will open

---

## Step 9 — Add Widget to Desktop

1. Open Yandex Music and play any track
2. Run the main app at least once (this registers the widget extension)
3. Right-click the macOS desktop → **Edit Widgets**
4. Search for "Yandex Music"
5. Drag **Small**, **Medium**, or **Large** widget to the desktop
6. Click **Done**

---

## How it Works

### Track Polling

`NowPlayingService` polls `MPNowPlayingInfoCenter.default().nowPlayingInfo` every 2 seconds. This system API returns metadata for whatever application currently holds the Now Playing session — Yandex Music populates this when it plays audio.

### Media Keys

`MediaKeyController` posts `CGEvent` system-defined events with NX key types:
- `NX_KEYTYPE_PLAY` (16) → Play/Pause
- `NX_KEYTYPE_NEXT` (17) → Next Track
- `NX_KEYTYPE_PREVIOUS` (18) → Previous Track

These are global media key events processed by the frontmost media application.

### Data Bridge

`AppGroupManager` uses `UserDefaults(suiteName:)` with the shared App Group container. Both the main app (writer) and the widget extension (reader) access the same key-value store.

### Widget Refresh

- `WidgetProvider` returns a `Timeline` with 30-second refresh policy
- After each playback command, `WidgetCenter.shared.reloadAllTimelines()` forces immediate refresh
- The main app also exposes a "Refresh Widget" button

---

## Troubleshooting

### Widget not appearing

- Make sure the main app has been run at least once
- Check that the App Group identifier matches exactly in both entitlements
- Check Console.app for errors from `com.yandexmusic.widget`

### No track info showing

- Yandex Music must be running and playing audio
- The app requires macOS media permissions — check System Settings → Privacy

### Media key commands not working

- The app must be authorized to post HID events
- Run the app first, play Yandex Music, then use widget buttons
- Check that `ENABLE_HARDENED_RUNTIME = YES` and no entitlement conflicts

### App Group "Unavailable"

- Verify your Apple Developer account has the App Group registered at developer.apple.com
- Re-generate provisioning profiles after adding App Group capability
- Try cleaning build folder: **Product → Clean Build Folder** (⇧⌘K)

---

## Architecture Notes

- `SharedModels.swift`, `Constants.swift`, `AppGroupManager.swift` are compiled into **both** targets
- The widget extension has **no access** to `NowPlayingService` or `MediaKeyController` — it only reads from App Group storage and fires `AppIntent` actions
- `PlaybackIntents.swift` in the extension duplicates the `sendMediaKey` function because the extension cannot import the main app module
- All logging uses `OSLog` with structured categories for easy Console.app filtering
