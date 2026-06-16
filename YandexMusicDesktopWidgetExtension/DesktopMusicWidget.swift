import SwiftUI
import WidgetKit
import AppIntents
import AppKit

// MARK: - Brand colors

private extension Color {
    static let ymYellow = Color(red: 1.00, green: 0.84, blue: 0.00)  // #FFD600
    static let ymDark   = Color(red: 0.09, green: 0.09, blue: 0.09)  // #171717
    static let ymCard   = Color(red: 0.14, green: 0.14, blue: 0.14)  // #242424
    static let ymDim    = Color(white: 0.55)

    /// Акцентный цвет из пользовательских настроек виджета.
    static func accent(_ name: String) -> Color {
        let c = AccentPalette.rgb(name)
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

// MARK: - Entry router

struct DesktopMusicWidgetEntryView: View {
    let entry: MusicEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let s = entry.configuration.widgetSettings
        if entry.track.isPlaceholder {
            EmptyStateView(s: s)
        } else {
            switch family {
            case .systemSmall:  SmallWidgetView(track: entry.track, s: s)
            case .systemMedium: MediumWidgetView(track: entry.track, s: s)
            case .systemLarge:  LargeWidgetView(track: entry.track, s: s)
            default:            MediumWidgetView(track: entry.track, s: s)
            }
        }
    }
}

// MARK: - Пустой вид (ничего не играет) ─────────────────────────────────────────

struct EmptyStateView: View {
    var s: WidgetSettings = .default
    @Environment(\.widgetFamily) private var family
    private var accent: Color { .accent(s.accent) }

    var body: some View {
        VStack(spacing: family == .systemSmall ? 8 : 12) {
            Image(systemName: "music.note")
                .font(.system(size: family == .systemSmall ? 26 : 34, weight: .semibold))
                .foregroundStyle(accent.opacity(0.9))
            VStack(spacing: 3) {
                Text(tr("Ничего не играет", "Nothing is playing"))
                    .font(.system(size: family == .systemSmall ? 12 : 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                if family != .systemSmall {
                    Text(tr("Включите трек в плеере", "Start a track in your player"))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .containerBackground(for: .widget) { Color.ymDark }
    }
}

// MARK: - Small ───────────────────────────────────────────────────────────────

struct SmallWidgetView: View {
    let track: TrackInfo
    var s: WidgetSettings = .default
    private var accent: Color { .accent(s.accent) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Button(intent: OpenYandexMusicIntent()) {
                    ArtworkThumb(data: track.artworkData, size: 52)
                        .contentTransition(.opacity)
                        .id("small-art-\(track.id)")
                }
                .buttonStyle(.plain)
                Spacer()
                if track.isPlaying {
                    MiniWave(color: accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.25))
                        .clipShape(Capsule())
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                    .id("small-title-\(track.id)")
                if s.showArtist {
                    Text(track.artist)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .id("small-artist-\(track.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                WidgetBtn(intent: PreviousTrackIntent(), icon: "backward.fill", size: 13)
                Spacer()
                WidgetBtn(
                    intent: PlayPauseIntent(),
                    icon: track.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                    size: 32, accent: true, accentColor: accent
                )
                Spacer()
                WidgetBtn(intent: NextTrackIntent(), icon: "forward.fill", size: 13)
            }
            .padding(.horizontal, 4)
        }
        .padding(14)
        .containerBackground(for: .widget) { ArtworkBlurBackground(data: track.artworkData, solid: s.background == "solid") }
    }
}

// MARK: - Medium ──────────────────────────────────────────────────────────────

struct MediumWidgetView: View {
    let track: TrackInfo
    var s: WidgetSettings = .default
    private var accent: Color { .accent(s.accent) }

    var body: some View {
        GeometryReader { geo in
            // Обложка во всю высоту, но не шире 38% ширины — чтобы кнопки справа влезали.
            let art = min(geo.size.height, geo.size.width * 0.38)
            HStack(spacing: 16) {
                Button(intent: OpenYandexMusicIntent()) {
                    ArtworkThumb(data: track.artworkData, size: art)
                        .contentTransition(.opacity)
                        .id("med-art-\(track.id)")
                }
                .buttonStyle(.plain)
                .layoutPriority(1)

                VStack(alignment: .leading, spacing: 0) {
                    StatusPill(isPlaying: track.isPlaying, accent: accent)

                    Spacer(minLength: 6)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .contentTransition(.opacity)
                            .id("med-title-\(track.id)")
                        if s.showArtist {
                            Text(track.artist)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                                .contentTransition(.opacity)
                                .id("med-artist-\(track.id)")
                        }
                    }

                    Spacer(minLength: 10)

                    HStack(spacing: 18) {
                        WidgetBtn(intent: PreviousTrackIntent(), icon: "backward.fill", size: 15)
                        WidgetBtn(
                            intent: PlayPauseIntent(),
                            icon: track.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                            size: 36, accent: true, accentColor: accent
                        )
                        WidgetBtn(intent: NextTrackIntent(), icon: "forward.fill", size: 15)
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Лайк/дизлайк — только для Яндекс Музыки и если включены в настройках
                if track.isYandex && s.showLikeButtons {
                    SideControls(likeState: track.likeState, size: 16, spacing: 20, accent: accent)
                        .layoutPriority(1)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(18)
        .containerBackground(for: .widget) { ArtworkBlurBackground(data: track.artworkData, solid: s.background == "solid") }
    }
}

// MARK: - Large ───────────────────────────────────────────────────────────────

struct LargeWidgetView: View {
    let track: TrackInfo
    var s: WidgetSettings = .default
    private var accent: Color { .accent(s.accent) }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Обложка в ТЕЛЕ виджета (а не только в containerBackground) — иначе в
            // неактивном состоянии рабочего стола система приглушает фон и фото
            // пропадает. Декодируется один раз (containerBackground — простой цвет).
            Button(intent: OpenYandexMusicIntent()) {
                ArtworkFullBleed(data: track.artworkData, solid: s.background == "solid")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .contentTransition(.opacity)
                    .id("lg-art-\(track.id)")
            }
            .buttonStyle(.plain)

            // Нижняя панель с информацией и управлением — поверх обложки.
            VStack(alignment: .leading, spacing: 0) {
                StatusPill(isPlaying: track.isPlaying, accent: accent)
                Spacer(minLength: 8)
                Text(track.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    .contentTransition(.opacity)
                    .id("lg-title-\(track.id)")
                if s.showArtist {
                    Text(track.artist)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .padding(.top, 2)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                        .contentTransition(.opacity)
                        .id("lg-artist-\(track.id)")
                }

                HStack(spacing: 16) {
                    WidgetBtn(intent: PreviousTrackIntent(), icon: "backward.fill", size: 20)
                    WidgetBtn(
                        intent: PlayPauseIntent(),
                        icon: track.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                        size: 48, accent: true, accentColor: accent
                    )
                    WidgetBtn(intent: NextTrackIntent(), icon: "forward.fill", size: 20)
                    Spacer()
                    if track.isYandex && s.showLikeButtons {
                        HStack(spacing: 16) {
                            LikeButton(likeState: track.likeState, size: 19, accent: accent)
                            DislikeButton(likeState: track.likeState, size: 19)
                        }
                    }
                }
                .padding(.top, 14)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.35), .black.opacity(0.85)],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
        .containerBackground(for: .widget) { Color.ymDark }
    }
}

// MARK: - Shared sub-views ────────────────────────────────────────────────────

/// Размытая обложка как фон + затемнение — премиальный вид, читаемый текст.
struct ArtworkBlurBackground: View {
    let data: Data?
    var solid: Bool = false
    var body: some View {
        ZStack {
            if !solid, let data, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 28)
                    .opacity(0.5)
            }
            Color.ymDark.opacity((solid || data == nil) ? 1 : 0.62)
            LinearGradient(
                colors: [.black.opacity(0.05), .black.opacity(0.4)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }
}

/// Обложка во всю ширину (квадрат) — максимально крупная для большого виджета.
struct ArtworkBig: View {
    let data: Data?
    var body: some View {
        Group {
            if let data, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                YMPlaceholder()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
    }
}

/// Обложка во весь фон (full-bleed) для большого виджета.
struct ArtworkFullBleed: View {
    let data: Data?
    var solid: Bool = false
    var body: some View {
        ZStack {
            if let data, let img = NSImage(data: data) {
                if solid {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).blur(radius: 30).opacity(0.5)
                    Color.ymDark.opacity(0.55)
                } else {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                }
            } else {
                YMPlaceholder()
            }
        }
    }
}

struct LikeButton: View {
    let likeState: LikeState
    var size: CGFloat = 18
    var accent: Color = .ymYellow
    var body: some View {
        Button(intent: LikeIntent()) {
            Image(systemName: likeState == .liked ? "heart.fill" : "heart")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(likeState == .liked ? accent : Color.white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }
}

struct DislikeButton: View {
    let likeState: LikeState
    var size: CGFloat = 18
    var body: some View {
        Button(intent: DislikeIntent()) {
            Image(systemName: likeState == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(likeState == .disliked
                    ? Color(red: 1, green: 0.32, blue: 0.32) : Color.white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }
}

/// Вертикальная колонка: лайк и дизлайк.
struct SideControls: View {
    let likeState: LikeState
    var size: CGFloat = 15
    var spacing: CGFloat = 18
    var accent: Color = .ymYellow

    var body: some View {
        VStack(spacing: spacing) {
            LikeButton(likeState: likeState, size: size, accent: accent)
            DislikeButton(likeState: likeState, size: size)
        }
    }
}

/// Чёткая обложка со скруглением, тонкой рамкой и тенью.
struct ArtworkThumb: View {
    let data: Data?
    let size: CGFloat
    var body: some View {
        Group {
            if let data, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                YMPlaceholder()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.13, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
    }
}

/// Капсула статуса: «Играет» с эквалайзером или «Пауза».
struct StatusPill: View {
    let isPlaying: Bool
    var accent: Color = .ymYellow
    var body: some View {
        HStack(spacing: 5) {
            if isPlaying {
                MiniWave(color: accent)
                Text(tr("Играет", "Playing"))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
            } else {
                Circle().fill(Color.ymDim).frame(width: 5, height: 5)
                Text(tr("Пауза", "Paused"))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.black.opacity(0.28))
        .clipShape(Capsule())
    }
}

struct ArtworkFill: View {
    let data: Data?
    var body: some View {
        Group {
            if let data, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                YMPlaceholder()
            }
        }
        .clipped()
    }
}

struct ArtworkSquare: View {
    let data: Data?
    let size: CGFloat
    var body: some View {
        Group {
            if let data, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                YMPlaceholder()
                    .frame(width: size, height: size)
            }
        }
    }
}

struct YMPlaceholder: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Color(red: 0.22, green: 0.08, blue: 0.02),
                    Color(red: 0.07, green: 0.07, blue: 0.07)
                ],
                center: .center,
                startRadius: 10,
                endRadius: 110
            )
            VStack(spacing: 4) {
                Text("Я")
                    .font(.system(size: 52, weight: .black))
                    .foregroundStyle(Color.ymYellow)
                Text(tr("Музыка", "Music"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.38))
                    .tracking(2.5)
            }
        }
    }
}

struct MiniWave: View {
    var color: Color = .ymYellow
    @State private var phase = false
    private let heights: [Double] = [0.6, 1.0, 0.75, 0.45]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(heights.indices, id: \.self) { i in
                let h = heights[i]
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: phase ? 9 * h : 4 * h)
                    .animation(
                        .easeInOut(duration: 0.38 + h * 0.22)
                        .repeatForever(autoreverses: true),
                        value: phase
                    )
            }
        }
        .frame(height: 10)
        .onAppear { phase = true }
    }
}

struct WidgetBtn<I: AppIntent>: View {
    let intent: I
    let icon: String
    let size: CGFloat
    var accent: Bool = false
    var accentColor: Color = .ymYellow

    var body: some View {
        Button(intent: intent) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundStyle(accent ? accentColor : Color.white.opacity(0.88))
        }
        .buttonStyle(.plain)
    }
}

struct LikeDislikeButtons: View {
    let likeState: LikeState
    var size: CGFloat = 14
    var spacing: CGFloat = 12

    var body: some View {
        Button(intent: LikeIntent()) {
            Image(systemName: likeState == .liked ? "heart.fill" : "heart")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(likeState == .liked
                    ? Color.ymYellow
                    : Color.white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }
}
