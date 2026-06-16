import Foundation
import CoreFoundation
import AppKit
import OSLog

// Мост к приватному MediaRemote.framework.
// MPNowPlayingInfoCenter работает только для данных самого приложения;
// чтобы читать трек любого другого приложения (Яндекс Музыка и т.д.)
// нужен MRMediaRemoteGetNowPlayingInfo из MediaRemote.
struct MediaRemoteHelper {

    private static let logger = Logger(
        subsystem: "com.yandexmusic.widget",
        category: "NowPlaying"
    )

    // MARK: - Function types

    private typealias GetInfoFn     = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias GetPlayingFn  = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void

    // MARK: - Framework + symbols (loaded once)

    private static let mrBundle: CFBundle? = {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework"
        guard let url = CFURLCreateWithFileSystemPath(
            kCFAllocatorDefault,
            path as CFString,
            CFURLPathStyle.cfurlposixPathStyle,
            true
        ) else { return nil }
        return CFBundleCreate(kCFAllocatorDefault, url)
    }()

    private static let getInfoFn: GetInfoFn? = {
        guard let b = mrBundle,
              let ptr = CFBundleGetFunctionPointerForName(
                  b, "MRMediaRemoteGetNowPlayingInfo" as CFString) else {
            return nil
        }
        return unsafeBitCast(ptr, to: GetInfoFn.self)
    }()

    private static let getPlayingFn: GetPlayingFn? = {
        guard let b = mrBundle,
              let ptr = CFBundleGetFunctionPointerForName(
                  b, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString) else {
            return nil
        }
        return unsafeBitCast(ptr, to: GetPlayingFn.self)
    }()

    static var isAvailable: Bool { getInfoFn != nil }

    // MARK: - Public API

    /// Асинхронно возвращает текущий трек из системного Now Playing.
    /// Не требует знания о том, запущена ли Яндекс Музыка — MediaRemote
    /// возвращает данные любого воспроизводящего приложения.
    static func fetchTrackInfo(completion: @escaping (TrackInfo) -> Void) {
        guard let fn = getInfoFn else {
            logger.warning("MediaRemote недоступен")
            completion(.empty)
            return
        }

        fn(DispatchQueue.main) { info in
            guard !info.isEmpty,
                  let title = info["Title"] as? String, !title.isEmpty else {
                completion(.empty)
                return
            }

            // Дополнительно проверяем системный статус через отдельный API
            if let playingFn = getPlayingFn {
                playingFn(DispatchQueue.main) { systemIsPlaying in
                    completion(makeTrackInfo(from: info, systemIsPlaying: systemIsPlaying))
                }
            } else {
                completion(makeTrackInfo(from: info, systemIsPlaying: nil))
            }
        }
    }

    // MARK: - Internal helpers

    static func makeTrackInfo(from info: [String: Any], systemIsPlaying: Bool? = nil) -> TrackInfo {
        let rawTitle  = info["Title"]  as? String ?? ""
        let rawArtist = info["Artist"] as? String ?? ""
        let title  = rawTitle.isEmpty  ? Constants.Media.fallbackTitle  : rawTitle
        let artist = rawArtist.isEmpty ? Constants.Media.fallbackArtist : rawArtist
        let album  = info["Album"] as? String ?? ""

        // PlaybackRate может прийти как Double, Int или Float
        let rate: Double = {
            if let d = info["PlaybackRate"] as? Double { return d }
            if let i = info["PlaybackRate"] as? Int    { return Double(i) }
            if let f = info["PlaybackRate"] as? Float  { return Double(f) }
            return 0.0
        }()

        let isPlay  = systemIsPlaying ?? (rate > 0.0)
        let artwork = artworkPNG(from: info)

        return TrackInfo(
            id:          "\(title)-\(artist)",
            title:       title,
            artist:      artist,
            album:       album,
            artworkData: artwork,
            isPlaying:   isPlay,
            lastUpdated: Date()
        )
    }

    private static func artworkPNG(from info: [String: Any]) -> Data? {
        guard let raw = info["ArtworkData"] as? Data else { return nil }
        // Нормализуем до PNG через NSImage (MediaRemote может отдавать JPEG/BMP)
        guard let image = NSImage(data: raw) else { return raw }
        guard let tiff = image.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff) else { return raw }
        return rep.representation(using: .png, properties: [:]) ?? raw
    }
}
