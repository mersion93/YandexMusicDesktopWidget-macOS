import Foundation
import AppKit
import CoreGraphics
import OSLog

// NX key type constants (from IOKit/hidsystem/ev_keymap.h)
let NX_KEYTYPE_PLAY: Int32     = 16
let NX_KEYTYPE_NEXT: Int32     = 17
let NX_KEYTYPE_PREVIOUS: Int32 = 18

// NX_SUBTYPE_AUX_CONTROL_BUTTONS = 8
private let NX_SUBTYPE_AUX: Int16 = 8

final class MediaKeyController {
    static let shared = MediaKeyController()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.yandexmusic.widget",
        category: "Playback"
    )

    private init() {}

    // MARK: - Public API

    // MRCommand ID (см. MediaRemote) — отправляются адаптером прямо текущему плееру.
    private let kMRTogglePlayPause = 2
    private let kMRNextTrack       = 4
    private let kMRPreviousTrack   = 5

    func playPause() {
        if NowPlayingStreamer.shared.isAvailable {
            logger.info("Play/Pause → adapter command")
            NowPlayingStreamer.shared.sendCommand(kMRTogglePlayPause)
        } else {
            logger.info("Sending Play/Pause media key")
            sendMediaKey(keyType: NX_KEYTYPE_PLAY)
        }
        AppGroupManager.shared.saveLastCommand(.playPause)
    }

    func nextTrack() {
        AppGroupManager.shared.saveLastCommand(.nextTrack)
        switchTrack(mediaKey: NX_KEYTYPE_NEXT, command: kMRNextTrack, label: "Next")
    }

    func previousTrack() {
        AppGroupManager.shared.saveLastCommand(.previousTrack)
        switchTrack(mediaKey: NX_KEYTYPE_PREVIOUS, command: kMRPreviousTrack, label: "Previous")
    }

    /// Переключение трека гибридно: СНАЧАЛА глобальная медиа-клавиша — она срабатывает
    /// мгновенно, когда системным «Сейчас играет» владеет активный плеер (обычный
    /// случай) → попап обновляется без задержки от запуска perl. Если же клавишу
    /// перехватил другой плеер (Apple Music, видео в браузере) и за 0.6 с трек так и не
    /// сменился — досылаем команду адаптером прямо текущему плееру (надёжный фолбэк).
    private func switchTrack(mediaKey: Int32, command: Int, label: String) {
        sendMediaKey(keyType: mediaKey)
        guard NowPlayingStreamer.shared.isAvailable else { return }
        let before = NowPlayingService.shared.currentTrack.title
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard NowPlayingService.shared.currentTrack.title == before else { return }
            self.logger.info("\(label): клавиша не сменила трек → адаптер")
            NowPlayingStreamer.shared.sendCommand(command)
        }
    }

    // MARK: - Private

    private func sendMediaKey(keyType: Int32) {
        // Key-down: flags = 0xa << 8 combined with key code << 16
        let keyDownData1 = (Int(keyType) << 16) | (0xa << 8)
        // Key-up: flags = 0xb << 8 combined with key code << 16
        let keyUpData1   = (Int(keyType) << 16) | (0xb << 8)

        let keyDown = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: NX_SUBTYPE_AUX,
            data1: keyDownData1,
            data2: -1
        )

        let keyUp = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xb00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: NX_SUBTYPE_AUX,
            data1: keyUpData1,
            data2: -1
        )

        keyDown?.cgEvent?.post(tap: .cghidEventTap)
        keyUp?.cgEvent?.post(tap: .cghidEventTap)

        logger.debug("Media key sent: keyType=\(keyType)")
    }
}
