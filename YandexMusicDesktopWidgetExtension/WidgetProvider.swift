import WidgetKit
import SwiftUI
import AppIntents
import OSLog

struct MusicEntry: TimelineEntry {
    let date: Date
    let track: TrackInfo
    let configuration: ConfigurationAppIntent
    var settings: WidgetSettings = .default
}

struct WidgetProvider: AppIntentTimelineProvider {
    private let logger = Logger(
        subsystem: "com.yandexmusic.widget.extension",
        category: "Widget"
    )

    func placeholder(in context: Context) -> MusicEntry {
        MusicEntry(
            date: Date(),
            track: TrackInfo(
                id: "placeholder",
                title: "Красивая песня",
                artist: "Исполнитель",
                album: "Альбом",
                artworkData: nil,
                isPlaying: true,
                lastUpdated: Date()
            ),
            configuration: ConfigurationAppIntent()
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> MusicEntry {
        let track = AppGroupManager.shared.loadTrack()
        logger.debug("Снимок виджета: \(track.title)")
        return MusicEntry(date: Date(), track: track, configuration: configuration,
                          settings: AppGroupManager.shared.loadWidgetSettings())
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<MusicEntry> {
        let now   = Date()
        // Виджет ТОЛЬКО ЧИТАЕТ из App Group — основное приложение (без sandbox)
        // пишет данные, виджет никогда не перезаписывает их.
        let track = AppGroupManager.shared.loadTrack()

        logger.debug("Timeline: «\(track.title)» — \(track.artist), играет=\(track.isPlaying)")

        let entry = MusicEntry(date: now, track: track, configuration: configuration,
                               settings: AppGroupManager.shared.loadWidgetSettings())

        // Быстрый путь: приложение пушит reloadAllTimelines() при смене трека
        // (мгновенно). Но система иногда ОТБРАСЫВАЕТ пуш под нагрузкой — а пуши
        // одного типа троттлятся пачкой, поэтому бэкап-пуши не всегда спасают.
        // Надёжный запасной механизм — таймлайн-«пульс» (другого типа, от пушей
        // не зависит). 15с: в обычном случае всё мгновенно от пуша, а отброшенный
        // пуш виджет сам подхватит максимум за 15с — без «застоя» до минуты.
        // Короче 15с не делаем: частый пульс жжёт бюджет WidgetKit и система
        // начинает резать обновления (это и был исходный «тормоз»).
        let heartbeat = now.addingTimeInterval(15)
        return Timeline(entries: [entry], policy: .after(heartbeat))
    }
}

// MARK: - Configuration Intent (параметры в редакторе виджета)

enum WidgetAccentChoice: String, AppEnum {
    case yellow, white, pink, blue, green, purple, orange, red
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Акцентный цвет" }
    static var caseDisplayRepresentations: [WidgetAccentChoice: DisplayRepresentation] {
        [.yellow: "Жёлтый", .white: "Белый", .pink: "Розовый", .blue: "Синий",
         .green: "Зелёный", .purple: "Фиолетовый", .orange: "Оранжевый", .red: "Красный"]
    }
}

enum WidgetBackgroundChoice: String, AppEnum {
    case blurred, dark
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Фон" }
    static var caseDisplayRepresentations: [WidgetBackgroundChoice: DisplayRepresentation] {
        [.blurred: "Размытая обложка", .dark: "Тёмный"]
    }
}

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Оформление"
    static let description = IntentDescription("Текущий трек (Яндекс Музыка, Spotify, Apple Music) с управлением")

    @Parameter(title: "Акцентный цвет", default: .yellow)
    var accent: WidgetAccentChoice

    @Parameter(title: "Фон", default: .blurred)
    var background: WidgetBackgroundChoice

    @Parameter(title: "Показывать исполнителя", default: true)
    var showArtist: Bool

    @Parameter(title: "Кнопки лайка / дизлайка", default: true)
    var showLikeButtons: Bool

    /// Маппинг параметров редактора в общую модель оформления.
    var widgetSettings: WidgetSettings {
        WidgetSettings(accent: accent.rawValue,
                       background: background == .dark ? "solid" : "blur",
                       showArtist: showArtist,
                       showLikeButtons: showLikeButtons)
    }
}
