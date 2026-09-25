#!/bin/bash
# Собирает «Шторку». Xcode не нужен — хватает Command Line Tools.
#
#   ./build.sh            собрать build/Шторка.app
#   ./build.sh --install  ещё и поставить в /Applications и перезапустить
#   ./build.sh --dmg      ещё и собрать ../Shtorka.dmg для релиза на GitHub
#   ./build.sh --selftest только прогнать самопроверку (отдельная тестовая сборка, приложение не трогает)
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "--selftest" ]]; then
  mkdir -p build/selftest
  swiftc -swift-version 5 -target arm64-apple-macos14.0 -D SELFTEST \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist \
    -o build/selftest/Shtorka-selftest Sources/*.swift
  pkill -x Shtorka && echo "(Шторка закрыта на время теста)" || true
  status=0
  build/selftest/Shtorka-selftest --selftest "$PWD/build/selftest" || status=$?
  [[ -d "/Applications/Шторка.app" ]] && open "/Applications/Шторка.app"
  exit $status
fi

APP="build/Шторка.app"
BIN="$APP/Contents/MacOS/Shtorka"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Универсальный бинарник: Apple Silicon + Intel
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" -o "build/Shtorka-$arch" Sources/*.swift
done
lipo -create -output "$BIN" build/Shtorka-arm64 build/Shtorka-x86_64
cp Info.plist "$APP/Contents/Info.plist"

# Иконка: рисуем PNG самим приложением и собираем .icns
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
"$BIN" --render-icon build/icon-1024.png
for size in 16 32 128 256 512; do
  sips -z $size $size build/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double build/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Собрано: $APP"

for arg in "$@"; do
  case "$arg" in
    --install)
      pkill -x Shtorka || true
      sleep 0.5
      rm -rf "/Applications/Шторка.app"
      ditto "$APP" "/Applications/Шторка.app"
      open "/Applications/Шторка.app"
      echo "Установлено в /Applications и запущено"
      ;;
    --dmg)
      STAGE="build/dmg"
      mkdir -p "$STAGE"
      ditto "$APP" "$STAGE/Шторка.app"
      ln -s /Applications "$STAGE/Программы"
      rm -f ../Shtorka.dmg
      hdiutil create -quiet -volname "Шторка" -srcfolder "$STAGE" -ov -format UDZO ../Shtorka.dmg
      echo "Установщик: ../Shtorka.dmg"
      ;;
  esac
done
