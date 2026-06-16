import Foundation
import Combine
import AppKit
import SwiftUI
import WidgetKit
import OSLog

final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()

    @Published private(set) var currentTrack: TrackInfo = .empty
    /// Последний успешный источник данных о треке
    @Published private(set) var dataSource: TrackReadSource = .none
    /// Заголовки окон ЯМ (для диагностики)
    @Published private(set) var rawWindowTitles: [String] = []

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.yandexmusic.widget",
        category: "NowPlaying"
    )
    private var timerCancellable: AnyCancellable?
    private var likesTimer: AnyCancellable?
    private var widgetReloadWork: DispatchWorkItem?
    private var lastWidgetReload = Date.distantPast

    /// Перезагрузка виджета: МГНОВЕННО на первое изменение (быстрая обложка),
    /// а частые повторы в течение 0.3с схлопываются в один хвостовой (без спама лимита).
    private func reloadWidgetDebounced() {
        let now = Date()
        if now.timeIntervalSince(lastWidgetReload) >= 0.3 {
            lastWidgetReload = now
            widgetReloadWork?.cancel(); widgetReloadWork = nil
            WidgetCenter.shared.reloadAllTimelines()
        } else if widgetReloadWork == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.lastWidgetReload = Date()
                self?.widgetReloadWork = nil
                WidgetCenter.shared.reloadAllTimelines()
            }
            widgetReloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    /// Надёжная перезагрузка для СМЕНЫ ТРЕКА: мгновенный пуш + два бэкапа.
    /// Система иногда отбрасывает одиночный reload под нагрузкой, и виджет
    /// «застывал» до следующего пульса (60с). Повторы через 1.5с и 4с ловят
    /// отброшенный пуш. Срабатывает только при реальной смене трека/паузы,
    /// не постоянно — поэтому бюджет WidgetKit не страдает.
    private func reloadWidgetForcefully() {
        lastWidgetReload = Date()
        widgetReloadWork?.cancel(); widgetReloadWork = nil
        WidgetCenter.shared.reloadAllTimelines()
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    // Дедуп активных запросов статуса лайка (по ключу «title|artist»).
    private var fetchingArtwork: Set<String> = []

    private var lastSignificantTitle   = ""
    private var lastSignificantArtist  = ""
    private var lastSignificantPlaying = false
    private var lastArtworkPresent     = false
    private var lastSignificantLike: LikeState = .none

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
    // Длительность трека из API по ключу «title|artist» (для полоски прогресса).
    private var apiDurationMap: [String: TimeInterval] = [:]
    // Обложка высокого разрешения по id трека ЯМ — чтобы в большом виджете не было
    // пикселизации (родная из стрима ~300px, на full-bleed мылит). Храним прямой URL
    // обложки, чтобы при повторной докачке не делать второй /search.
    private var hdCoverCache: [String: Data] = [:]
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
        AppGroupManager.shared.saveTrack(currentTrack)
        reloadWidgetDebounced()
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
        AppGroupManager.shared.saveTrack(currentTrack)
        reloadWidgetDebounced()
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
        AppGroupManager.shared.saveTrack(currentTrack)
        reloadWidgetDebounced()
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

            let titles   = YMTrackReader.debugWindowTitles(pid: pid)
            let likeState = YMActionController.shared.currentLikeState(pid: pid)

            if var result = YMTrackReader.readCurrentTrack(pid: pid) {
                result.track.likeState = likeState
                let finished = result
                DispatchQueue.main.async {
                    // Пока шло медленное AX-чтение, стрим мог дать свежие данные — не затираем их.
                    guard !self.hasStreamData else { return }
                    self.rawWindowTitles = titles
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
                    self.rawWindowTitles = titles
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
    private func applyNativeTrack(_ track: TrackInfo) {
        hasStreamData = true
        applyTrack(track, source: .mediaRemote)
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

        let idChanged = track.id != currentTrack.id
        // Сохраняем статус лайка из API между событиями одного трека: makeTrack про
        // лайк не знает (.none), и перезапись стёрла бы реальный статус — это давало
        // мелькание сердечка и лишние записи track.json на каждое событие позиции.
        if !idChanged, likeOverrides[track.id] == nil {
            track.likeState = currentTrack.likeState
        }
        // Обложка приходит отдельным событием чуть позже названия. Если в этом
        // событии её нет — держим предыдущую (а не nil), чтобы не мелькал чёрный
        // квадрат/плейсхолдер и не было видно «провала качества» при переключении.
        if (track.artworkData?.isEmpty ?? true), let prevArt = currentTrack.artworkData, !prevArt.isEmpty {
            track.artworkData = prevArt
        }
        if idChanged {
            // Анимируем переход между треками через SwiftUI transaction
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                currentTrack = track
                dataSource   = source
            }
        } else {
            currentTrack = track
            dataSource   = source
        }

        let titleChanged   = track.title    != lastSignificantTitle
        let artistChanged  = track.artist   != lastSignificantArtist
        let playingChanged = track.isPlaying != lastSignificantPlaying
        let artChanged     = (track.artworkData != nil) != lastArtworkPresent

        // track.json пишем ТОЛЬКО при изменении видимого виджету контента
        // (название/исполнитель/обложка/пауза/лайк). Позицию (elapsed) виджет не
        // показывает, поэтому на каждое событие стрима ~150 КБ обложки в файл не
        // гоняем — попап/окно берут позицию из currentTrack в памяти.
        let likeChanged = track.likeState != lastSignificantLike
        if titleChanged || artistChanged || playingChanged || artChanged || likeChanged {
            lastSignificantTitle   = track.title
            lastSignificantArtist  = track.artist
            lastSignificantPlaying = track.isPlaying
            lastArtworkPresent     = (track.artworkData != nil)
            lastSignificantLike    = track.likeState
            AppGroupManager.shared.saveTrack(track)
            AppGroupManager.shared.saveSyncStatus(.synced)
            // Смена трека/паузы — НАДЁЖНАЯ перезагрузка с бэкапами (иногда система
            // отбрасывает одиночный пуш под нагрузкой → виджет «застывал» до пульса).
            reloadWidgetForcefully()
            logger.debug("Трек изменился: «\(track.title)» / \(source.rawValue) / играет=\(track.isPlaying)")
        }

        enrichTrack(track)
    }

    /// Обогащение трека: ТОЛЬКО статус лайка из API Яндекса.
    /// Обложку берём исключительно из системного стрима (она родная и всегда верная) —
    /// внешний поиск обложки по названию отключён, т.к. находил ЧУЖИЕ картинки.
    private func enrichTrack(_ track: TrackInfo) {
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
        if let data = hdCoverCache[apiId] {
            guard currentTrack.id == track.id, currentTrack.artworkData != data else { return }
            currentTrack.artworkData = data
            AppGroupManager.shared.saveTrack(currentTrack)
            reloadWidgetDebounced()
            return
        }
        guard !hdCoverFetching.contains(apiId) else { return }
        // Знаем прямой URL обложки — качаем по нему через fetchHDCover (он даунскейлит),
        // без повторного /search.
        if let url = apiCoverURLMap[apiKey(track)] {
            fetchHDCover(url, apiId: apiId, for: track)
            return
        }
        hdCoverFetching.insert(apiId)
        YandexMusicAPI.shared.highResCover(title: track.title, artist: track.artist, duration: track.duration) { [weak self] data in
            // Даунскейл на фоне (как в fetchHDCover) — иначе хранили бы полный 1000px.
            guard let data, !data.isEmpty else {
                DispatchQueue.main.async { self?.hdCoverFetching.remove(apiId) }
                return
            }
            let scaled = NowPlayingService.downscaledArtwork(data) ?? data
            DispatchQueue.main.async {
                guard let self else { return }
                self.hdCoverFetching.remove(apiId)
                self.cacheAndApplyHD(scaled, apiId: apiId, for: track)
            }
        }
    }

    /// Качает HD-обложку по готовому URL и применяет к текущему треку.
    private func fetchHDCover(_ url: URL, apiId: String, for track: TrackInfo) {
        if let data = hdCoverCache[apiId] { cacheAndApplyHD(data, apiId: apiId, for: track); return }
        guard !hdCoverFetching.contains(apiId) else { return }
        hdCoverFetching.insert(apiId)
        YandexMusicAPI.shared.fetchCover(url) { [weak self] data in
            // Даунскейл делаем на фоне (тяжёлый рендер не на главном потоке).
            guard let data, !data.isEmpty else {
                DispatchQueue.main.async { self?.hdCoverFetching.remove(apiId) }
                return
            }
            let scaled = NowPlayingService.downscaledArtwork(data) ?? data
            DispatchQueue.main.async {
                guard let self else { return }
                self.hdCoverFetching.remove(apiId)
                self.cacheAndApplyHD(scaled, apiId: apiId, for: track)
            }
        }
    }

    /// Уменьшает обложку до ~700px и пережимает в JPEG. 1000×1000 виджету/попапу не
    /// нужны (виджет рендерит <~700px), а меньший размер = меньше байт в App Group и
    /// быстрее декодирование при каждом рендере виджета. Возвращает nil при ошибке.
    static func downscaledArtwork(_ data: Data, maxDim: CGFloat = 700) -> Data? {
        // По ПИКСЕЛЯМ (а не NSImage.size в точках — он зависит от DPI и может
        // ошибочно посчитать обложку «маленькой»).
        guard let src = NSBitmapImageRep(data: data) else { return nil }
        let pw = src.pixelsWide, ph = src.pixelsHigh
        guard pw > 0, ph > 0 else { return nil }
        let maxSide = max(pw, ph)
        if CGFloat(maxSide) <= maxDim { return data }   // уже мелкая
        let scale = maxDim / CGFloat(maxSide)
        let newW = max(1, Int((CGFloat(pw) * scale).rounded()))
        let newH = max(1, Int((CGFloat(ph) * scale).rounded()))
        guard let dst = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: newW, pixelsHigh: newH,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        dst.size = NSSize(width: newW, height: newH)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: dst)
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: newW, height: newH))
        NSGraphicsContext.restoreGraphicsState()
        return dst.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    private func cacheAndApplyHD(_ data: Data, apiId: String, for track: TrackInfo) {
        hdCoverCache[apiId] = data
        if hdCoverCache.count > 60 { hdCoverCache.removeAll(); hdCoverCache[apiId] = data }
        guard currentTrack.id == track.id, currentTrack.artworkData != data else { return }
        currentTrack.artworkData = data
        AppGroupManager.shared.saveTrack(currentTrack)
        reloadWidgetDebounced()
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
