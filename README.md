<div align="center">

# 🎵 YandexMusicDesktopWidget

**Виджет «Сейчас играет» для Яндекс Музыки на macOS** — рабочий стол и меню-бар,
обложка в HD, лайки и управление воспроизведением.

**Русский** · [English](README.en.md)

![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
[![Release](https://img.shields.io/github/v/release/mersion93/YandexMusicDesktopWidget-macOS?color=ffcc00&label=релиз)](../../releases/latest)
[![Downloads](https://img.shields.io/github/downloads/mersion93/YandexMusicDesktopWidget-macOS/total?color=ffcc00&label=скачиваний)](../../releases)
[![License](https://img.shields.io/badge/лицензия-MIT-blue)](LICENSE)

<img src="docs/screenshot2.png" width="640" alt="Виджеты на рабочем столе">

</div>

---

## ✨ Возможности

| | |
|---|---|
| 🎵 Виджеты трёх размеров на рабочем столе | 🖼 Обложка в высоком качестве |
| ❤️ Лайк / дизлайк прямо из виджета | ⏯ Плей/пауза, переключение, перемотка |
| 🪟 Меню-бар попап (2 стиля) + окно | 🌍 Русский и английский интерфейс |
| 🚀 Автозапуск при входе в систему | ⚡️ Работает, даже когда плеер свёрнут |

## 📥 Установка

1. Скачайте **`YandexMusicDesktopWidget-1.0.0.dmg`** из раздела **[Releases](../../releases/latest)**.
2. Откройте DMG и перетащите приложение в папку **Программы**.
3. **Первый запуск.** Приложение бесплатное и не имеет платной подписи Apple, поэтому macOS
   попросит подтверждение **один раз** — любым способом:

   <details>
   <summary><b>Способ 1 — без Терминала (рекомендуется)</b></summary>

   - Двойной клик по приложению → в окне предупреждения нажмите **Отмена**.
   - Откройте **Системные настройки → Конфиденциальность и безопасность**.
   - Внизу будет строка про заблокированное приложение → нажмите **«Открыть всё равно»** → подтвердите паролем.
   - Дальше приложение открывается обычным двойным кликом.
   </details>

   <details>
   <summary><b>Способ 2 — одна команда в Терминале</b></summary>

   ```bash
   xattr -dr com.apple.quarantine /Applications/YandexMusicDesktopWidget.app
   ```
   Затем запустите приложение двойным кликом.
   </details>

4. В окне приложения → **Настройки** войдите в Яндекс (для обложек и лайков).
5. Добавьте виджет: правый клик по рабочему столу → **Изменить виджеты** → «YandexMusicWidget».

## 🛠 Сборка из исходников

Нужен Xcode 16+ и macOS 14+:

```bash
bash release_tools/make_release.sh 1.0.0   # собирает .app и DMG
```

Описание архитектуры — в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## 📄 Лицензия

[MIT](LICENSE). Компонент `Vendor/MediaRemoteAdapter` —
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (своя лицензия).
