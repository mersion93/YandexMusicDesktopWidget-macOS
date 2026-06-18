<div align="center">

# 🎵 YandexMusicDesktopWidget

**A "Now Playing" widget for Yandex Music on macOS** — desktop & menu bar,
HD artwork, likes, and playback controls.

[Русский](README.md) · **English**

![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
[![Release](https://img.shields.io/github/v/release/mersion93/YandexMusicDesktopWidget-macOS?color=ffcc00)](../../releases/latest)
[![Downloads](https://img.shields.io/github/downloads/mersion93/YandexMusicDesktopWidget-macOS/total?color=ffcc00)](../../releases)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

<img src="docs/screenshot2.png" width="640" alt="Desktop widgets">

</div>

---

## ✨ Features

| | |
|---|---|
| 🎵 Three desktop widget sizes | 🖼 High-quality artwork |
| ❤️ Like / dislike from the widget | ⏯ Play/pause, skip, scrub |
| 🪟 Menu-bar popup (2 styles) + window | 🌍 Russian & English UI |
| 🚀 Launch at login | ⚡️ Works even when the player is minimized |

## 📥 Installation

1. Download the latest **`.dmg`** from **[Releases](../../releases/latest)**.
2. Open the DMG and drag the app into **Applications**.
3. **First launch.** The app is free and not signed with a paid Apple ID, so macOS asks for
   confirmation **once** — choose either way:

   <details>
   <summary><b>Option 1 — no Terminal (recommended)</b></summary>

   - Double-click the app → click **Cancel** in the warning.
   - Open **System Settings → Privacy & Security**.
   - Scroll down to the blocked-app notice → click **"Open Anyway"** → confirm with your password.
   - From now on it opens with a normal double-click.
   </details>

   <details>
   <summary><b>Option 2 — one Terminal command</b></summary>

   ```bash
   xattr -dr com.apple.quarantine /Applications/YandexMusicDesktopWidget.app
   ```
   Then open the app normally.
   </details>

4. In the app window → **Settings**, sign in to Yandex (for artwork and likes).
5. Add the widget: right-click the desktop → **Edit Widgets** → "YandexMusicWidget".

## 🛠 Build from source

Requires Xcode 16+ and macOS 14+:

```bash
bash release_tools/make_release.sh 1.0.0   # builds the .app and DMG
```

Architecture overview: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## 📄 License

[MIT](LICENSE). The `Vendor/MediaRemoteAdapter` component is
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (its own license).
