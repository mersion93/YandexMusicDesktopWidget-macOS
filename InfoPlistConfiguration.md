# Info.plist Configuration Reference

## Main App Target: YandexMusicDesktopWidget

### Required Keys

| Key | Value | Purpose |
|-----|-------|---------|
| `LSMinimumSystemVersion` | `14.0` | macOS 14 Sonoma minimum |
| `NSPrincipalClass` | `NSApplication` | Required for macOS apps |
| `NSAppleEventsUsageDescription` | String | Required for Apple Events access |
| `NSAppleMusicUsageDescription` | String | Required for Media Player access |

### Build Settings Required

In Xcode → Target → Build Settings:

```
MACOSX_DEPLOYMENT_TARGET = 14.0
SWIFT_VERSION = 5.10
PRODUCT_BUNDLE_IDENTIFIER = com.yandexmusic.widget
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_STYLE = Automatic
ENABLE_APP_SANDBOX = YES
```

---

## Widget Extension Target: YandexMusicDesktopWidgetExtension

### Required Keys

| Key | Value | Purpose |
|-----|-------|---------|
| `LSMinimumSystemVersion` | `14.0` | macOS 14 Sonoma minimum |
| `CFBundleDisplayName` | `Yandex Music` | Name shown in widget picker |
| `NSExtension.NSExtensionPointIdentifier` | `com.apple.widgetkit-extension` | Identifies as WidgetKit |

### Build Settings Required

```
MACOSX_DEPLOYMENT_TARGET = 14.0
SWIFT_VERSION = 5.10
PRODUCT_BUNDLE_IDENTIFIER = com.yandexmusic.widget.extension
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_STYLE = Automatic
ENABLE_APP_SANDBOX = YES
```

---

## App Group Configuration

Both targets MUST share the same App Group: `group.com.yandexmusic.widget`

This is configured in Entitlements files AND in:
- Xcode → Target → Signing & Capabilities → App Groups

---

## Framework Imports by File

| File | Frameworks |
|------|-----------|
| `MediaKeyController.swift` | `CoreGraphics`, `AppKit` |
| `NowPlayingService.swift` | `MediaPlayer`, `Combine`, `AppKit` |
| `AppGroupManager.swift` | `Foundation`, `OSLog` |
| `WidgetProvider.swift` | `WidgetKit`, `SwiftUI`, `AppIntents` |
| `PlaybackIntents.swift` | `AppIntents`, `WidgetKit`, `CoreGraphics` |
| `DesktopMusicWidget.swift` | `SwiftUI`, `WidgetKit`, `AppKit` |
| `ContentView.swift` | `SwiftUI`, `WidgetKit`, `Combine` |
