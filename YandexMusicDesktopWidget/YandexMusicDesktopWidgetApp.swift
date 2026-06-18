import AppKit
import SwiftUI
import ApplicationServices

// Версия для macOS 11+ (Big Sur и новее): без системного виджета на рабочем столе.
// Точка входа на AppKit (NSStatusItem + NSPopover + NSWindow), т.к. SwiftUI
// MenuBarExtra/Window/openWindow доступны только с macOS 13. Ядро (NowPlayingService,
// попап ContentView, адаптер, REST API) — то же, что в основной версии.

@main
struct LegacyAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

extension Notification.Name {
    /// Попап просит открыть главное окно (настройки/о программе).
    static let showMainWindow = Notification.Name("YM.ShowMainWindow")
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Нет иконки в доке — только иконка в строке меню (как в основной версии).
        NSApp.setActivationPolicy(.accessory)
        NowPlayingService.shared.startObserving()

        setupPopover()
        setupStatusItem()

        NotificationCenter.default.addObserver(
            self, selector: #selector(showMainWindow),
            name: .showMainWindow, object: nil)

        // Запрос разрешений на Accessibility (опционально — для лайка без входа и
        // запасного чтения трека через AX).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            Self.requestPermissionsIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NowPlayingService.shared.stopObserving()
    }

    // MARK: - Меню-бар попап

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingController(rootView: ContentView().preferredColorScheme(.dark))
        popover.contentViewController = host
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "music.note",
                                accessibilityDescription: "Yandex Music")
            btn.action = #selector(togglePopover(_:))
            btn.target = self
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // Подгоняем размер попапа под содержимое SwiftUI (на 11 нет авто-sizingOptions).
        if let host = popover.contentViewController {
            host.view.layoutSubtreeIfNeeded()
            popover.contentSize = host.view.fittingSize
        }
        NowPlayingService.shared.forceRefreshIncludingUnminimize()
        popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Главное окно

    @objc private func showMainWindow() {
        popover.performClose(nil)
        if mainWindow == nil {
            let host = NSHostingController(rootView: MainWindowView().preferredColorScheme(.dark))
            let win = NSWindow(contentViewController: host)
            win.title = "Music Widget"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.center()
            NotificationCenter.default.addObserver(
                self, selector: #selector(mainWindowWillClose),
                name: NSWindow.willCloseNotification, object: win)
            mainWindow = win
        }
        // Пока окно открыто — показываем приложение как обычное (иконка в доке, фокус).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func mainWindowWillClose() {
        // Окно закрыли — снова прячемся в строку меню (без иконки в доке).
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Разрешения

    private static func requestPermissionsIfNeeded() {
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
    }
}

// MARK: - Автозапуск при входе (macOS 11+, без SMAppService)

/// Автозапуск через LaunchAgent в ~/Library/LaunchAgents (SMAppService доступен только
/// с macOS 13). Простой и надёжный способ для старых систем: launchd запускает
/// исполняемый файл приложения при входе пользователя.
enum LoginItem {
    private static let label = (Bundle.main.bundleIdentifier ?? "com.yandexmusic.widget") + ".login"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        if on {
            guard let exec = Bundle.main.executablePath else { return false }
            let dir = plistURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exec],
                "RunAtLoad": true,
                "ProcessType": "Interactive"
            ]
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0) else { return false }
            do { try data.write(to: plistURL); return true } catch { return false }
        } else {
            try? FileManager.default.removeItem(at: plistURL)
            return true
        }
    }
}
