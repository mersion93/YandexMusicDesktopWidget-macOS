import SwiftUI
import Combine
import ServiceManagement

private extension Color {
    static let ymYellow = Color(red: 1.00, green: 0.84, blue: 0.00)
}

/// Анимированный эквалайзер — полоски «дышат» при воспроизведении (живой попап).
struct EqualizerBars: View {
    var color: Color = .ymYellow
    @State private var animate = false
    private let factors: [CGFloat] = [0.45, 0.95, 0.65, 1.0, 0.55]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(factors.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: animate ? 14 * factors[i] : 4)
                    .animation(
                        .easeInOut(duration: 0.42 + Double(i) * 0.08)
                            .repeatForever(autoreverses: true),
                        value: animate
                    )
            }
        }
        .frame(height: 15)
        .onAppear { animate = true }
    }
}

struct ContentView: View {
    @StateObject private var service = NowPlayingService.shared
    @State private var axGranted     = false
    @State private var showSettings  = false
    @State private var ymAuthorized  = YandexMusicAPI.shared.isAuthorized
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @Environment(\.openWindow) private var openWindow

    // Прогресс и хронометраж
    @State private var elapsedSeconds: TimeInterval = 0
    @State private var lastTickDate: Date?

    @State private var isSeeking = false
    // Анимация кнопок
    @State private var pressingPlay = false
    @State private var pressingPrev = false
    @State private var pressingNext = false
    // Пульсация статус-точки
    @State private var dotPulse     = false

    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            playerSection
            progressSection
            if !axGranted && !ymAuthorized {
                Divider()
                permissionsAlert
            }
            Divider()
            openYMButton
            Divider()
            compactFooter
        }
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor))
        // Плавное изменение высоты попапа при появлении/скрытии полоски прогресса
        .animation(.easeInOut(duration: 0.3), value: service.currentTrack.duration > 0)
        // Синхронизируем состояние разрешений
        .onReceive(ticker) { _ in
            axGranted  = YMTrackReader.isAccessibilityGranted
            ymAuthorized = YandexMusicAPI.shared.isAuthorized
            tickElapsed()
        }
        .onAppear {
            axGranted  = YMTrackReader.isAccessibilityGranted
            dotPulse = service.currentTrack.isPlaying
            seedElapsed()
            // При открытии попапа берём свежую позицию из системы.
            NowPlayingStreamer.shared.pollNow()
        }
        // Смена трека или новая позиция от системы — пересеять прогресс с реального места.
        .onChange(of: service.currentTrack.id) { _ in seedElapsed() }
        .onChange(of: service.currentTrack.elapsed) { _ in seedElapsed() }
        .onChange(of: service.currentTrack.isPlaying) { playing in
            dotPulse = playing
            if playing { lastTickDate = Date() } else { lastTickDate = nil }
        }
    }

    /// Сеет полосу прогресса с РЕАЛЬНОЙ позиции трека (с учётом времени с последнего события).
    private func seedElapsed() {
        let t = service.currentTrack
        let drift = t.isPlaying ? max(0, Date().timeIntervalSince(t.lastUpdated)) : 0
        var pos = t.elapsed + drift
        if t.duration > 0 { pos = min(pos, t.duration) }
        elapsedSeconds = max(0, pos)
        lastTickDate = t.isPlaying ? Date() : nil
    }

    // MARK: - Elapsed timer

    private func tickElapsed() {
        guard service.currentTrack.isPlaying, let last = lastTickDate else { return }
        let now = Date()
        let cap = service.currentTrack.duration > 0 ? service.currentTrack.duration : .infinity
        elapsedSeconds = min(elapsedSeconds + now.timeIntervalSince(last), cap)
        lastTickDate = now
    }

    // Ключ кросс-фейда — только id трека: смена обложки того же трека (низкое→HD)
    // происходит на месте, без повторного мелькания.
    private var artworkIdentifier: String { service.currentTrack.id }

    private var playerName: String {
        let bid = service.currentTrack.playerBundleID
        return bid.isEmpty ? "Яндекс Музыка" : Constants.Players.name(for: bid)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ymYellow)
            Text(playerName)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.opacity)
            Spacer()
            // Статус: анимированный эквалайзер при воспроизведении, иначе точка «Пауза»
            HStack(spacing: 5) {
                if service.currentTrack.isPlaying {
                    EqualizerBars(color: Color.ymYellow)
                    Text("Играет")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.ymYellow)
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text("Пауза")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: service.currentTrack.isPlaying)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Player section

    private var playerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Обложка с чистым кросс-фейдом (ключ = идентичность картинки)
                artworkView
                    .id(artworkIdentifier)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.35), value: artworkIdentifier)
                    .onTapGesture { openYandexMusic() }
                    .help("Открыть Яндекс Музыку")

                // Название / исполнитель со слайдом при смене трека
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.currentTrack.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Text(service.currentTrack.artist)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    if !service.currentTrack.album.isEmpty {
                        Text(service.currentTrack.album)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.85),
                           value: service.currentTrack.id)

                Spacer()

                // Лайк/дизлайк — только для Яндекс Музыки
                if service.currentTrack.isYandex {
                    VStack(spacing: 10) { likeButton; dislikeButton }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            // Транспортные кнопки
            HStack(spacing: 0) {
                mediaButton(icon: "backward.fill", pressing: $pressingPrev, size: 16) {
                    MediaKeyController.shared.previousTrack()
                    service.scheduleRefreshAfterTrackChange()
                }
                Spacer()
                playPauseButton
                Spacer()
                mediaButton(icon: "forward.fill", pressing: $pressingNext, size: 16) {
                    MediaKeyController.shared.nextTrack()
                    service.scheduleRefreshAfterTrackChange()
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Обложка

    private var artworkView: some View {
        Group {
            if let data = service.currentTrack.artworkData,
               let img  = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(
                            colors: [
                                Color(red: 0.22, green: 0.08, blue: 0.02),
                                Color(red: 0.09, green: 0.09, blue: 0.09)
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                    Text("Я")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(Color.ymYellow)
                }
                .frame(width: 56, height: 56)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
    }

    // MARK: - Кнопки воспроизведения

    private var playPauseButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.15, dampingFraction: 0.55)) { pressingPlay = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) { pressingPlay = false }
            }
            MediaKeyController.shared.playPause()
        }) {
            ZStack {
                Circle()
                    .fill(Color.ymYellow)
                    .frame(width: 36, height: 36)
                    .shadow(color: Color.ymYellow.opacity(0.38), radius: 6, y: 2)
                Image(systemName: service.currentTrack.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .offset(x: service.currentTrack.isPlaying ? 0 : 1)
                    .animation(.easeInOut(duration: 0.18), value: service.currentTrack.isPlaying)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(pressingPlay ? 0.86 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.55), value: pressingPlay)
    }

    private func mediaButton(icon: String, pressing: Binding<Bool>,
                             size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.15, dampingFraction: 0.55)) { pressing.wrappedValue = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) { pressing.wrappedValue = false }
            }
            action()
        }) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.7))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .scaleEffect(pressing.wrappedValue ? 0.82 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.55), value: pressing.wrappedValue)
    }

    // MARK: - Лайк / Дизлайк

    private var likeButton: some View {
        Button(action: { service.likeCurrentTrack() }) {
            Image(systemName: service.currentTrack.likeState == .liked ? "heart.fill" : "heart")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(service.currentTrack.likeState == .liked
                                 ? Color.ymYellow : Color.secondary)
                .scaleEffect(service.currentTrack.likeState == .liked ? 1.18 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.5),
                           value: service.currentTrack.likeState)
        }
        .buttonStyle(.plain)
        .disabled(!axGranted)
        .help("Нравится")
    }

    private var dislikeButton: some View {
        Button(action: { service.dislikeCurrentTrack() }) {
            Image(systemName: service.currentTrack.likeState == .disliked
                  ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(service.currentTrack.likeState == .disliked
                                 ? Color(red: 1, green: 0.32, blue: 0.32) : Color.secondary)
                .scaleEffect(service.currentTrack.likeState == .disliked ? 1.18 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.5),
                           value: service.currentTrack.likeState)
        }
        .buttonStyle(.plain)
        .disabled(!axGranted)
        .help("Не нравится")
    }

    // MARK: - Прогресс

    @ViewBuilder
    private var progressSection: some View {
        let dur = service.currentTrack.duration
        if dur > 0 {
            VStack(spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.ymYellow)
                            .frame(
                                width: max(0, geo.size.width * CGFloat(min(elapsedSeconds / dur, 1.0))),
                                height: 4
                            )
                            // Анимируем только естественное движение; при перемотке — мгновенно.
                            .animation(isSeeking ? nil : .linear(duration: 0.5), value: elapsedSeconds)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                isSeeking = true
                                let frac = max(0, min(1, v.location.x / geo.size.width))
                                elapsedSeconds = frac * dur     // следует за пальцем без анимации
                                lastTickDate = nil
                            }
                            .onEnded { v in
                                let frac = max(0, min(1, v.location.x / geo.size.width))
                                let target = frac * dur
                                elapsedSeconds = target
                                lastTickDate = service.currentTrack.isPlaying ? Date() : nil
                                NowPlayingStreamer.shared.seek(toSeconds: target)
                                // Снимаем флаг чуть позже, чтобы скачок не анимировался.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isSeeking = false }
                            }
                    )
                }
                .frame(height: 12)   // увеличенная зона нажатия
                HStack {
                    Text(formatDuration(elapsedSeconds))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatDuration(dur))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.opacity)
        }
    }

    // MARK: - Предупреждение о разрешениях

    private var permissionsAlert: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .foregroundStyle(Color.ymYellow)
                .font(.system(size: 13))
            Text("Войдите в Яндекс — для избранного")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Войти") { loginYandex() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.ymYellow)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.ymYellow.opacity(0.06))
    }

    // MARK: - Кнопка «Открыть ЯМ»

    private var openYMButton: some View {
        Button(action: openYandexMusic) {
            HStack(spacing: 7) {
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text("Открыть Яндекс Музыку")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .medium))
                    .opacity(0.55)
            }
            .foregroundStyle(Color.ymYellow)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.ymYellow.opacity(0.06))
    }

    // MARK: - Нижняя панель

    private var compactFooter: some View {
        HStack {
            Spacer()
            Button(action: {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Открыть приложение и настройки")

            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Завершить приложение")
            .padding(.leading, 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // MARK: - Настройки

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Аккаунт Яндекс Музыки")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ymAuthorized ? "Вход выполнен" : "Вход не выполнен")
                        .font(.system(size: 12))
                    Text("Настоящие обложки и избранное")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if ymAuthorized {
                    Button("Выйти") {
                        YandexMusicAPI.shared.logout()
                        ymAuthorized = false
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("Войти") { loginYandex() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .tint(Color.ymYellow)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            Text("Разрешения")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            permRow(title: "Accessibility", subtitle: "Лайк/дизлайк и запасное чтение трека",
                    granted: axGranted) { YMTrackReader.requestAccessibilityPermission() }

            Divider()

            Text("Общее")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Запускать при входе").font(.system(size: 12))
                    Text("Открывать приложение при включении Mac")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.ymYellow)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .onChange(of: launchAtLogin) { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    // Откатываем переключатель, если система отказала
                    launchAtLogin = (SMAppService.mainApp.status == .enabled)
                }
            }

            Spacer(minLength: 14)
        }
        .frame(width: 280)
    }

    private func permRow(title: String, subtitle: String,
                         granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
            } else {
                Button("Разрешить", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.ymYellow)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func loginYandex() {
        YandexAuthController.shared.present { token in
            guard let token else { return }
            YandexMusicAPI.shared.applyToken(token) { ok in
                ymAuthorized = ok
                if ok { service.forceRefresh() }
            }
        }
    }

    private func openYandexMusic() {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Constants.Media.yandexMusicBundleID
        }) {
            app.activate(options: .activateAllWindows)
        } else if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Constants.Media.yandexMusicBundleID
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let t = Int(s); return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: date)
    }
}
