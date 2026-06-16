import Foundation
import WidgetKit
import OSLog

final class WidgetDataStore {
    static let shared = WidgetDataStore()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.yandexmusic.widget",
        category: "Storage"
    )
    private let appGroup = AppGroupManager.shared

    private init() {}

    // MARK: - Track

    func saveTrack(_ track: TrackInfo) {
        appGroup.saveTrack(track)
        logger.info("Track saved to WidgetDataStore: \(track.title)")
    }

    func loadTrack() -> TrackInfo {
        let track = appGroup.loadTrack()
        logger.debug("Track loaded from WidgetDataStore: \(track.title)")
        return track
    }

    // MARK: - Playback State

    func savePlaybackState(isPlaying: Bool) {
        var track = loadTrack()
        track = TrackInfo(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            artworkData: track.artworkData,
            isPlaying: isPlaying,
            lastUpdated: Date()
        )
        appGroup.saveTrack(track)
        logger.info("Playback state saved: isPlaying=\(isPlaying)")
    }

    func loadPlaybackState() -> Bool {
        return loadTrack().isPlaying
    }

    // MARK: - Widget Reload

    func reloadWidgetTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
        appGroup.saveSyncStatus(.synced)
        logger.info("Widget timelines reloaded")
    }
}
