import Foundation
import AppKit
import CoreGraphics
import OSLog

// Читает текущий трек из Яндекс Музыки через несколько fallback-методов,
// так как ЯМ не регистрирует треки через стандартный MPNowPlayingInfoCenter.

enum TrackReadSource: String {
    case mediaRemote   = "MediaRemote"
    case windowTitle   = "Заголовок окна"
    case accessibility = "Accessibility"
    case none          = "—"
}

struct YMTrackReader {

    private static let logger = Logger(subsystem: "com.yandexmusic.widget", category: "YMReader")

    // MARK: - Player bar cache
    // findTransportButton обходит ВСЁ AX-дерево приложения (~30 уровней Electron-DOM).
    // После первого нахождения кэшируем AXUIElement плеера и читаем напрямую.
    // Кэш сбрасывается при смене PID или если элемент стал недоступен.

    private static let cacheLock = NSLock()
    private static var _cachedPID: pid_t = 0
    private static var _cachedPlayerBar: AXUIElement?

    private static func cachedPlayerBar(for pid: pid_t) -> AXUIElement? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard _cachedPID == pid, let el = _cachedPlayerBar else { return nil }
        // Проверяем валидность: если элемент уничтожен — вернём nil
        var r: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r) == .success else {
            _cachedPlayerBar = nil; return nil
        }
        return el
    }

    private static func setCachedPlayerBar(_ el: AXUIElement, for pid: pid_t) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        _cachedPID = pid; _cachedPlayerBar = el
    }

    static func invalidateCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        _cachedPID = 0; _cachedPlayerBar = nil
    }

    // MARK: - Public

    static func readCurrentTrack(pid: pid_t) -> (track: TrackInfo, source: TrackReadSource)? {
        // 1. Accessibility первым — читаем из плеера напрямую, независимо от текущей страницы ЯМ.
        //    Заголовок окна показывает название страницы (напр. "Яндекс Плюс"), а не трека.
        if AXIsProcessTrusted(), let t = readFromAccessibility(pid: pid) {
            logger.debug("Трек через AX: «\(t.title, privacy: .public)» / \(t.artist, privacy: .public)")
            return (t, .accessibility)
        }

        // 2. Заголовок окна — запасной вариант когда AX недоступен
        let titles = allWindowTitles(pid: pid)
        if let t = parseWindowTitles(titles) {
            logger.debug("Трек из заголовка окна: «\(t.title, privacy: .public)» / \(t.artist, privacy: .public)")
            return (t, .windowTitle)
        }

        return nil
    }

    static var isScreenRecordingGranted: Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        let selfPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        return list.contains { win in
            guard let pid = win[kCGWindowOwnerPID as String] as? Int32, pid != selfPID else { return false }
            return win[kCGWindowName as String] is String
        }
    }

    static func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        openSettings(pane: "Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        openSettings(pane: "Privacy_ScreenCapture")
    }

    private static func openSettings(pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    static var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    // MARK: - Window title

    private static func allWindowTitles(pid: pid_t) -> [String] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return list.compactMap { win -> String? in
            guard let ownerPID = win[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
                  let name = win[kCGWindowName as String] as? String, !name.isEmpty else { return nil }
            return name
        }
    }

    private static func parseWindowTitles(_ titles: [String]) -> TrackInfo? {
        titles.compactMap { parseWindowTitle($0) }.first
    }

    private static func parseWindowTitle(_ raw: String) -> TrackInfo? {
        var s = raw
            .replacingOccurrences(of: " – ", with: " — ")
            .replacingOccurrences(of: " - ", with: " — ")
            .replacingOccurrences(of: " | ", with: " — ")
            .replacingOccurrences(of: " · ", with: " — ")

        for suffix in [" — Яндекс Музыка", " — Яндекс.Музыка", " — Yandex Music",
                       " — Yandex.Music", " — YANDEX MUSIC"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)); break }
        }
        s = s.trimmingCharacters(in: .whitespaces)

        let lower = s.lowercased()
        guard !lower.isEmpty,
              lower != "яндекс музыка", lower != "яндекс.музыка",
              lower != "yandex music", lower != "yandex.music",
              lower != "untitled",
              !lower.contains("собираем музыку"),
              !lower.contains("моя волна"),
              // Страницы ЯМ, не являющиеся треками
              !lower.contains("яндекс плюс"),
              !lower.contains("yandex plus"),
              !lower.contains("профиль"),
              !lower.contains("настройки"),
              !lower.contains("подписк"),
              !lower.contains("коллекци") else { return nil }

        let parts = s.components(separatedBy: " — ")
                     .map { cleanName($0.trimmingCharacters(in: .whitespaces)) }
                     .filter { !$0.isEmpty }
        let title  = parts.first ?? cleanName(s)
        let artist = parts.count >= 2 ? parts[1] : Constants.Media.fallbackArtist
        guard title.count > 1 else { return nil }

        return TrackInfo(id: "\(title)-\(artist)", title: title, artist: artist,
                         album: parts.count >= 3 ? parts[2] : "",
                         artworkData: nil, isPlaying: true, lastUpdated: Date())
    }

    // MARK: - Accessibility

    private static func readFromAccessibility(pid: pid_t) -> TrackInfo? {
        let app = AXUIElementCreateApplication(pid)
        // kAXDescriptionAttribute обновляется сразу при смене трека — используем его как
        // основной источник названия. URL-ссылки могут содержать историю/очередь (стale-данные).
        if let t = readTrackUnified(app: app, pid: pid) { return t }
        // Запасной путь (полноэкранный плеер и пр., где кнопки pleera не находятся):
        // сканируем всё дерево и берём ПЕРВЫЙ кластер «Трек …» + «Артист …».
        if let t = readTrackWholeTree(app: app) { return t }
        return nil
    }

    /// Сканирует всё дерево приложения и собирает первый встреченный трек:
    /// первая метка «Трек …»/«Сингл …»/… → название, идущие за ней «Артист …» → исполнители.
    /// Работает независимо от режима окна (обычный/полноэкранный плеер).
    private static func readTrackWholeTree(app: AXUIElement) -> TrackInfo? {
        var title: String?
        var artists: [String] = []
        var stop = false

        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth < 22, !stop else { return }
            var descRef: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef) == .success,
               let desc = descRef as? String, !desc.isEmpty {
                if hasArtistPrefix(desc) {
                    if title != nil {
                        let name = cleanName(desc)
                        if !name.isEmpty && !isNoise(name) && !artists.contains(name) { artists.append(name) }
                    }
                } else if hasMetaPrefix(desc) {
                    let stripped = cleanName(desc)
                    if !stripped.isEmpty && !isNoise(stripped) {
                        if title == nil {
                            title = stripped               // первая метка трека — это текущий
                        } else {
                            stop = true; return            // следующий трек — конец кластера
                        }
                    }
                }
            }
            var childRef: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childRef) == .success,
                  let children = childRef as? [AXUIElement] else { return }
            for child in children { walk(child, depth + 1); if stop { return } }
        }
        walk(app, 0)

        guard let t = title, !t.isEmpty else { return nil }
        let artist = artists.isEmpty ? Constants.Media.fallbackArtist : artists.joined(separator: ", ")
        let playing = detectIsPlaying(in: app)
        logger.debug("AX whole-tree: «\(t, privacy: .public)» — \(artist, privacy: .public)")
        return TrackInfo(id: "\(t)-\(artist)", title: t, artist: artist,
                         album: "", artworkData: nil, isPlaying: playing, lastUpdated: Date())
    }

    /// Объединённый метод: title и artist из kAXDescriptionAttribute потомков плеера,
    /// с подтверждением / fallback через music-application:// ссылки.
    private static func readTrackUnified(app: AXUIElement, pid: pid_t) -> TrackInfo? {
        guard let playerBar = resolvePlayerBar(app: app, pid: pid) else { return nil }

        // 1. Сканируем ПРЯМЫХ потомков плеера по kAXDescriptionAttribute.
        //    ЯМ ставит следующие метки:
        //      "Артист {name}"  → исполнитель (может повторяться при нескольких артистах)
        //      "Трек {title}"   → название трека
        //      "Сингл {title}", "Альбом {title}", "EP {title}" и т.п. → название трека
        //    Важно: "Артист {name}" нельзя использовать как title, поэтому обрабатываем отдельно.
        // РЕКУРСИВНО ищем по всему поддереву плеера элементы с описаниями
        // "Трек …" (название) и "Артист …" (исполнитель). В новой версии ЯМ это
        // AXLink, лежащие на 2 уровня глубже панели плеера, поэтому прямого
        // обхода детей недостаточно.
        var titleFromDesc: String?
        var artistParts:   [String] = []
        collectTrackDescriptions(el: playerBar, depth: 0, maxDepth: 6,
                                 title: &titleFromDesc, artists: &artistParts)
        let artistFromDesc: String? = artistParts.isEmpty ? nil : artistParts.joined(separator: ", ")

        // 2. Сканируем music-application:// ссылки в плеере.
        //    scanForMusicLinks сам снимает "Артист "/"Трек " префиксы с текста ссылок.
        var urlCandidates: [String] = []
        scanForMusicLinks(el: playerBar, depth: 0, maxDepth: 5, results: &urlCandidates)

        // 3. Определяем title и artist.
        let title: String
        var artist = Constants.Media.fallbackArtist

        if let knownTitle = titleFromDesc {
            title  = knownTitle
            // Приоритет: артист из AX description (точнее URL-кандидатов)
            if let knownArtist = artistFromDesc {
                artist = knownArtist
            } else if let idx = urlCandidates.firstIndex(where: {
                $0.lowercased() == knownTitle.lowercased()
            }), idx > 0 {
                artist = urlCandidates[idx - 1]
            } else if urlCandidates.count >= 2,
                      urlCandidates[1].lowercased() == knownTitle.lowercased() {
                artist = urlCandidates[0]
            } else if !urlCandidates.isEmpty {
                artist = urlCandidates[0]
            }
        } else if let knownArtist = artistFromDesc, !urlCandidates.isEmpty {
            // Артист есть из AX description, title берём из URL-кандидатов
            artist = knownArtist
            title  = urlCandidates.first(where: { $0.lowercased() != knownArtist.lowercased() })
                     ?? urlCandidates[0]
        } else if urlCandidates.count >= 2 {
            // Fallback: URL-кандидаты в DOM-порядке (артист первый, трек второй)
            artist = urlCandidates[0]
            title  = urlCandidates[1]
        } else {
            // Последний резерв — полный сбор текстов из плеера
            var texts: [String] = []; var links: [String] = []
            collectLinksAndTexts(from: playerBar, depth: 0, maxDepth: 10, links: &links, texts: &texts)
            let unique = (links + texts).filter { !isNoise($0) }
                .reduce(into: [String]()) { acc, s in
                    if !acc.contains(where: { $0.lowercased() == s.lowercased() }) { acc.append(s) }
                }
            guard let first = unique.first else { return nil }
            title = first
        }

        // Финальная страховка: снимаем любые оставшиеся префиксы с обоих полей
        let cleanTitle  = cleanName(title)
        let cleanArtist = cleanName(artist)
        guard !cleanTitle.isEmpty else { return nil }

        // Реальное состояние воспроизведения по кнопке плеера
        let playing = detectIsPlaying(in: playerBar)

        logger.debug("AX unified: «\(cleanTitle, privacy: .public)» — \(cleanArtist, privacy: .public), играет=\(playing)")
        return TrackInfo(id: "\(cleanTitle)-\(cleanArtist)", title: cleanTitle, artist: cleanArtist,
                        album: "", artworkData: nil, isPlaying: playing, lastUpdated: Date())
    }

    /// Определяет, играет ли музыка, по подписи кнопки воспроизведения внутри плеера.
    /// Когда трек ИГРАЕТ — кнопка предлагает «Пауза»; когда на ПАУЗЕ — «Воспроизвести».
    private static func detectIsPlaying(in playerBar: AXUIElement) -> Bool {
        var found: Bool?
        func scan(_ el: AXUIElement, _ depth: Int) {
            guard depth < 18, found == nil else { return }
            var roleRef: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            if roleRef as? String == "AXButton" {
                var d: AnyObject?; var t: AnyObject?
                AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &d)
                AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &t)
                let label = ((d as? String ?? "") + " " + (t as? String ?? "")).lowercased()
                if label.contains("пауз") || label.contains("pause") {
                    found = true; return            // кнопка «Пауза» → сейчас играет
                }
                if label.contains("воспроизв") || label.contains("play")
                    || label.contains("продолжить") || label.contains("слушать") {
                    found = false; return           // кнопка «Воспроизвести» → на паузе
                }
            }
            var c: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &c) == .success,
                  let children = c as? [AXUIElement] else { return }
            for child in children { scan(child, depth + 1) }
        }
        scan(playerBar, 0)
        return found ?? true   // если кнопку не нашли — считаем, что играет
    }

    /// Публичный доступ к панели плеера (кэшированной) для других контроллеров,
    /// чтобы сканировать только её поддерево вместо всего дерева приложения.
    static func playerBar(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        return resolvePlayerBar(app: app, pid: pid)
    }

    // Возвращает кэшированный playerBar или находит его обходом AX-дерева.
    private static func resolvePlayerBar(app: AXUIElement, pid: pid_t) -> AXUIElement? {
        if let cached = cachedPlayerBar(for: pid) { return cached }
        var anchor: AXUIElement?
        findTransportButton(el: app, depth: 0, maxDepth: 30, result: &anchor)
        guard let button = anchor, let bar = parentOf(button) else { return nil }
        setCachedPlayerBar(bar, for: pid)
        return bar
    }

    // MARK: - URL-based track finding
    //
    // В ЯМ (Electron) ссылки в плеере могут использовать схему music-application://.
    // Реальный порядок в DOM (проверено эмпирически): сначала ИСПОЛНИТЕЛЬ, потом ТРЕК.
    // Если kAXURLAttribute недоступен (JS-роутинг), метод вернёт nil и сработает fallback.

    private static func findTrackViaURLs(app: AXUIElement, pid: pid_t) -> TrackInfo? {
        guard let playerBar = resolvePlayerBar(app: app, pid: pid) else { return nil }

        // Ищем music-application:// ссылки ТОЛЬКО внутри [AXGroup] Плеер (Level 1 от prev-кнопки).
        // Подниматься выше нельзя — на Level 2+ находятся «Рекомендации моей волны»
        // с ссылками на станции (Zenøn, Это поп! …), которые не обновляются при смене трека.
        var candidates: [String] = []
        scanForMusicLinks(el: playerBar, depth: 0, maxDepth: 5, results: &candidates)

        guard candidates.count >= 2 else { return nil }

        // DOM-порядок: исполнитель первый, название трека второй
        let artist = candidates[0]
        let title  = candidates[1]
        logger.debug("AX URL-метод: «\(title, privacy: .public)» — \(artist, privacy: .public)")
        return TrackInfo(id: "\(title)-\(artist)", title: title, artist: artist,
                         album: candidates.count > 2 ? candidates[2] : "",
                         artworkData: nil, isPlaying: true, lastUpdated: Date())
    }

    /// Рекурсивно собирает по поддереву плеера название (из «Трек …»/«Сингл …»/…)
    /// и исполнителей (из «Артист …»). Это основной источник в новой версии ЯМ.
    private static func collectTrackDescriptions(el: AXUIElement, depth: Int, maxDepth: Int,
                                                 title: inout String?, artists: inout [String]) {
        guard depth < maxDepth else { return }

        var descRef: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef) == .success,
           let desc = descRef as? String, !desc.isEmpty {
            if hasArtistPrefix(desc) {
                let name = cleanName(desc)
                if !name.isEmpty && !isNoise(name) && !artists.contains(name) {
                    artists.append(name)
                }
            } else if title == nil, hasMetaPrefix(desc) {
                let stripped = cleanName(desc)
                if !stripped.isEmpty && !isNoise(stripped) {
                    title = stripped
                }
            }
        }

        var childRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return }
        for child in children {
            collectTrackDescriptions(el: child, depth: depth + 1, maxDepth: maxDepth,
                                     title: &title, artists: &artists)
        }
    }

    /// Собирает тексты AXLink с music-application:// URL в порядке DOM.
    /// Снимает accessibility-префиксы "Артист ", "Трек " с текста ссылок.
    private static func scanForMusicLinks(el: AXUIElement, depth: Int, maxDepth: Int,
                                          results: inout [String]) {
        guard depth < maxDepth, results.count < 3 else { return }

        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)

        if roleRef as? String == "AXLink" {
            if let url = linkURL(el), url.lowercased().hasPrefix("music-application"),
               let raw = linkText(el) {
                // ЯМ ставит "Артист {name}", "Трек {title}" на ссылки — снимаем префиксы
                let text = cleanName(raw)
                if !isNoise(text) && !results.contains(where: { $0.lowercased() == text.lowercased() }) {
                    results.append(text)
                }
            }
        }

        var childRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return }
        for child in children {
            scanForMusicLinks(el: child, depth: depth + 1, maxDepth: maxDepth, results: &results)
        }
    }

    private static func linkText(_ el: AXUIElement) -> String? {
        for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            var ref: AnyObject?
            if AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
               let s = ref as? String, !s.isEmpty { return s }
        }
        return nil
    }

    private static func linkURL(_ el: AXUIElement) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &ref) == .success else { return nil }
        if let s = ref as? String { return s }
        if let url = ref as? URL { return url.absoluteString }
        if CFGetTypeID(ref) == CFURLGetTypeID(),
           let url = (ref as! CFURL) as URL? { return url.absoluteString }
        return nil
    }

    // MARK: - Transport-button fallback

    private static let noisePatterns = [
        "яндекс музык", "yandex music", "поиск", "моя волна", "для вас",
        "тренд", "коллекци", "главная", "подкаст", "настройк", "очередь",
        "слушать", "скачать", "плейлист", "радио", "ещё", "меню", "избранное",
        "новинк", "чарт", "like", "dislike", "play", "pause", "next", "previous",
        "недавн", "рекоменд", "волна", "в стиле", "собираем музыку",
        "дневник звука", "яндекс плюс", "всё подряд", "артиста",
        // Элементы управления плеера
        "нравится", "не нравится", "громкост", "звук", "таймкод",
        "контекстное меню", "предыдущ", "следующ", "пауз", "воспроизв",
        "плеер", "секунд", "минут", "секунд",
        // Названия рекомендательных станций My Wave (не являются треками)
        "классическ", "тренирова", "душа требует", "радостно",
        "йо, рэп", "йо,рэп", "лето внутри", "эфир", "станция"
    ]

    private static func isNoise(_ s: String) -> Bool {
        let l = s.lowercased()
        if l.isEmpty || s.count < 2 || s.count > 120 { return true }
        if l.hasPrefix("http") || l.hasPrefix("javascript") { return true }
        if l.range(of: #"^-?\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return true }
        for p in noisePatterns where l.contains(p) { return true }
        return false
    }

    // Читает трек из AXGroup описания вида "Сингл Never Alone" → "Never Alone".
    // ЯМ ставит в AXDescription первого дочернего AXGroup плеера строку:
    //   «<тип> <название>» — "Сингл", "Альбом", "EP" и т.п.
    private static func findTrackViaPlayer(app: AXUIElement, pid: pid_t) -> TrackInfo? {
        guard let playerBar = resolvePlayerBar(app: app, pid: pid) else { return nil }

        // 1. Название трека из AXDescription прямого потомка Плеера
        //    "Сингл Never Alone" → стрипаем префикс → "Never Alone"
        var titleFromDesc: String?
        var childRef: AnyObject?
        if AXUIElementCopyAttributeValue(playerBar, kAXChildrenAttribute as CFString, &childRef) == .success,
           let children = childRef as? [AXUIElement] {
            for child in children {
                var descRef: AnyObject?
                guard AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &descRef) == .success,
                      let desc = descRef as? String, !desc.isEmpty else { continue }
                let stripped = stripTrackTypePrefix(desc)
                if !stripped.isEmpty && !isNoise(stripped) {
                    titleFromDesc = stripped
                    break
                }
            }
        }

        // 2. Все AXStaticText внутри Плеера (до глубины 10, не вылезая за пределы плеера)
        var links: [String] = []
        var texts: [String] = []
        collectLinksAndTexts(from: playerBar, depth: 0, maxDepth: 10, links: &links, texts: &texts)
        let filtered = (links + texts).filter { !isNoise($0) }
        var seen = Set<String>()
        let unique = filtered.filter { seen.insert($0.lowercased()).inserted }

        // Название: приоритет у дескриптора (надёжнее)
        let title = titleFromDesc ?? unique.first ?? ""
        guard !title.isEmpty else { return nil }

        // Артист: следующий уникальный текст в плеере, не совпадающий с названием
        // В большинстве случаев артист в AX-дереве плеера отсутствует — это нормально
        let artist = unique.first(where: { $0.lowercased() != title.lowercased() })
                     ?? Constants.Media.fallbackArtist
        let album  = unique.first(where: {
            let l = $0.lowercased()
            return l != title.lowercased() && l != artist.lowercased()
        }) ?? ""

        logger.debug("AX плеер: «\(title, privacy: .public)» — \(artist, privacy: .public)")
        return TrackInfo(id: "\(title)-\(artist)", title: title, artist: artist,
                         album: album, artworkData: nil, isPlaying: true, lastUpdated: Date())
    }

    // Слова-метки доступности, которые ЯМ ставит перед названием/исполнителем.
    static let metaPrefixWords = [
        "Артист", "Artist", "Трек", "Track", "Сингл", "Single",
        "Альбом", "Album", "EP", "Подкаст", "Podcast", "Эфир", "Станция", "Station"
    ]
    static let artistPrefixWords = ["Артист", "Artist"]

    /// Универсальная очистка строки от accessibility-префиксов ЯМ.
    /// Устойчива к ЛЮБОМУ типу пробела после слова-метки (обычный, неразрывный U+00A0
    /// и т.п.), которые часто вставляет Electron. Снимает вложенные префиксы тоже.
    /// "Трек Tes doux yeux verts" → "Tes doux yeux verts"
    /// "Артист\u{00A0}Daniela Paris" → "Daniela Paris"
    static func cleanName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for word in metaPrefixWords {
                guard s.count > word.count,
                      s.lowercased().hasPrefix(word.lowercased()) else { continue }
                let after = s.dropFirst(word.count)
                // После слова-метки должен идти пробел (любой) — иначе это часть названия
                guard let firstChar = after.first, firstChar.isWhitespace else { continue }
                s = String(after).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return s
    }

    /// true если строка начинается со слова-метки исполнителя ("Артист …", "Artist …").
    static func hasArtistPrefix(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for word in artistPrefixWords {
            guard s.count > word.count, s.lowercased().hasPrefix(word.lowercased()) else { continue }
            if let c = s.dropFirst(word.count).first, c.isWhitespace { return true }
        }
        return false
    }

    /// true если строка начинается с любого слова-метки ЯМ.
    static func hasMetaPrefix(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for word in metaPrefixWords {
            guard s.count > word.count, s.lowercased().hasPrefix(word.lowercased()) else { continue }
            if let c = s.dropFirst(word.count).first, c.isWhitespace { return true }
        }
        return false
    }

    // Совместимость со старым кодом
    private static func stripTrackTypePrefix(_ s: String) -> String { cleanName(s) }

    // Ищет кнопку "Предыдущий трек" как якорь плеера.
    // Кнопки "Воспроизведение" встречаются на карточках станций — они ложные якоря.
    // "Предыдущий трек" есть ТОЛЬКО в настоящих транспортных контролах плеера.
    private static func findTransportButton(el: AXUIElement, depth: Int, maxDepth: Int,
                                            result: inout AXUIElement?) {
        guard depth < maxDepth, result == nil else { return }

        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        if roleRef as? String == "AXButton" {
            var descRef: AnyObject?; var titleRef: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef)
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef)
            let combined = ((descRef as? String ?? "") + " " + (titleRef as? String ?? "")).lowercased()
            // Только prev/next — они уникальны для плеера (не встречаются на карточках станций)
            if combined.contains("предыдущ") || combined.contains("previous")
                || combined.contains("следующ") || combined.contains("next") {
                result = el; return
            }
        }

        var childRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return }
        for child in children {
            findTransportButton(el: child, depth: depth + 1, maxDepth: maxDepth, result: &result)
        }
    }

    private static func parentOf(_ el: AXUIElement) -> AXUIElement? {
        var parentRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success,
              CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { return nil }
        return (parentRef as! AXUIElement)
    }

    private static func collectLinksAndTexts(from el: AXUIElement, depth: Int, maxDepth: Int,
                                             links: inout [String], texts: inout [String]) {
        guard depth < maxDepth else { return }
        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        if role == "AXLink" || role == "AXStaticText" {
            if let s = linkText(el) {
                if role == "AXLink" { links.append(s) } else { texts.append(s) }
            }
        }

        var childRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return }
        for child in children {
            collectLinksAndTexts(from: child, depth: depth + 1, maxDepth: maxDepth,
                                 links: &links, texts: &texts)
        }
    }

    // MARK: - Minimized-window support

    /// Возвращает true если главное окно ЯМ свёрнуто в Dock.
    static func isWindowMinimized(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else { return false }
        var minRef: AnyObject?
        guard AXUIElementCopyAttributeValue(windows[0], kAXMinimizedAttribute as CFString, &minRef) == .success,
              let isMin = minRef as? Bool else { return false }
        return isMin
    }

    /// Кратковременно разворачивает окно ЯМ, читает трек из AX-дерева, сворачивает обратно.
    /// Вызывать только по явному действию пользователя — создаёт анимацию в Dock.
    static func readByUnminimizingBriefly(pid: pid_t) -> (track: TrackInfo, source: TrackReadSource)? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else { return nil }
        let window = windows[0]

        var minRef: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
              let isMin = minRef as? Bool, isMin else { return nil }

        // Разворачиваем окно
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        // Гарантированно вернём свёрнутое состояние, даже если чтение упадёт.
        defer { AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef) }

        // Ждём, пока Electron разморозит renderer и обновит AX-дерево
        Thread.sleep(forTimeInterval: 0.3)

        invalidateCache()
        if let t = readFromAccessibility(pid: pid) {
            return (t, .accessibility)
        }
        return nil
    }
}
