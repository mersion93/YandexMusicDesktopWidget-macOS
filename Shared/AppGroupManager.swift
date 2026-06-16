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

    // Обложку держим ОТДЕЛЬНЫМ файлом, а не внутри track.json. Тогда метаданные
    // (название/пауза/лайк) — это крошечный JSON, который пишется часто и дёшево,
    // а тяжёлая обложка (~70–150 КБ) переписывается ТОЛЬКО когда реально меняется.
    private var lastArtwork: Data?

    func saveTrack(_ track: TrackInfo) {
        guard let url = fileURL("track.json") else {
            logger.error("Контейнер недоступен — трек не сохранён")
            return
        }
        var meta = track
        let art = track.artworkData
        meta.artworkData = nil   // обложка — отдельным файлом
        do {
            let data = try JSONEncoder().encode(meta)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Ошибка сохранения трека: \(error.localizedDescription)")
        }
        // Обложка: пишем только когда реально изменилась (сравнение байт — дёшево).
        if let artURL = fileURL("artwork.dat"), art != lastArtwork {
            lastArtwork = art
            if let art, !art.isEmpty { try? art.write(to: artURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: artURL) }
        }
    }

    func loadTrack() -> TrackInfo {
        guard let url = fileURL("track.json"),
              let data = try? Data(contentsOf: url),
              var track = try? JSONDecoder().decode(TrackInfo.self, from: data) else {
            return TrackInfo.notRunning
        }
        // Подцепляем обложку из отдельного файла.
        if let artURL = fileURL("artwork.dat"), let art = try? Data(contentsOf: artURL), !art.isEmpty {
            track.artworkData = art
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
