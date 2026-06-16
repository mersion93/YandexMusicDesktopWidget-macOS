#!/bin/bash
# Устанавливает свежесобранную версию приложения в /Applications со стабильным
# состоянием для разрешений (Accessibility / Запись экрана).
#
# Как пользоваться:
#   1. Соберите проект в Xcode (⌘B) — Team можно оставить "None" (ad-hoc).
#   2. Дважды кликните по этому файлу install.command в Finder.
#   3. Выдайте приложению разрешение Accessibility (один раз).
#
# Запускайте приложение ВСЕГДА из /Applications (Launchpad / Finder),
# а не из Xcode — иначе подпись меняется и разрешение слетает.

set -e

BUNDLE_ID="com.yandexmusic.widget"
APP_NAME="YandexMusicDesktopWidget.app"
DST="/Applications/$APP_NAME"

echo "==> Ищу свежую сборку в DerivedData..."
SRC=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path "*/Build/Products/Debug/$APP_NAME" \
        -not -path "*/Index.noindex/*" \
        -type d 2>/dev/null \
      | xargs -I{} stat -f "%m %N" {} 2>/dev/null \
      | sort -rn | head -1 | cut -d' ' -f2-)

if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
  echo "❌ Сборка не найдена. Сначала соберите проект в Xcode (⌘B)."
  read -n 1 -s -r -p "Нажмите любую клавишу для выхода..."
  exit 1
fi
echo "    Найдено: $SRC"

echo "==> Закрываю запущенную копию (если открыта)..."
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
pkill -f "/Applications/$APP_NAME" 2>/dev/null || true
sleep 1

echo "==> Копирую в /Applications..."
rm -rf "$DST"
cp -R "$SRC" "$DST"

echo "==> Снимаю карантин..."
xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true

echo "==> Переподписываю (deep, ad-hoc)..."
codesign --force --deep --sign - "$DST"
codesign --verify --deep --strict "$DST" && echo "    ✅ подпись валидна"

echo "==> Сбрасываю старые разрешения (TCC)..."
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true

echo "==> Запускаю приложение..."
open "$DST"

echo ""
echo "✅ Готово. Теперь:"
echo "   1. В окне приложения нажмите «Разрешить» у Accessibility"
echo "   2. Включите тумблер «YandexMusicDesktopWidget» в Универсальном доступе"
echo "   3. Нажмите «Опросить сейчас» — трек должен появиться"
echo ""
read -n 1 -s -r -p "Нажмите любую клавишу для выхода..."
