import SwiftUI
import AppKit
import CoreGraphics

@main
struct YandexMusicDesktopWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: "music.note")
        }
        .menuBarExtraStyle(.window)

        // Полноценное окно приложения (настройки, плееры, о программе, онбординг)
        Window("Music Widget", id: "main") {
            MainWindowView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Нет иконки в доке — только иконка в строке меню
        NSApp.setActivationPolicy(.accessory)
        NowPlayingService.shared.startObserving()

        // При первом запуске запрашиваем разрешения сразу, не ждём пока пользователь
        // найдёт предупреждение в интерфейсе приложения.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            Self.requestPermissionsIfNeeded()
        }
    }

    private static func requestPermissionsIfNeeded() {
        // Запись экрана больше не нужна (данные идут через системный адаптер).
        // Accessibility — опционально, для лайка без входа и запасного чтения трека.
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NowPlayingService.shared.stopObserving()
    }
}
