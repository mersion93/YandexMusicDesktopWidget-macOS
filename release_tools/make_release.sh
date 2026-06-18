#!/bin/bash
# Собирает релизный DMG: встраивает адаптер, переподписывает ad-hoc, пакует.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
APP_SRC="build/Release/Build/Products/Release/YandexMusicDesktopWidget.app"
OUT="release_tools/dist"
APP="$OUT/YandexMusicDesktopWidget.app"
ENT_APP="release_tools/app.entitlements"
ENT_WIDGET="release_tools/widget.entitlements"
ADAPTER="Vendor/MediaRemoteAdapter"

echo "▸ Подготовка $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"
cp -R "$APP_SRC" "$APP"

echo "▸ Встраиваю mediaremote-adapter в Resources"
rm -rf "$APP/Contents/Resources/MediaRemoteAdapter"
cp -R "$ADAPTER" "$APP/Contents/Resources/MediaRemoteAdapter"

echo "▸ Удаляю dev-провижининг (ad-hoc его не использует)"
rm -f "$APP/Contents/embedded.provisionprofile"
find "$APP/Contents/PlugIns" -name "embedded.provisionprofile" -delete 2>/dev/null || true

# Переподписываем изнутри наружу. --force перезаписывает существующую подпись.
echo "▸ Подпись вложенных .dylib/.framework адаптера (ad-hoc)"
find "$APP/Contents/Resources/MediaRemoteAdapter" \( -name "*.dylib" -o -name "*.framework" \) -print0 \
  | while IFS= read -r -d '' f; do codesign --force --sign - --timestamp=none "$f"; done

echo "▸ Подпись виджет-расширения (ad-hoc, sandbox)"
WIDGET="$APP/Contents/PlugIns/YandexMusicDesktopWidgetExtension.appex"
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements "$ENT_WIDGET" "$WIDGET"

echo "▸ Подпись основного приложения (ad-hoc, library validation off)"
# БЕЗ --deep: вложенные (адаптер-framework + appex) уже подписаны выше; --deep
# переподписал бы вендорный MediaRemoteAdapter.framework и портил печать бандла
# (codesign --verify проходит, но LaunchServices/pkd отвергают → виджета нет в галерее).
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements "$ENT_APP" "$APP"

echo "▸ Проверка подписи"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3 || true

echo "▸ Собираю DMG"
DMG="release_tools/YandexMusicDesktopWidget-$VERSION.dmg"
STAGE="$OUT/dmg_stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp release_tools/INSTALL.txt "$STAGE/Как установить.txt" 2>/dev/null || true
rm -f "$DMG"
hdiutil create -volname "YandexMusicWidget" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null
echo "✅ Готово: $DMG"
ls -lh "$DMG"
