import Foundation
import OSLog

// Хранение в общем контейнере App Group через ФАЙЛЫ, а не UserDefaults.
// Причина: основное приложение работает БЕЗ песочницы, а расширение виджета —
// В песочнице. UserDefaults(suiteName:) у них резолвится в разные места, и данные
// не доходят до виджета. FileManager.containerURL(...) даёт ОДИН и тот же путь
// обоим (при наличии entitlement App Groups), поэтому делимся файлами.

final class AppGroupManager {
    static let shared = AppGroupManager()

    private let logger = Logger(subsystem: "com.yandexmusic.widget", category: "AppGroup")
    private let containerURL: URL?

    private init() {
        containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.AppGroup.identifier
        )
        if containerURL == nil {
            logger.error("App Group контейнер недоступен: \(Constants.AppGroup.identifier)")
        } else {
            logger.info("App Group контейнер: \(self.containerURL!.path)")
        }
    }

    var isAvailable: Bool { containerURL != nil }

    private func fileURL(_ name: String) -> URL? {
        containerURL?.appendingPathComponent(name)
    }

    private func writeString(_ value: String, to name: String) {
        guard let url = fileURL(name) else { return }
        try? value.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func readString(_ name: String) -> String? {
        guard let url = fileURL(name), let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Track

    func saveTrack(_ track: TrackInfo) {
        guard let url = fileURL("track.json") else {
            logger.error("Контейнер недоступен — трек не сохранён")
            return
        }
        do {
            let data = try JSONEncoder().encode(track)
            try data.write(to: url, options: .atomic)
            logger.debug("Трек сохранён: \(track.title) — \(track.artist)")
        } catch {
            logger.error("Ошибка сохранения трека: \(error.localizedDescription)")
        }
    }

    func loadTrack() -> TrackInfo {
        guard let url = fileURL("track.json"),
              let data = try? Data(contentsOf: url),
              let track = try? JSONDecoder().decode(TrackInfo.self, from: data) else {
            return TrackInfo.notRunning
        }
        return track
    }

    // MARK: - Настройки виджета

    func saveWidgetSettings(_ s: WidgetSettings) {
        guard let url = fileURL("widget_settings.json") else { return }
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }
    func loadWidgetSettings() -> WidgetSettings {
        guard let url = fileURL("widget_settings.json"),
              let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(WidgetSettings.self, from: data) else {
            return .default
        }
        return s
    }

    // MARK: - Last command

    func saveLastCommand(_ command: PlaybackCommand) {
        writeString(command.rawValue, to: "command")
    }

    func loadLastCommand() -> PlaybackCommand {
        guard let raw = readString("command"),
              let command = PlaybackCommand(rawValue: raw) else { return .none }
        return command
    }

    // MARK: - Sync status

    func saveSyncStatus(_ status: WidgetSyncStatus) {
        writeString(status.rawValue, to: "sync")
    }

    func loadSyncStatus() -> WidgetSyncStatus {
        guard let raw = readString("sync"),
              let status = WidgetSyncStatus(rawValue: raw) else { return .unknown }
        return status
    }

    // MARK: - Авторизация Яндекса (надёжное файловое хранение вместо UserDefaults)

    func saveYandexToken(_ token: String?) {
        guard let url = fileURL("ym_token") else { return }
        if let token { try? token.data(using: .utf8)?.write(to: url, options: .atomic) }
        else { try? FileManager.default.removeItem(at: url) }
    }
    func loadYandexToken() -> String? {
        let t = readString("ym_token")
        return (t?.isEmpty == false) ? t : nil
    }
    func saveYandexUID(_ uid: String?) {
        guard let url = fileURL("ym_uid") else { return }
        if let uid { try? uid.data(using: .utf8)?.write(to: url, options: .atomic) }
        else { try? FileManager.default.removeItem(at: url) }
    }
    func loadYandexUID() -> String? {
        let u = readString("ym_uid")
        return (u?.isEmpty == false) ? u : nil
    }

    // MARK: - Pending action (виджет → приложение)

    func savePendingAction(_ action: PendingAction) {
        writeString(action.rawValue, to: "pending")
        logger.debug("Pending action: \(action.rawValue)")
    }

    func loadPendingAction() -> PendingAction {
        guard let raw = readString("pending"),
              let action = PendingAction(rawValue: raw) else { return .none }
        return action
    }
}
