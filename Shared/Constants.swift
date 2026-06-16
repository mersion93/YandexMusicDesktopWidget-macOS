import Foundation
import CoreGraphics

enum Constants {
    enum AppGroup {
        static let identifier = "group.com.yandexmusic.widget"
    }

    enum UserDefaultsKeys {
        static let trackTitle       = "track_title"
        static let trackArtist      = "track_artist"
        static let trackAlbum       = "track_album"
        static let artworkData      = "artwork_data"
        static let isPlaying        = "is_playing"
        static let lastUpdated      = "last_updated"
        static let lastCommand      = "last_command"
        static let widgetSyncStatus = "widget_sync_status"
        static let likeState        = "like_state"
        static let pendingAction    = "pending_action"
    }

    enum Timing {
        static let nowPlayingRefreshInterval: TimeInterval     = 1.0
        static let widgetTimelineRefreshInterval: TimeInterval = 15.0
    }

    enum Players {
        static let yandex  = "ru.yandex.desktop.music"
        static let spotify = "com.spotify.client"
        static let apple   = "com.apple.Music"

        /// Поддерживаемые плееры (их «Сейчас играет» показываем в виджете).
        static let supported: Set<String> = [yandex, spotify, apple]

        static func name(for bundleID: String) -> String {
            switch bundleID {
            case yandex:  return "Яндекс Музыка"
            case spotify: return "Spotify"
            case apple:   return "Apple Music"
            default:      return "Музыка"
            }
        }
    }

    enum Media {
        static let yandexMusicBundleID = "ru.yandex.desktop.music"
        static let fallbackTitle       = "Яндекс Музыка"
        static let fallbackArtist      = "Нет информации о треке"
        static let fallbackAlbum       = ""
        static let notRunningTitle     = "Яндекс Музыка"
        static let notRunningArtist    = "Запустите Яндекс Музыку"
    }

    enum UI {
        static let cornerRadius: CGFloat        = 16
        static let artworkCornerRadius: CGFloat = 12
        static let buttonSize: CGFloat          = 32
        static let smallArtworkSize: CGFloat    = 56
        static let mediumArtworkSize: CGFloat   = 72
        static let largeArtworkSize: CGFloat    = 160
    }
}
