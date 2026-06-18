import Foundation
import Combine
import AppKit
import SwiftUI
import WidgetKit
import ImageIO
import UniformTypeIdentifiers
import OSLog

/// ЕДИНСТВЕННЫЙ источник правды о текущем треке (Single Source of Truth).
/// Только этот объект читает плеер (mediaremote-adapter / Accessibility) и владеет
/// `currentTrack`. Все потребители подписываются на него и НЕ обращаются к источникам
/// напрямую:
///   • попап и окно — через `@Published currentTrack` (SwiftUI/Combine, в процессе);
///   • десктопный виджет — через App Group (`track.json` + `reloadAllTimelines`), т.к.
///     это отдельный sandboxed-процесс и подписаться на Combine он не может.
/// Запись наружу идёт ТОЛЬКО через `publishToWidget(_:)` — она и фильтрует «значимые
/// изменения» (см. `TrackInfo.hasSameWidgetContent`).
final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()

    @Published private(set) var currentTrack: TrackInfo = .empty

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.yandexmusic.widget",
        category: "NowPlaying"
    )
    private var timerCancellable: AnyCancellable?
    private var likesTimer: AnyCancellable?

    // У WidgetKit ЖЁСТКИЙ суточный бюджет на reloadAllTimelines(). Если его исчерпать
    // (а смена трека порождает несколько событий: название → исполнитель → HD-обложка),
    // система перестаёт перечитывать провайдер и виджет ЗАВИСАЕТ на старом треке.
    // Поэтому ВСЕ запросы перезагрузки идут сюда и СХЛОПЫВАЮТСЯ в один фактический пуш
    // на устоявшуюся смену трека (+ один отложенный повтор от потери пуша).
    private var reloadWork: DispatchWorkItem?
    private var reloadWindowStart: Date?
    private var widgetBackupReload: DispatchWorkItem?

    /// Запросить перезагрузку виджета. Несколько вызовов за ~секунду (название, затем
    /// исполнитель, затем HD-обложка) сольются в ОДИН пуш: когда данные стали полными —
    /// через короткую паузу 0.3с (добрать хвосты), а если так и неполны — не позже 1.5с
    /// от первого запроса (грузим тем, что есть, чтобы не зависнуть). Попап обновляется
    /// мгновенно из памяти и от этого пуша не зависит.
    private func requestWidgetReload() {
        let now = Date()
        if reloadWindowStart == nil { reloadWindowStart = now }
        let capReached = now.timeIntervalSince(reloadWindowStart!) >= 1.5
        let needsHD = currentTrack.isYandex && YandexMusicAPI.shared.isAuthorized
        let complete = (pendingArtist == nil) && (currentTrack.artworkData != nil || !needsHD)

        reloadWork?.cancel()
        let delay = (complete || capReached) ? 0.3 : 1.5
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reloadWindowStart = nil
            self.reloadWork = nil
            self.fireWidgetReload()
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Один фактический пуш + один отложенный повтор (система иногда тихо отбрасывает
    /// одиночный пуш; повтор перевыставляется на каждом пуше — не больше двух на трек).
    private func fireWidgetReload() {
        WidgetCenter.shared.reloadAllTimelines()
        widgetBackupReload?.cancel()
        let backup = DispatchWorkItem { WidgetCenter.shared.reloadAllTimelines() }
        widgetBackupReload = backup
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: backup)
    }

    // Дедуп активных запросов статуса лайка (по ключу «title|artist»).
    private var fetchingArtwork: Set<String> = []

    // Последний снимок, реально записанный в track.json — чтобы не писать повторно тот
    // же видимый контент (см. publishToWidget / TrackInfo.hasSameWidgetContent).
    private var lastPublished: TrackInfo?

    /// ЕДИНСТВЕННАЯ точка записи трека наружу (App Group → виджет). Пишет и перезагружает
    /// виджет ТОЛЬКО при значимом изменении (название/исполнитель/обложка/пауза/лайк);
    /// позиция воспроизведения сюда не входит. Возвращает true, если запись произошла.
    @discardableResult
    private func publishToWidget(_ track: TrackInfo) -> Bool {
        if let last = lastPublished, track.hasSameWidgetContent(as: last) { return false }
        lastPublished = track
        AppGroupManager.shared.saveTrack(track)
        AppGroupManager.shared.saveSyncStatus(.synced)
        requestWidgetReload()
        return true
    }

    // Пока стрим хоть раз отдал данные и не был очищен — он основной источник,
    // и чтение через Accessibility НЕ вмешивается (иначе перебивает неверными данными).
    private var hasStreamData = false

    // Какой плеер сейчас активен (ЯМ/Spotify/Apple Music) — для открытия и лайка.
    private var currentPlayerBundleID = Constants.Players.yandex

    // ЯМ не отдаёт статус лайка через Accessibility (AXValue пустой), поэтому
    // храним оптимистичный статус по id трека — он отражает действия пользователя.
    private var likeOverrides: [String: LikeState] = [:]

    // Маппинг ключа → id трека в каталоге ЯМ (для лайка и обложки через API).
    // Ключ включает длительность: у одной песни бывает несколько track-id с разной
    // длительностью (разные альбомы), и без этого они бы перетирали друг друга.
    private var apiTrackIdMap: [String: String] = [:]
    private func apiKey(_ t: TrackInfo) -> String {
        "\(t.title)|\(t.artist)|\(Int(t.duration.rounded()))"
    }
    // HD-обложки (~700px, по одной на трек) кэшируются в общем ArtworkCache (NSCache) —
    // каждая скачивается и даунскейлится один раз. Здесь храним лишь служебное:
    // активные докачки (дедуп) и прямой URL обложки (чтобы не делать второй /search).
    private var hdCoverFetching: Set<String> = []
    private var apiCoverURLMap: [String: URL] = [:]

    private init() {
        if !MediaRemoteHelper.isAvailable {
            logger.warning("MediaRemote.framework недоступен")
        }
    }

    // MARK: - Public

    func startObserving() {
        guard timerCancellable == nil else { return }
        timerCancellable = Timer.publish(
            every: Constants.Timing.nowPlayingRefreshInterval,
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in self?.fetchNowPlaying() }

        // Когда ЯМ разворачивают из свёрнутого состояния — AX-дерево
        // обновляется и мы сразу читаем актуальный трек (без ожидания следующего тика).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(ymDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // AX Observer: мгновенная реакция на смену трека через kAXTitleChangedNotification
        YMAccessibilityObserver.shared.onChange = { [weak self] in
            self?.fetchNowPlaying()
        }

        // Главный источник: системное «Сейчас играет» через mediaremote-adapter.
        // Работает при любом состоянии окна (свёрнуто/полный экран) и даёт родную обложку.
        NowPlayingStreamer.shared.onUpdate = { [weak self] track in
            self?.applyNativeTrack(track)
        }
        NowPlayingStreamer.shared.onCleared = { [weak self] in
            // Системное «Сейчас играет» пусто/не от ЯМ — отдаём управление обычному
            // опросу (он покажет паузу/последний трек или «не запущено»).
            self?.hasStreamData = false
        }
        NowPlayingStreamer.shared.start()

        // Команды из виджета (next/prev/like/…) пишутся в App Group файл. Чтобы кнопки
        // виджета срабатывали мгновенно, а не ждали тика опроса, следим за каталогом
        // контейнера и выполняем команду сразу по факту записи.
        startPendingWatcher()

        // Если уже авторизованы — подгружаем список лайков (для синхронизации статуса)
        YandexMusicAPI.shared.refreshOnLaunch()
        // Периодически обновляем лайки — на случай, если трек лайкнули в самой ЯМ.
        // После обновления списка пере-сверяем статус ТЕКУЩЕГО трека, чтобы виджет
        // показал актуальный лайк, даже если трек не переключался.
        likesTimer = Timer.publish(every: 120, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                YandexMusicAPI.shared.refreshLikes { [weak self] in
                    guard let self else { return }
                    self.refreshCurrentLikeStatus()
                }
            }

        fetchNowPlaying()
        logger.info("NowPlayingService запущен, опрос каждые \(Constants.Timing.nowPlayingRefreshInterval) с")
    }

    func stopObserving() {
        timerCancellable?.cancel()
        timerCancellable = nil
        likesTimer?.cancel()
        likesTimer = nil
        pendingWatchSource?.cancel()
        pendingWatchSource = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        YMAccessibilityObserver.shared.stop()
        NowPlayingStreamer.shared.stop()
        YMTrackReader.invalidateCache()
        logger.info("NowPlayingService остановлен")
    }

    @objc private func ymDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Constants.Media.yandexMusicBundleID else { return }
        // Даём Electron 300 мс на обновление AX-дерева после разворачивания окна
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.fetchNowPlaying()
        }
        logger.debug("ЯМ активирована — принудительное обновление трека")
    }

    func forceRefresh() {
        fetchNowPlaying()
    }

    /// Форсированное обновление трека, включая краткое разворачивание окна если оно свёрнуто.
    /// Вызывать при открытии попапа или явном нажатии пользователем — создаёт анимацию в Dock.
    func forceRefreshIncludingUnminimize() {
        // Если системный стрим активен — он уже даёт актуальные данные (в т.ч. при
        // свёрнутом окне), AX-чтение не нужно и только затёрло бы обложку.
        if hasStreamData { return }
        guard let ymApp = yandexMusicApp() else { fetchNowPlaying(); return }
        let pid = ymApp.processIdentifier
        YMTrackReader.invalidateCache()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let likeState = YMActionController.shared.currentLikeState(pid: pid)

            // Если окно свёрнуто — AX-дерево заморожено, обычное чтение даст устаревшие
            // данные. Поэтому при свёрнутом окне сразу идём через краткое разворачивание.
            let minimized = YMTrackReader.isWindowMinimized(pid: pid)

            if !minimized, var result = YMTrackReader.readCurrentTrack(pid: pid) {
                result.track.likeState = likeState
                let finished = result
                DispatchQueue.main.async { self.applyTrack(finished.track, source: finished.source) }
                return
            }

            // Окно свёрнуто или чтение не дало результат — краткое разворачивание
            if var result = YMTrackReader.readByUnminimizingBriefly(pid: pid) {
                result.track.likeState = likeState
                let finished = result
                DispatchQueue.main.async { self.applyTrack(finished.track, source: finished.source) }
            }
        }
    }

    /// Планирует обновление трека через 1.5 с после переключения трека (Next/Prev).
    /// Включает кратковременное разворачивание, если окно ЯМ свёрнуто.
    func scheduleRefreshAfterTrackChange() {
        rapidRefreshBurst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.forceRefreshIncludingUnminimize()
        }
    }

    /// Серия частых внеплановых опросов сразу после переключения трека — чтобы новые
    /// данные (название/обложка) появились как можно быстрее, не дожидаясь тика опроса.
    func rapidRefreshBurst() {
        for delay in [0.15, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NowPlayingStreamer.shared.pollNow()
            }
        }
    }

    /// Выставляет статус лайка ТОЛЬКО если этот трек всё ещё текущий (защита от
    /// гонки, когда трек переключился за время сетевого запроса).
    private func applyLikeIfCurrent(_ trackId: String, state: LikeState) {
        guard currentTrack.id == trackId, currentTrack.likeState != state else { return }
        currentTrack.likeState = state
        publishToWidget(currentTrack)
    }

    /// Лайк текущего трека (вызывается из основного окна). Только для Яндекс Музыки.
    func likeCurrentTrack() {
        guard isYandexActive else { return }
        // Путь через API Яндекса — надёжно ставит/снимает лайк по id трека.
        if YandexMusicAPI.shared.isAuthorized {
            // Фиксируем трек, по которому нажали лайк — за время сетевого ответа трек
            // может переключиться, и без этого мы лайкнули/пометили бы уже ДРУГОЙ трек.
            let target = currentTrack
            let key = apiKey(target)
            let prevState = target.likeState
            if let apiId = apiTrackIdMap[key] {
                let newLiked = prevState != .liked
                applyLikeIfCurrent(target.id, state: newLiked ? .liked : .none)   // оптимистично
                YandexMusicAPI.shared.setLike(trackId: apiId, liked: newLiked) { [weak self] ok in
                    guard let self else { return }
                    // На ошибке откатываем оптимистичный статус, чтобы не врать.
                    if !ok { self.applyLikeIfCurrent(target.id, state: prevState) }
                }
                return
            }
            // id ещё не найден — ищем ПО ДЛИТЕЛЬНОСТИ (точная запись) и затем лайкаем
            applyLikeIfCurrent(target.id, state: .liked)   // оптимистично
            YandexMusicAPI.shared.searchTrack(title: target.title, artist: target.artist, duration: target.duration) { [weak self] apiTrack in
                guard let self, let apiTrack else { self?.applyLikeIfCurrent(target.id, state: prevState); return }
                self.apiTrackIdMap[key] = apiTrack.id
                YandexMusicAPI.shared.setLike(trackId: apiTrack.id, liked: true) { ok in
                    if !ok { self.applyLikeIfCurrent(target.id, state: prevState) }
                }
            }
            return
        }

        // Без токена — старый путь: AX-нажатие + оптимистичный статус.
        guard let pid = yandexMusicApp()?.processIdentifier else { return }
        let id = currentTrack.id
        let newState: LikeState = currentTrack.likeState == .liked ? .none : .liked
        likeOverrides[id] = newState
        currentTrack.likeState = newState
        publishToWidget(currentTrack)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = YMActionController.shared.performLike(pid: pid)
            AppGroupManager.shared.saveLastCommand(.like)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.fetchNowPlaying() }
        }
    }

    /// Дизлайк текущего трека (вызывается из основного окна). Только для Яндекс Музыки.
    func dislikeCurrentTrack() {
        guard isYandexActive else { return }
        guard let pid = yandexMusicApp()?.processIdentifier else { return }
        let id = currentTrack.id
        let newState: LikeState = currentTrack.likeState == .disliked ? .none : .disliked
        likeOverrides[id] = newState
        currentTrack.likeState = newState
        publishToWidget(currentTrack)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = YMActionController.shared.performDislike(pid: pid)
            AppGroupManager.shared.saveLastCommand(.dislike)
            // Дизлайк часто переключает трек — обновляем чуть позже
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.fetchNowPlaying() }
        }
    }

    // MARK: - Private

    private func fetchNowPlaying() {
        let ymPid = yandexMusicApp()?.processIdentifier
        if let ymPid { YMAccessibilityObserver.shared.startIfNeeded(pid: ymPid) }

        // Выполняем команду из виджета (медиаклавиши работают для любого плеера).
        processPendingAction(pid: ymPid)

        // Системный стрим (ЯМ/Spotify/Apple Music) — основной источник. Если он отдаёт
        // данные — не вмешиваемся (даже если ЯМ не запущена, а играет другой плеер).
        if hasStreamData { return }

        // Стрим молчит — запасной путь только для Яндекс Музыки (через AX).
        guard let pid = ymPid else {
            applyTrack(.notRunning, source: .none)
            return
        }

        // Нативные методы (заголовок окна + AX) идут первыми — они специфичны для ЯМ.
        // MediaRemote читаем только если оба нативных метода не дали результат,
        // иначе при наличии другого плеера (Apple Music, Spotify) MediaRemote
        // вернёт их трек и подменит данные ЯМ.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let likeState = YMActionController.shared.currentLikeState(pid: pid)

            if var result = YMTrackReader.readCurrentTrack(pid: pid) {
                result.track.likeState = likeState
                let finished = result
                DispatchQueue.main.async {
                    // Пока шло медленное AX-чтение, стрим мог дать свежие данные — не затираем их.
                    guard !self.hasStreamData else { return }
                    self.applyTrack(finished.track, source: finished.source)
                }
                return
            }

            // Нативные методы не дали трек — пробуем MediaRemote как запасной вариант
            // (ЯМ иногда всё же регистрируется, но это редкость)
            MediaRemoteHelper.fetchTrackInfo { [weak self] mrTrack in
                guard let self else { return }
                let mrHasTitle = mrTrack.title != Constants.Media.fallbackTitle
                              && mrTrack.title != Constants.Media.notRunningTitle
                if mrHasTitle {
                    guard !self.hasStreamData else { return }
                    var t = mrTrack
                    t.likeState = YMActionController.shared.currentLikeState(pid: pid)
                    self.applyTrack(t, source: .mediaRemote)
                    return
                }

                // Ни один метод не дал трек — ЯМ работает, данные временно недоступны
                // (чаще всего: окно свёрнуто → AX-дерево заморожено Electron'ом).
                // Не сбрасываем currentTrack на заглушку — сохраняем последнее известное.
                DispatchQueue.main.async {
                    let hadValidTrack = self.currentTrack.title != Constants.Media.fallbackTitle
                                    && self.currentTrack.title != Constants.Media.notRunningTitle
                    if !hadValidTrack {
                        let fallback = TrackInfo(
                            id: "ym-running-\(pid)",
                            title: Constants.Media.fallbackTitle,
                            artist: Constants.Media.fallbackArtist,
                            album: "",
                            artworkData: nil,
                            isPlaying: true,
                            lastUpdated: Date()
                        )
                        self.applyTrack(fallback, source: .none)
                    }
                }
            }
        }
    }

    /// Применяет трек из системного стрима (основной источник).
    private var pendingNativeTrack: TrackInfo?
    private var nativeApplyWork: DispatchWorkItem?

    // Маска исполнителя: пока источник не прислал настоящего исполнителя нового
    // трека, прячем поле. stale — исполнитель прошлого трека (его не показываем).
    private var pendingArtist: (title: String, stale: String)?
    private var artistRevealWork: DispatchWorkItem?
    // Кэш «название+длительность → исполнитель» для уже игравших треков: при возврате
    // показываем исполнителя сразу. Длительность в ключе ОБЯЗАТЕЛЬНА — у разных песен
    // бывает одинаковое название (Saviour и т.п.), и без неё подставлялся бы чужой
    // исполнитель → чужая обложка.
    private var knownArtist: [String: String] = [:]
    private func artistKey(_ title: String, _ duration: TimeInterval) -> String? {
        guard duration > 1 else { return nil }   // без надёжной длительности кэш не используем
        return "\(title)|\(Int(duration.rounded()))"
    }
    private func rememberArtist(_ title: String, _ artist: String, _ duration: TimeInterval) {
        guard !artist.isEmpty, let k = artistKey(title, duration) else { return }
        if knownArtist.count > 150 { knownArtist.removeAll() }
        knownArtist[k] = artist
    }

    /// Если настоящий исполнитель так и не пришёл за 0.8с — значит он ТОТ ЖЕ, что был
    /// (трек того же артиста). Показываем его и снимаем маску.
    private func scheduleArtistReveal(stale: String, forTitle title: String) {
        artistRevealWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let pa = self.pendingArtist,
                  pa.title == title, self.currentTrack.title == title else { return }
            self.pendingArtist = nil
            var t = self.currentTrack
            t.artist = stale
            t.id = "\(t.title)-\(t.artist)"
            self.currentTrack = t
            self.publishToWidget(t)
            self.enrichTrack(t)   // теперь artist есть — можно искать HD/лайк
        }
        artistRevealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func applyNativeTrack(_ track: TrackInfo) {
        hasStreamData = true
        // Тот же трек (позиция/пауза/обновление обложки) — применяем СРАЗУ, чтобы
        // не замедлять виджет и попап.
        if track.id == currentTrack.id, pendingNativeTrack == nil {
            applyTrack(track, source: .mediaRemote)
            return
        }
        // СМЕНА трека: лёгкая склейка пачки (70мс) — БЕЗ долгого ожидания, чтобы
        // название+обложка появлялись быстро. За «старого исполнителя на новом треке»
        // отвечает маска исполнителя в applyTrack (прячем, пока не придёт настоящий).
        pendingNativeTrack = track
        nativeApplyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let t = self.pendingNativeTrack else { return }
            self.pendingNativeTrack = nil
            self.applyTrack(t, source: .mediaRemote)
        }
        nativeApplyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    private func applyTrack(_ rawTrack: TrackInfo, source: TrackReadSource) {
        var track = rawTrack

        // Запоминаем активный плеер (для открытия и определения, доступен ли лайк).
        if !track.playerBundleID.isEmpty {
            currentPlayerBundleID = track.playerBundleID
        }

        // Финальный предохранитель: какой бы источник ни дал данные, снимаем
        // accessibility-префиксы ЯМ ("Артист …", "Трек …") с названия и исполнителя.
        let cleanTitle  = YMTrackReader.cleanName(track.title)
        let cleanArtist = YMTrackReader.cleanName(track.artist)
        if cleanTitle != track.title || cleanArtist != track.artist {
            track.title  = cleanTitle
            track.artist = cleanArtist
            track.id     = "\(cleanTitle)-\(cleanArtist)"
        }

        // Применяем оптимистичный статус лайка (AX реальный статус не отдаёт)
        if let ov = likeOverrides[track.id] {
            track.likeState = ov
        }
        // Ограничиваем рост словаря оптимистичных лайков.
        if likeOverrides.count > 200 { likeOverrides.removeAll() }

        // Обложку/артиста НЕ подставляем из внешних кэшей — только родные из системного стрима.

        let oldTitle  = currentTrack.title
        let oldArtist = currentTrack.artist
        // МАСКА ИСПОЛНИТЕЛЯ: источник отдаёт исполнителя на ~0.5с позже названия.
        // Чтобы не показывать СТАРОГО исполнителя на новом треке — прячем поле (пусто),
        // пока не придёт настоящий. Настоящий = первый непустой и НЕ равный старому
        // (либо раскрываем старого по таймеру — значит исполнитель тот же).
        if let k = artistKey(track.title, track.duration), let known = knownArtist[k], !known.isEmpty {
            // Исполнителя ЭТОГО трека (название+длительность) уже знаем — он авторитетный.
            // Показываем сразу и НЕ даём запоздалому/чужому событию его перебить.
            track.artist = known
            if pendingArtist?.title == track.title { pendingArtist = nil; artistRevealWork?.cancel() }
        } else if track.title != oldTitle {
            // Новый трек, исполнителя пока не знаем.
            if !track.artist.isEmpty, track.artist != oldArtist {
                pendingArtist = nil; artistRevealWork?.cancel()       // настоящий пришёл сразу
            } else {
                pendingArtist = (title: track.title, stale: oldArtist)
                track.artist = ""
                scheduleArtistReveal(stale: oldArtist, forTitle: track.title)
            }
        } else if let pa = pendingArtist, pa.title == track.title {
            if !track.artist.isEmpty, track.artist != pa.stale {
                pendingArtist = nil; artistRevealWork?.cancel()       // пришёл настоящий
            } else {
                track.artist = ""                                      // держим пусто
            }
        }
        track.id = "\(track.title)-\(track.artist)"   // id с учётом маски (стабилен)
        rememberArtist(track.title, track.artist, track.duration)   // запоминаем для быстрых возвратов

        let idChanged = track.id != currentTrack.id
        if track.title == oldTitle, likeOverrides[track.id] == nil {
            track.likeState = currentTrack.likeState
        }
        // ОБЛОЖКА. Для Яндекса родную из адаптера НЕ показываем: при переходах адаптер
        // отдаёт обложку прошлого трека (в т.ч. разными вариантами) — отсюда «чужое
        // фото». Показываем ТОЛЬКО проверенную HD из API (найдена по точному треку).
        // Нет HD → плейсхолдер-загрузка; тот же трек → держим уже показанную; уже
        // игравший → мгновенно из кэша. Для не-Яндекс (API нет) оставляем родную.
        if track.isYandex && YandexMusicAPI.shared.isAuthorized {
            if let apiId = apiTrackIdMap[apiKey(track)], let hd = ArtworkCache.shared.data(for: apiId) {
                track.artworkData = hd
            } else if !idChanged, let prev = currentTrack.artworkData, !prev.isEmpty {
                track.artworkData = prev
            } else {
                track.artworkData = nil
            }
        }
        if idChanged {
            // Анимируем переход между треками через SwiftUI transaction
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                currentTrack = track
            }
        } else {
            currentTrack = track
        }

        // track.json пишем ТОЛЬКО при значимом изменении (название/исполнитель/обложка/
        // пауза/лайк) — единая точка publishToWidget с проверкой hasSameWidgetContent.
        // Позицию (elapsed) виджет не показывает, поэтому ~150 КБ обложки в файл на
        // каждое событие стрима не гоняем: попап/окно берут позицию из памяти.
        if publishToWidget(track) {
            logger.debug("Трек изменился: «\(track.title)» / \(source.rawValue) / играет=\(track.isPlaying)")
        }

        enrichTrack(track)
    }

    /// Обогащение трека: ТОЛЬКО статус лайка из API Яндекса.
    /// Обложку берём исключительно из системного стрима (она родная и всегда верная) —
    /// внешний поиск обложки по названию отключён, т.к. находил ЧУЖИЕ картинки.
    private func enrichTrack(_ track: TrackInfo) {
        // Пока исполнитель скрыт — НЕ ищем в API (пустой artist дал бы мусорный поиск).
        guard pendingArtist == nil else { return }
        guard track.title != Constants.Media.fallbackTitle,
              track.title != Constants.Media.notRunningTitle else { return }
        // Статус лайка — только для Яндекс Музыки (для Spotify/Apple Music это чужой каталог).
        guard track.isYandex, YandexMusicAPI.shared.isAuthorized else { return }
        enrichLikeStatus(track)
    }

    /// Пере-сверяет статус лайка текущего трека по свежему списку лайков
    /// (вызывается после периодического refreshLikes).
    private func refreshCurrentLikeStatus() {
        enrichTrack(currentTrack)
    }

    /// Находит id трека в каталоге ЯМ (по названию+артисту+длительности) и выставляет
    /// реальный статус лайка. Длительность важна: у песни бывает несколько track-id.
    private func enrichLikeStatus(_ track: TrackInfo) {
        let key = apiKey(track)

        // Уже знаем id — сверяем лайк и применяем HD-обложку (из кэша или докачиваем).
        if let apiId = apiTrackIdMap[key] {
            let liked = YandexMusicAPI.shared.isLiked(trackId: apiId)
            applyLikeIfCurrent(track.id, state: liked ? .liked : .none)
            applyOrFetchHDCover(apiId: apiId, for: track)
            return
        }

        guard !fetchingArtwork.contains(key) else { return }
        fetchingArtwork.insert(key)

        YandexMusicAPI.shared.searchTrack(title: track.title, artist: track.artist, duration: track.duration) { [weak self] apiTrack in
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetchingArtwork.remove(key)
                guard let apiTrack else { return }
                self.apiTrackIdMap[key] = apiTrack.id
                let liked = YandexMusicAPI.shared.isLiked(trackId: apiTrack.id)
                self.applyLikeIfCurrent(track.id, state: liked ? .liked : .none)
                // HD-обложка: только при СТРОГОМ совпадении названия (чтобы не подставить чужую).
                guard apiTrack.title.lowercased() == track.title.lowercased(),
                      let url0 = apiTrack.coverURL else { return }
                let bigStr = url0.absoluteString.replacingOccurrences(of: "400x400", with: "1000x1000")
                guard let bigURL = URL(string: bigStr) else { return }
                self.apiCoverURLMap[key] = bigURL   // запоминаем — чтобы не искать повторно
                self.fetchHDCover(bigURL, apiId: apiTrack.id, for: track)
            }
        }
    }

    /// Применяет HD-обложку из кэша; если её нет — докачивает (нужен apiTrack для URL,
    /// поэтому при пустом кэше делаем поиск через highResCover со строгим совпадением).
    private func applyOrFetchHDCover(apiId: String, for track: TrackInfo) {
        if let data = ArtworkCache.shared.data(for: apiId) {
            cacheAndApplyHD(data, apiId: apiId, for: track)
            return
        }
        guard !hdCoverFetching.contains(apiId) else { return }
        // Знаем прямой URL обложки — качаем по нему через fetchHDCover, без /search.
        if let url = apiCoverURLMap[apiKey(track)] {
            fetchHDCover(url, apiId: apiId, for: track)
            return
        }
        hdCoverFetching.insert(apiId)
        YandexMusicAPI.shared.highResCover(title: track.title, artist: track.artist, duration: track.duration) { [weak self] data in
            self?.handleFetchedCover(data, apiId: apiId, for: track)
        }
    }

    /// Качает HD-обложку по готовому URL и применяет к текущему треку.
    private func fetchHDCover(_ url: URL, apiId: String, for track: TrackInfo) {
        if let data = ArtworkCache.shared.data(for: apiId) { cacheAndApplyHD(data, apiId: apiId, for: track); return }
        guard !hdCoverFetching.contains(apiId) else { return }
        hdCoverFetching.insert(apiId)
        YandexMusicAPI.shared.fetchCover(url) { [weak self] data in
            self?.handleFetchedCover(data, apiId: apiId, for: track)
        }
    }

    /// Даунскейл до ~700px на фоне и применяет.
    private func handleFetchedCover(_ data: Data?, apiId: String, for track: TrackInfo) {
        guard let data, !data.isEmpty else {
            DispatchQueue.main.async { self.hdCoverFetching.remove(apiId) }
            return
        }
        let hd = NowPlayingService.downscaledArtwork(data, maxDim: 700) ?? data
        DispatchQueue.main.async {
            self.hdCoverFetching.remove(apiId)
            self.cacheAndApplyHD(hd, apiId: apiId, for: track)
        }
    }

    /// Уменьшает обложку до ~700px и пережимает в JPEG. 1000×1000 виджету/попапу не
    /// нужны (виджет рендерит <~700px), а меньший размер = меньше байт в App Group и
    /// быстрее декодирование при каждом рендере виджета. Возвращает nil при ошибке.
    static func downscaledArtwork(_ data: Data, maxDim: CGFloat = 700) -> Data? {
        // ImageIO (CGImageSource) — надёжный даунсэмплинг. Прежний путь через
        // NSBitmapImageRep+NSGraphicsContext рисовал ЧЁРНЫЙ квадрат.
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDim),   // не апскейлит мелкие
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private func cacheAndApplyHD(_ data: Data, apiId: String, for track: TrackInfo) {
        ArtworkCache.shared.store(data, for: apiId)
        guard currentTrack.id == track.id, currentTrack.artworkData != data else { return }
        currentTrack.artworkData = data
        publishToWidget(currentTrack)   // название+HD-обложка атомарно, если контент сменился
    }

    // Наблюдатель за каталогом App Group: реагирует на запись команды виджетом мгновенно
    // (вместо ожидания тика опроса). Каталог, а не файл: запись атомарная (rename),
    // поэтому inode файла меняется — следить надо за стабильным inode каталога.
    private var pendingWatchSource: DispatchSourceFileSystemObject?

    private func startPendingWatcher() {
        guard pendingWatchSource == nil,
              let dir = AppGroupManager.shared.containerDirectory else { return }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        src.setEventHandler { [weak self] in self?.checkPendingAction() }
        src.setCancelHandler { close(fd) }
        pendingWatchSource = src
        src.resume()
    }

    /// Дёшево проверяет, есть ли команда виджета; если нет — сразу выходит (не сканируя
    /// процессы). Срабатывает на любую запись в каталог, поэтому важно быть лёгким.
    private func checkPendingAction() {
        guard AppGroupManager.shared.loadPendingAction() != .none else { return }
        processPendingAction(pid: yandexMusicApp()?.processIdentifier)
    }

    /// Выполняет команду из виджета. Медиаклавиши (play/next/prev) работают для любого
    /// активного плеера; лайк/дизлайк/повтор/перемешка — только для Яндекс Музыки (нужен её pid).
    private func processPendingAction(pid: pid_t?) {
        let action = AppGroupManager.shared.loadPendingAction()
        guard action != .none else { return }
        AppGroupManager.shared.savePendingAction(.none)

        switch action {
        case .playPause:
            if pid == nil && !hasStreamData {
                // Ничего не играет — запускаем активный/последний плеер.
                launchActivePlayer(thenPlay: true)
            } else {
                MediaKeyController.shared.playPause()
            }
        case .nextTrack:
            MediaKeyController.shared.nextTrack()
            rapidRefreshBurst()
        case .previousTrack:
            MediaKeyController.shared.previousTrack()
            rapidRefreshBurst()
        case .like:
            // Тот же надёжный путь, что и из окна: API Яндекса (setLike по trackId),
            // с AX-фолбэком внутри likeCurrentTrack. Раньше виджет шёл только через
            // AX-клик по кнопке в окне ЯМ — и лайк часто не доходил до сервера.
            guard isYandexActive else { break }
            DispatchQueue.main.async { [weak self] in self?.likeCurrentTrack() }
        case .dislike:
            guard isYandexActive else { break }
            DispatchQueue.main.async { [weak self] in self?.dislikeCurrentTrack() }
        case .openApp:
            openActivePlayer()
        case .repeatMode:
            guard let pid else { break }
            DispatchQueue.global(qos: .userInitiated).async { _ = YMActionController.shared.performRepeat(pid: pid) }
        case .shuffle:
            guard let pid else { break }
            DispatchQueue.global(qos: .userInitiated).async { _ = YMActionController.shared.performShuffle(pid: pid) }
        case .none:
            break
        }
    }

    private var isYandexActive: Bool { currentPlayerBundleID == Constants.Players.yandex }

    /// Открывает (или активирует) текущий активный плеер.
    private func openActivePlayer() {
        let bid = currentPlayerBundleID
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
            app.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Запускает активный/последний плеер и (опционально) шлёт Play.
    private func launchActivePlayer(thenPlay: Bool) {
        let bid = currentPlayerBundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return }
        NSWorkspace.shared.open(url)
        guard thenPlay else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            MediaKeyController.shared.playPause()
        }
    }

    private func yandexMusicApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == Constants.Media.yandexMusicBundleID }
    }
}
