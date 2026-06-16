import Foundation
import OSLog

// Читает системное «Сейчас играет» через mediaremote-adapter (обход блокировки
// MediaRemote в macOS 15.4+). Держит ОДИН постоянный процесс `stream` и получает
// события push'ем — это почти нулевой CPU в простое (в отличие от опроса).
// Работает при любом состоянии окна плеера. Поддерживает ЯМ/Spotify/Apple Music.

final class NowPlayingStreamer {
    static let shared = NowPlayingStreamer()

    /// Срабатывает при обновлении трека (на главном потоке).
    var onUpdate: ((TrackInfo) -> Void)?
    /// Срабатывает, когда «Сейчас играет» пусто / не от поддерживаемого плеера.
    var onCleared: (() -> Void)?

    private let logger = Logger(subsystem: "com.yandexmusic.widget", category: "Streamer")
    private var task: Process?
    private var buffer = Data()
    private var state: [String: Any] = [:]   // только в очереди readabilityHandler

    private init() {}

    var isAvailable: Bool { adapterPaths() != nil }

    private func adapterPaths() -> (pl: String, framework: String)? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let pl = res.appendingPathComponent("MediaRemoteAdapter/mediaremote-adapter.pl").path
        let fw = res.appendingPathComponent("MediaRemoteAdapter/MediaRemoteAdapter.framework").path
        let fm = FileManager.default
        return (fm.fileExists(atPath: pl) && fm.fileExists(atPath: fw)) ? (pl, fw) : nil
    }

    // MARK: - Жизненный цикл процесса

    func start() {
        guard task == nil, let paths = adapterPaths() else {
            if adapterPaths() == nil { logger.warning("Адаптер MediaRemote не найден") }
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [paths.pl, paths.framework, "stream"]

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice   // не блокируемся на невычитанном stderr

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ingest(chunk)
        }
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.logger.warning("Стрим завершился — перезапуск через 2с")
            DispatchQueue.main.async {
                self.task = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.start() }
            }
        }
        do {
            try proc.run()
            task = proc
            logger.info("Стрим Now Playing запущен")
        } catch {
            logger.error("Не удалось запустить стрим: \(error.localizedDescription)")
        }
    }

    func stop() {
        task?.terminationHandler = nil
        task?.terminate()
        task = nil
    }

    /// Быстрый одноразовый снимок (`get`) — для мгновенного отклика после переключения трека.
    func pollNow() {
        guard let paths = adapterPaths() else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [paths.pl, paths.framework, "get"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return }
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            watchdog.cancel()
            p.waitUntilExit()
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let track = self.makeTrack(from: obj) else { return }
            DispatchQueue.main.async { self.onUpdate?(track) }
        }
    }

    /// Перемотка трека на позицию в секундах (через `seek`, мкс).
    func seek(toSeconds seconds: Double) {
        guard let paths = adapterPaths(), seconds >= 0 else { return }
        // seek 0 адаптер игнорирует (проверка `if ($position)`), поэтому минимум 1 мкс ≈ начало.
        let micros = max(1, Int(seconds * 1_000_000))
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [paths.pl, paths.framework, "seek", "\(micros)"]
            p.standardOutput = Pipe(); p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return }
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: watchdog)
            p.waitUntilExit()
            watchdog.cancel()
        }
    }

    // MARK: - Парсинг потока (всё в очереди readabilityHandler — без гонок)

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty else { continue }
            handleLine(lineData)
        }
        if buffer.count > 1_000_000 { buffer.removeAll() }   // защита от разрастания
    }

    private func handleLine(_ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return }
        let isDiff = (obj["diff"] as? Bool) ?? false

        // Пустое служебное сообщение — игнор (не сбрасываем состояние).
        if !isDiff && payload.isEmpty { return }
        // Чужой плеер — игнор (сохраняем последнее состояние поддерживаемого).
        if let b = payload["bundleIdentifier"] as? String, !Constants.Players.supported.contains(b) { return }
        // Смена трека — сбрасываем обложку, чтобы не показать чужую.
        if let inTitle = payload["title"] as? String, inTitle != (state["title"] as? String) {
            state["artworkData"] = nil
        }
        for (k, v) in payload {
            if k == "artworkData" {
                if let s = v as? String, !s.isEmpty { state[k] = s }   // пустую не затираем
            } else {
                state[k] = v
            }
        }

        guard let track = makeTrack(from: state) else { return }
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(track) }
    }

    /// Строит TrackInfo из словаря (общего для stream-состояния и одноразового get).
    private func makeTrack(from d: [String: Any]) -> TrackInfo? {
        guard let bundle = d["bundleIdentifier"] as? String,
              Constants.Players.supported.contains(bundle),
              let title = d["title"] as? String, !title.isEmpty else { return nil }
        let artist   = (d["artist"] as? String) ?? ""
        let album    = (d["album"] as? String) ?? ""
        let playing  = (d["playing"] as? Bool) ?? true
        let duration = (d["duration"] as? Double) ?? 0
        var artwork: Data?
        if let b64 = d["artworkData"] as? String, !b64.isEmpty {
            artwork = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
        }
        // Реальная позиция: elapsedTime — позиция на момент timestamp; добавляем дрейф до «сейчас».
        var elapsed = (d["elapsedTime"] as? Double) ?? 0
        if playing, let ts = d["timestamp"] as? String, let tsDate = Self.parseTimestamp(ts) {
            let drift = Date().timeIntervalSince(tsDate)
            if drift > 0 && drift < 3600 { elapsed += drift }   // разумный дрейф
        }
        if duration > 0 { elapsed = min(max(0, elapsed), duration) } else { elapsed = max(0, elapsed) }

        var t = TrackInfo(
            id: "\(title)-\(artist)",
            title: title,
            artist: artist.isEmpty ? Constants.Media.fallbackArtist : artist,
            album: album,
            artworkData: artwork,
            isPlaying: playing,
            lastUpdated: Date(),
            likeState: .none,
            duration: duration,
            elapsed: elapsed
        )
        t.playerBundleID = bundle
        return t
    }

    private static func parseTimestamp(_ s: String) -> Date? {
        let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: s) { return d }
        let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime]
        return b.date(from: s)
    }
}
