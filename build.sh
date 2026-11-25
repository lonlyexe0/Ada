#!/bin/bash
# Ada'yı derler, ~/Applications/Ada.app olarak kurar ve açar.
#   ./build.sh            → derle + kur + aç
#   ./build.sh --no-run   → sadece derle (build/Ada.app)
set -euo pipefail
cd "$(dirname "$0")"

echo "→ Derleniyor..."
swift build -c release

APP="build/Ada.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Ada "$APP/Contents/MacOS/Ada"
cp Info.plist "$APP/Contents/Info.plist"
# İmzayı uygulama kimliğine bağla: böylece her derlemede macOS
# "bu yeni bir uygulama" deyip Müzik iznini tekrar sormaz.
codesign --force --sign - \
    --requirements '=designated => identifier "local.ada.island"' \
    "$APP" >/dev/null 2>&1
echo "→ Hazır: $APP"

if [[ "${1:-}" != "--no-run" ]]; then
    # Sabit bir yere kur: "Mac açılınca başlat" bu kopyayı açar.
    INSTALLED="$HOME/Applications/Ada.app"
    pkill -x Ada 2>/dev/null || true
    sleep 0.3
    mkdir -p "$HOME/Applications"
    rm -rf "$INSTALLED"
    ditto "$APP" "$INSTALLED"
    open "$INSTALLED"
    echo "→ Kuruldu ve açıldı: $INSTALLED"
    echo "→ Kapatmak için: menü çubuğundaki kapsül ikonu → Ada'dan çık"
fi
