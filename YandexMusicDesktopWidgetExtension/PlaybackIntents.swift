import AppIntents
import WidgetKit
import OSLog

// Виджет работает в sandboxed-процессе. CGEvent.post(tap: .cghidEventTap) из
// sandboxed-контекста тихо блокируется macOS — кнопки не работают.
// Решение: ВСЕ команды пишутся в App Group файл, основное приложение (без sandbox)
// читает их каждые 2 секунды и выполняет через MediaKeyController / AX.

private let logger = Logger(subsystem: "com.yandexmusic.widget.extension", category: "Intent")

// MARK: - Play/Pause Intent

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Воспроизведение / Пауза"
    static let description = IntentDescription("Переключает воспроизведение в Яндекс Музыке")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("PlayPauseIntent → pending queue")
        AppGroupManager.shared.savePendingAction(.playPause)
        AppGroupManager.shared.saveLastCommand(.playPause)
        // Оптимистично переключаем иконку СРАЗУ (приложение подтвердит реальный статус
        // через ~0.5с). Иначе иконка play/pause обновлялась с задержкой.
        AppGroupManager.shared.toggleSavedPlaying()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - Next Track Intent

struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Следующий трек"
    static let description = IntentDescription("Переключает на следующий трек в Яндекс Музыке")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("NextTrackIntent → pending queue")
        AppGroupManager.shared.savePendingAction(.nextTrack)
        AppGroupManager.shared.saveLastCommand(.nextTrack)
        // НЕ перезагружаем таймлайн здесь — иначе виджет покажет ещё старый трек.
        // Основное приложение обновит виджет, когда придут данные нового трека.
        return .result()
    }
}

// MARK: - Previous Track Intent

struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Предыдущий трек"
    static let description = IntentDescription("Переключает на предыдущий трек в Яндекс Музыке")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("PreviousTrackIntent → pending queue")
        AppGroupManager.shared.savePendingAction(.previousTrack)
        AppGroupManager.shared.saveLastCommand(.previousTrack)
        return .result()
    }
}

// MARK: - Repeat Intent

struct RepeatIntent: AppIntent {
    static let title: LocalizedStringResource = "Повтор"
    static let description = IntentDescription("Переключает режим повтора в Яндекс Музыке")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppGroupManager.shared.savePendingAction(.repeatMode)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - Shuffle Intent

struct ShuffleIntent: AppIntent {
    static let title: LocalizedStringResource = "Перемешать"
    static let description = IntentDescription("Переключает случайный порядок в Яндекс Музыке")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppGroupManager.shared.savePendingAction(.shuffle)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - Open Yandex Music Intent

struct OpenYandexMusicIntent: AppIntent {
    static let title: LocalizedStringResource = "Открыть Яндекс Музыку"
    static let description = IntentDescription("Открывает приложение Яндекс Музыка")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppGroupManager.shared.savePendingAction(.openApp)
        return .result()
    }
}

// MARK: - Like Intent

struct LikeIntent: AppIntent {
    static let title: LocalizedStringResource = "Нравится"
    static let description = IntentDescription("Добавляет текущий трек в «Мне нравится»")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("LikeIntent → pending queue")
        AppGroupManager.shared.savePendingAction(.like)
        AppGroupManager.shared.saveLastCommand(.like)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - Dislike Intent

struct DislikeIntent: AppIntent {
    static let title: LocalizedStringResource = "Не нравится"
    static let description = IntentDescription("Отмечает текущий трек как «Не нравится»")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("DislikeIntent → pending queue")
        AppGroupManager.shared.savePendingAction(.dislike)
        AppGroupManager.shared.saveLastCommand(.dislike)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
