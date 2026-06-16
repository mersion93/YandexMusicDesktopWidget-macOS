import SwiftUI
import ServiceManagement
import WidgetKit

private extension Color {
    static let ymYellow = Color(red: 1.00, green: 0.84, blue: 0.00)
}

// MARK: - Главное окно приложения

struct MainWindowView: View {
    @StateObject private var service = NowPlayingService.shared
    @State private var section: Section = .nowPlaying
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false

    enum Section: String, CaseIterable, Identifiable {
        case nowPlaying, players, settings, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .nowPlaying: return "Сейчас играет"
            case .players:    return "Плееры"
            case .settings:   return "Настройки"
            case .about:      return "О программе"
            }
        }
        var icon: String {
            switch self {
            case .nowPlaying: return "music.note"
            case .players:    return "square.stack"
            case .settings:   return "gearshape"
            case .about:      return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Group {
                switch section {
                case .nowPlaying: NowPlayingPane()
                case .players:    PlayersPane()
                case .settings:   SettingsPane()
                case .about:      AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            if !hasSeenOnboarding { showOnboarding = true }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { hasSeenOnboarding = true; showOnboarding = false }
        }
    }

}

// MARK: - Сейчас играет

struct NowPlayingPane: View {
    @StateObject private var service = NowPlayingService.shared
    @State private var elapsed: TimeInterval = 0
    @State private var lastTick: Date?
    @State private var hiResArt: Data?
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var track: TrackInfo { service.currentTrack }
    /// Обложка для окна: HD из API (если подтянулась), иначе родная из системы.
    private var displayArt: Data? { hiResArt ?? track.artworkData }

    // Ключ кросс-фейда — ТОЛЬКО id трека: смена трека = один переход, а апгрейд
    // низкого→HD того же трека происходит на месте (без повторного мелькания).
    private var artKey: String { track.id }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            ZStack {
                artworkContent
                    .id(artKey)
                    .transition(.opacity)
            }
            .frame(width: 240, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .animation(.easeInOut(duration: 0.4), value: artKey)

            VStack(spacing: 4) {
                Text(track.title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                Text(track.artist).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                Text(playerName).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ymYellow).padding(.top, 2)
            }

            if track.duration > 0 {
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 4)
                            Capsule().fill(Color.ymYellow)
                                .frame(width: max(0, geo.size.width * CGFloat(min(elapsed / track.duration, 1))), height: 4)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                            let f = max(0, min(1, v.location.x / geo.size.width))
                            elapsed = f * track.duration
                            lastTick = track.isPlaying ? Date() : nil
                            NowPlayingStreamer.shared.seek(toSeconds: elapsed)
                        })
                    }
                    .frame(height: 12)
                    HStack {
                        Text(fmt(elapsed)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Text(fmt(track.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 280)
            }

            HStack(spacing: 28) {
                ctrl("backward.fill", 20) { MediaKeyController.shared.previousTrack(); service.scheduleRefreshAfterTrackChange() }
                ctrl(track.isPlaying ? "pause.fill" : "play.fill", 26) { MediaKeyController.shared.playPause() }
                ctrl("forward.fill", 20) { MediaKeyController.shared.nextTrack(); service.scheduleRefreshAfterTrackChange() }
                if track.isYandex {
                    Divider().frame(height: 24)
                    ctrl(track.likeState == .liked ? "heart.fill" : "heart", 18,
                         tint: track.likeState == .liked ? Color.ymYellow : .secondary) { service.likeCurrentTrack() }
                }
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(ticker) { _ in
            guard track.isPlaying, let last = lastTick else { return }
            let cap = track.duration > 0 ? track.duration : .infinity
            elapsed = min(elapsed + Date().timeIntervalSince(last), cap); lastTick = Date()
        }
        .onChange(of: track.id) { _ in seedElapsed(); loadHiResArt() }
        .onChange(of: track.elapsed) { _ in seedElapsed() }
        .onAppear {
            seedElapsed(); loadHiResArt()
            NowPlayingStreamer.shared.pollNow()   // свежая позиция при открытии окна
        }
        .navigationTitle("Сейчас играет")
    }

    @ViewBuilder private var artworkContent: some View {
        if let data = displayArt, let img = NSImage(data: data) {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Color(red: 0.22, green: 0.08, blue: 0.02), .black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text("Я").font(.system(size: 64, weight: .black)).foregroundStyle(Color.ymYellow)
            }
        }
    }

    private var playerName: String {
        let b = track.playerBundleID
        return b.isEmpty ? "Яндекс Музыка" : Constants.Players.name(for: b)
    }

    /// Для ЯМ (если выполнен вход) подтягивает обложку 1000×1000 из API для большого окна.
    private func loadHiResArt() {
        hiResArt = nil
        let t = track
        guard t.isYandex, YandexMusicAPI.shared.isAuthorized,
              t.title != Constants.Media.notRunningTitle else { return }
        YandexMusicAPI.shared.highResCover(title: t.title, artist: t.artist) { data in
            DispatchQueue.main.async {
                // применяем только если трек ещё тот же
                guard self.track.id == t.id, let data else { return }
                self.hiResArt = data
            }
        }
    }
    private func seedElapsed() {
        let drift = track.isPlaying ? max(0, Date().timeIntervalSince(track.lastUpdated)) : 0
        var pos = track.elapsed + drift
        if track.duration > 0 { pos = min(pos, track.duration) }
        elapsed = max(0, pos)
        lastTick = track.isPlaying ? Date() : nil
    }
    private func fmt(_ s: TimeInterval) -> String { String(format: "%d:%02d", Int(s)/60, Int(s)%60) }
    private func ctrl(_ icon: String, _ size: CGFloat, tint: Color = .primary, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 40, height: 40)
        }.buttonStyle(.plain)
    }
}

// MARK: - Плееры

struct PlayersPane: View {
    @StateObject private var service = NowPlayingService.shared
    private let players: [(id: String, name: String, icon: String)] = [
        (Constants.Players.yandex,  "Яндекс Музыка", "music.note"),
        (Constants.Players.spotify, "Spotify",       "music.note.list"),
        (Constants.Players.apple,   "Apple Music",   "music.note")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Поддерживаемые плееры")
                .font(.system(size: 18, weight: .bold)).padding(.bottom, 4)
            Text("Виджет автоматически показывает тот плеер, который сейчас играет в системе.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 18)

            ForEach(players, id: \.id) { p in
                let active = service.currentTrack.playerBundleID == p.id
                HStack(spacing: 12) {
                    Image(systemName: p.icon).font(.system(size: 18))
                        .foregroundStyle(active ? Color.ymYellow : .secondary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.system(size: 14, weight: .medium))
                        Text(p.id == Constants.Players.yandex ? "Полная поддержка (лайки, обложки)" : "Воспроизведение, обложка, прогресс")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if active {
                        Text("Играет").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.ymYellow)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.ymYellow.opacity(0.12)).clipShape(Capsule())
                    }
                }
                .padding(.vertical, 10)
                Divider()
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("Плееры")
    }
}

// MARK: - Настройки

struct SettingsPane: View {
    @ObservedObject private var service = NowPlayingService.shared
    @State private var ymAuthorized = YandexMusicAPI.shared.isAuthorized
    @State private var axGranted = YMTrackReader.isAccessibilityGranted
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @AppStorage("popup_style") private var popupStyle = "compact"
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                group("Аккаунт Яндекс Музыки") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ymAuthorized ? "Вход выполнен" : "Вход не выполнен").font(.system(size: 13))
                            Text("Настоящие обложки и избранное").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if ymAuthorized {
                            Button("Выйти") { YandexMusicAPI.shared.logout(); ymAuthorized = false }
                        } else {
                            Button("Войти") { loginYandex() }.tint(Color.ymYellow)
                        }
                    }
                }

                group("Разрешения") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility").font(.system(size: 13))
                            Text("Лайк/дизлайк и запасное чтение трека").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if axGranted {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Разрешить") { YMTrackReader.requestAccessibilityPermission() }.tint(Color.ymYellow)
                        }
                    }
                }

                group("Общее") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Запускать при входе").font(.system(size: 13))
                            Text("Открывать приложение при включении Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.switch).tint(Color.ymYellow)
                            .onChange(of: launchAtLogin) { on in
                                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                                catch { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
                            }
                    }
                }

                group("Стиль попапа в меню-баре") {
                    HStack(spacing: 16) {
                        styleOption(title: "Компактный", value: "compact") { CompactMock(art: service.currentTrack.artworkData) }
                        styleOption(title: "Карточка", value: "card") { CardMock(art: service.currentTrack.artworkData) }
                        Spacer()
                    }
                    Text("Применяется при следующем открытии попапа.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                group("Оформление виджета") {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "paintbrush").foregroundStyle(Color.ymYellow).font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Цвет, фон и элементы настраиваются для каждого виджета отдельно")
                                .font(.system(size: 13))
                            Text("Правый клик по виджету на рабочем столе → «Редактировать виджет»")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle("Настройки")
        .onReceive(ticker) { _ in
            ymAuthorized = YandexMusicAPI.shared.isAuthorized
            axGranted = YMTrackReader.isAccessibilityGranted
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    /// Кликабельная карточка-превью стиля попапа с подсветкой выбранного.
    private func styleOption<P: View>(title: String, value: String,
                                      @ViewBuilder preview: () -> P) -> some View {
        let selected = popupStyle == value
        return Button { popupStyle = value } label: {
            VStack(spacing: 8) {
                preview()
                    .frame(width: 154, height: 100)
                    .background(Color.black.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(selected ? Color.ymYellow : Color.secondary.opacity(0.25),
                                    lineWidth: selected ? 2 : 1)
                    )
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.ymYellow : .secondary)
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                }
            }
        }
        .buttonStyle(.plain)
    }


    private func loginYandex() {
        YandexAuthController.shared.present { token in
            guard let token else { return }
            YandexMusicAPI.shared.applyToken(token) { ok in ymAuthorized = ok }
        }
    }
}

// MARK: - О программе

struct AboutPane: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Версия \(v)"
    }
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note")
                .font(.system(size: 52, weight: .bold)).foregroundStyle(Color.ymYellow)
                .frame(width: 96, height: 96)
                .background(Color.ymYellow.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("Music Widget").font(.system(size: 22, weight: .bold))
            Text(version).font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Виджет «Сейчас играет» для рабочего стола и меню-бара.\nПоддержка Яндекс Музыки, Spotify и Apple Music.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360).padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .navigationTitle("О программе")
    }
}

// MARK: - Онбординг

struct OnboardingView: View {
    let onDone: () -> Void
    @State private var axGranted = YMTrackReader.isAccessibilityGranted
    @State private var ymAuthorized = YandexMusicAPI.shared.isAuthorized
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note")
                .font(.system(size: 44, weight: .bold)).foregroundStyle(Color.ymYellow)
            Text("Добро пожаловать").font(.system(size: 22, weight: .bold))
            Text("Виджет покажет, что играет в Яндекс Музыке, Spotify или Apple Music.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)

            VStack(spacing: 12) {
                step("1", "Войдите в Яндекс", "Для обложек и избранного", done: ymAuthorized) {
                    YandexAuthController.shared.present { t in
                        guard let t else { return }
                        YandexMusicAPI.shared.applyToken(t) { ok in ymAuthorized = ok }
                    }
                }
                step("2", "Дайте Accessibility", "Для лайков (опционально)", done: axGranted) {
                    YMTrackReader.requestAccessibilityPermission()
                }
                step("3", "Добавьте виджет", "ПКМ по столу → «Изменить виджеты»", done: false, action: nil)
            }
            .frame(maxWidth: 420)

            Button("Начать") { onDone() }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(Color.ymYellow)
                .padding(.top, 6)
        }
        .padding(36)
        .frame(width: 480, height: 520)
        .onReceive(ticker) { _ in
            axGranted = YMTrackReader.isAccessibilityGranted
            ymAuthorized = YandexMusicAPI.shared.isAuthorized
        }
    }

    private func step(_ num: String, _ title: String, _ subtitle: String, done: Bool, action: (() -> Void)?) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.ymYellow.opacity(0.18)).frame(width: 28, height: 28)
                if done { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                else { Text(num).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ymYellow) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let action, !done {
                Button("Сделать", action: action).controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Схематичные превью стилей попапа

private extension Color { static let ymYellowMock = Color(red: 1, green: 0.84, blue: 0) }

/// Миниатюра обложки для превью (реальная, если есть; иначе серый плейсхолдер).
@ViewBuilder
private func mockCover(_ art: Data?, size: CGFloat, radius: CGFloat) -> some View {
    if let art, let img = NSImage(data: art) {
        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    } else {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.secondary.opacity(0.5)).frame(width: size, height: size)
    }
}

/// Мини-макет «Компактный»: горизонтальная строка.
struct CompactMock: View {
    var art: Data? = nil
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                mockCover(art, size: 24, radius: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(Color.primary.opacity(0.55)).frame(width: 54, height: 4)
                    Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 36, height: 3)
                }
                Spacer(minLength: 4)
                Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(Color.ymYellowMock)
            }
            Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 3)
                .overlay(alignment: .leading) { Capsule().fill(Color.ymYellowMock).frame(width: 44, height: 3) }
            HStack(spacing: 12) {
                Circle().fill(Color.secondary.opacity(0.55)).frame(width: 5, height: 5)
                Circle().fill(Color.ymYellowMock).frame(width: 9, height: 9)
                Circle().fill(Color.secondary.opacity(0.55)).frame(width: 5, height: 5)
            }
        }
        .padding(13)
    }
}

/// Мини-макет «Карточка»: крупная обложка по центру.
struct CardMock: View {
    var art: Data? = nil
    var body: some View {
        VStack(spacing: 4) {
            mockCover(art, size: 36, radius: 6)
            Capsule().fill(Color.primary.opacity(0.55)).frame(width: 48, height: 4).padding(.top, 2)
            Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 32, height: 3)
            Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 96, height: 3)
                .overlay(alignment: .leading) { Capsule().fill(Color.ymYellowMock).frame(width: 32, height: 3) }
                .padding(.top, 1)
            HStack(spacing: 9) {
                Circle().fill(Color.secondary.opacity(0.55)).frame(width: 5, height: 5)
                Circle().fill(Color.ymYellowMock).frame(width: 9, height: 9)
                Circle().fill(Color.secondary.opacity(0.55)).frame(width: 5, height: 5)
                Image(systemName: "heart.fill").font(.system(size: 7)).foregroundStyle(Color.ymYellowMock)
            }
            .padding(.top, 1)
        }
        .padding(9)
    }
}
