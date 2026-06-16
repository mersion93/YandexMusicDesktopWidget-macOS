# Архитектура YandexMusicDesktopWidget

Документ описывает назначение каждого файла и ключевые механизмы. Цель — чтобы по нему
можно было быстро понять, что за что отвечает.

---

## Цели (таргеты)

| Таргет | Bundle ID | Песочница | Назначение |
|--------|-----------|-----------|------------|
| Приложение | `com.yandexmusic.widget` | **выкл** (нужен Accessibility) | читает трек, пишет данные, исполняет команды |
| Виджет | `com.yandexmusic.widget.extension` | **вкл** | только читает данные и шлёт действия |

Общий канал данных — **App Group** `group.com.yandexmusic.widget`
(`~/Library/Group Containers/...`): приложение пишет, виджет читает.

---

## Shared/ — общий код обоих таргетов

- **SharedModels.swift** — модели данных: `TrackInfo` (трек: название, исполнитель,
  обложка, длительность, позиция, статус лайка, какой плеер), `WidgetSettings` (акцент, фон,
  показ исполнителя/кнопок), `AccentPalette` (пресеты цветов), `PendingAction` (действие из
  виджета), `LikeState`.
- **Constants.swift** — константы: список плееров и их bundle id, имена, интервалы опроса,
  заглушки названий.
- **AppGroupManager.swift** — мост через App Group: `saveTrack`/`loadTrack` (`track.json`),
  токен/uid Яндекса, `WidgetSettings`, `PendingAction`. Используется и приложением, и виджетом.

---

## YandexMusicDesktopWidget/ — основное приложение

- **YandexMusicDesktopWidgetApp.swift** — `@main`: пункт меню-бара (попап), окно приложения
  (`Window id: "main"`), `AppDelegate`. Запускает сервисы при старте.
- **ContentView.swift** — попап меню-бара. Два стиля через `@AppStorage("popup_style")`:
  `compactLayout` (узкая строка) и `cardLayout` (крупная обложка по центру). Анимированный
  эквалайзер, перемотка, лайк/дизлайк.
- **MainWindowView.swift** — окно приложения: разделы **Сейчас играет**, **Плееры**,
  **Настройки** (аккаунт, Accessibility, автозапуск, стиль попапа с превью), **О программе**,
  онбординг. Здесь же мини-макеты `CompactMock`/`CardMock` для превью стилей.
- **NowPlayingService.swift** — **ядро**. Сводит источники трека, держит `currentTrack`,
  пишет в App Group, перезагружает виджет, обрабатывает действия из виджета
  (`processPendingAction`), ставит лайки (через API, AX — фолбэк), подтягивает HD-обложку.
  Здесь же логика перезагрузки виджета (см. ниже).
- **NowPlayingStreamer.swift** — **основной источник**: постоянный процесс
  `mediaremote-adapter` (`stream`), событийно отдаёт NDJSON с данными трека (~0% CPU).
  Также `pollNow()` (разовый `get`) и `seek()` (перемотка).
- **MediaRemoteHelper.swift** — разовое чтение Now Playing (используется как фолбэк/проверка
  доступности).
- **YandexMusicAPI.swift** — Яндекс API: OAuth (`YandexAuthController`, WKWebView), поиск трека,
  лайки (`setLike`/`refreshLikes`/`isLiked`), HD-обложка `highResCover` (строгое совпадение
  названия, 1000×1000). Токен/uid хранятся в App Group.
- **YMTrackReader.swift** — запасное чтение трека через Accessibility (когда стрим недоступен);
  чистка префиксов «Артист …»/«Трек …».
- **YMAccessibilityObserver.swift** — наблюдение за окном ЯМ через AXObserver.
- **YMActionController.swift** — лайк/дизлайк/повтор/перемешивание через симуляцию кликов в окне
  ЯМ (AX). Используется как фолбэк, когда нет токена API.
- **MediaKeyController.swift** — системные медиаклавиши (плей/пауза, вперёд, назад) через
  `CGEvent`. Работают для любого активного плеера.

---

## YandexMusicDesktopWidgetExtension/ — виджет (WidgetKit)

- **DesktopMusicWidgetBundle.swift** — точка входа виджета.
- **DesktopMusicWidget.swift** — виды `SmallWidgetView` / `MediumWidgetView` / `LargeWidgetView`
  + вспомогательные (`ArtworkThumb`, `ArtworkFullBleed`, `SideControls`, `StatusPill`,
  `EmptyStateView`). Большой виджет — обложка на весь фон. Обложка привязана к `track.id`
  с мягким `contentTransition`, чтобы смена была одним плавным переходом.
- **WidgetProvider.swift** — таймлайн: читает `track.json` и `WidgetSettings`, отдаёт один entry
  с политикой `.after(15s)` (пульс-страховка). `ConfigurationAppIntent` — параметры оформления
  (акцент, фон, показ исполнителя/кнопок) в редакторе виджета.
- **PlaybackIntents.swift** — кнопки виджета (`AppIntent`): кладут `PendingAction` в App Group,
  приложение их исполняет (CGEvent из песочницы недоступен).

---

## Ключевые механизмы

### Перезагрузка виджета (без «застоя» и без тормозов)
В `NowPlayingService`:
- **Смена трека/паузы** → `reloadWidgetForcefully()`: мгновенный `reloadAllTimelines()`
  + два бэкапа (1.5с и 4с) на случай, если система отбросила первый пуш.
- **Мелкие обновления** (статус лайка, HD-обложка) → `reloadWidgetDebounced()`:
  мгновенно на первое изменение, частые повторы схлопываются (0.3с).
- **Пульс** в `WidgetProvider` — `.after(15s)`: таймлайн-обновление другого типа, не зависит
  от пушей; страховка, чтобы виджет никогда не зависал надолго. Короче 15с нельзя — частый
  пульс исчерпывает бюджет WidgetKit, и система начинает резать обновления.

### HD-обложка
Родная обложка из стрима ~300px и мылит на большом виджете. Для треков ЯМ (при входе)
`NowPlayingService` подменяет её на 1000×1000 из API (`hdCoverCache`, строгое совпадение
названия) и пишет в `track.json`.

### Подпись и распространение
- На машину разработчика — **dev-подпись** (Apple Development): разрешения Accessibility
  сохраняются между пересборками.
- В DMG для раздачи — **ad-hoc** (`release_tools/make_release.sh`): снимает привязку к
  устройствам, добавляет `disable-library-validation` (чтобы адаптер грузился на чужих Маках).
  Пользователь один раз снимает карантин и выдаёт Accessibility.

---

## Поток данных (коротко)

```
mediaremote-adapter (stream)
        │  события Now Playing
        ▼
NowPlayingStreamer ──► NowPlayingService ──► track.json (App Group) ──► WidgetProvider ──► виджет
                              │                                              ▲
                              ├── YandexMusicAPI (HD-обложка, лайки)         │ reloadAllTimelines()
                              └── ContentView / MainWindowView (UI)          │
                                                                            │
виджет: PlaybackIntents ──► PendingAction (App Group) ──► NowPlayingService ┘ (исполняет)
```
