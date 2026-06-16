import Foundation

/// Оценка трека пользователем в Яндекс Музыке.
enum LikeState: String, Codable {
    case none      // нет оценки
    case liked     // «Мне нравится»
    case disliked  // «Не нравится»
}

struct TrackInfo: Codable, Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var artworkData: Data?
    var isPlaying: Bool
    var lastUpdated: Date
    var likeState: LikeState = .none
    var duration: TimeInterval = 0   // полная длина трека в секундах, 0 если неизвестно
    var elapsed: TimeInterval = 0    // реальная позиция в треке на момент lastUpdated
    var playerBundleID: String = ""  // какой плеер сейчас играет (ЯМ/Spotify/Apple Music)

    /// Лайк/дизлайк доступны только для Яндекс Музыки (через её API/AX).
    var isYandex: Bool { playerBundleID == "ru.yandex.desktop.music" || playerBundleID.isEmpty }

    /// Нет реального трека (заглушка/не запущено) — виджет показывает чистый пустой вид.
    var isPlaceholder: Bool {
        title.isEmpty
        || title == Constants.Media.notRunningTitle
        || title == Constants.Media.fallbackTitle
        || artist == Constants.Media.fallbackArtist
        || artist == Constants.Media.notRunningArtist
    }

    static let empty = TrackInfo(
        id: UUID().uuidString,
        title: Constants.Media.fallbackTitle,
        artist: Constants.Media.fallbackArtist,
        album: Constants.Media.fallbackAlbum,
        artworkData: nil,
        isPlaying: false,
        lastUpdated: Date()
    )

    static let notRunning = TrackInfo(
        id: "not-running",
        title: Constants.Media.notRunningTitle,
        artist: Constants.Media.notRunningArtist,
        album: "",
        artworkData: nil,
        isPlaying: false,
        lastUpdated: Date()
    )

    var isYandexMusicRunning: Bool {
        id != "not-running"
    }
}

enum PlaybackCommand: String, Codable {
    case playPause     = "Play/Pause"
    case nextTrack     = "Next Track"
    case previousTrack = "Previous Track"
    case like          = "Like"
    case dislike       = "Dislike"
    case none          = "None"
}

/// Действие, поставленное виджетом в очередь для выполнения основным приложением.
/// CGEvent.post из sandboxed extension не работает, поэтому ВСЕ команды идут
/// через App Group файл, основное приложение их читает и выполняет.
enum PendingAction: String, Codable {
    case like
    case dislike
    case playPause
    case nextTrack
    case previousTrack
    case repeatMode
    case shuffle
    case openApp
    case none
}

enum WidgetSyncStatus: String, Codable {
    case synced  = "Synced"
    case stale   = "Stale"
    case unknown = "Unknown"
}

// MARK: - Настройки оформления виджета (общие для приложения и расширения)

struct WidgetSettings: Codable, Equatable {
    var accent: String       = "yellow"   // имя пресета из AccentPalette
    var background: String   = "blur"      // "blur" | "solid"
    var showArtist: Bool     = true
    var showLikeButtons: Bool = true

    static let `default` = WidgetSettings()
}

/// Палитра акцентных цветов (RGB-компоненты, чтобы не тянуть SwiftUI в Shared).
enum AccentPalette {
    static let presets: [(name: String, title: String, r: Double, g: Double, b: Double)] = [
        ("yellow", "Жёлтый",    1.00, 0.84, 0.00),
        ("white",  "Белый",     0.95, 0.95, 0.96),
        ("pink",   "Розовый",   1.00, 0.41, 0.71),
        ("blue",   "Синий",     0.30, 0.60, 1.00),
        ("green",  "Зелёный",   0.30, 0.85, 0.45),
        ("purple", "Фиолетовый",0.66, 0.45, 1.00),
        ("orange", "Оранжевый", 1.00, 0.55, 0.15),
        ("red",    "Красный",   1.00, 0.36, 0.33)
    ]
    static func rgb(_ name: String) -> (r: Double, g: Double, b: Double) {
        if let p = presets.first(where: { $0.name == name }) { return (p.r, p.g, p.b) }
        return (1.00, 0.84, 0.00)
    }
}
