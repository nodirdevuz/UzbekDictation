#!/bin/bash
# Kapsula HAQIQATAN ko'rinyaptimi — takrorlanadigan tekshiruv.
#
# Nega kerak: kapsula qaysi Space'da chizilishi macOS ning ichki qarori (hujjatlashtirilmagan,
# versiyalar orasida o'zgaradi). 27.07 monitor tanlash tuzatildi, 28.07 esa o'sha kapsula
# TO'LIQ EKRANLI oynada ko'rinmay qoldi. "Ko'z bilan qaradim" degan tekshiruv shu sababli
# yetarli emas — bu skript ikkala holatni ham qayta tiklaydi va skrinshot qoldiradi.
#
#   tools/check-capsule.sh          — ikkala holat (oddiy ish stoli + to'liq ekran)
#
# Talab: terminalda Accessibility ruxsati (sintetik ⌘ bosishlari uchun).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/capsule-check"
mkdir -p "$OUT"

# Ekranning MANTIQIY o'lchami (2880x1800 Retina ≠ 1680x1050 nuqta) — skrinshot nuqtalarda.
read -r W H <<<"$(osascript -e 'tell application "Finder" to get bounds of window of desktop' | awk -F', ' '{print $3, $4}')"
X=$(( W / 2 - 220 ))
Y=$(( H - 190 ))

echo "[1/3] Vositalar"
swiftc -O "$ROOT/tools/simulate-taps.swift" -o "$OUT/taps" 2>/dev/null
swiftc -O "$ROOT/tools/fs-window.swift" -o "$OUT/fswin" 2>/dev/null

echo "[2/3] Oddiy ish stoli"
"$OUT/taps" tap2 >/dev/null
screencapture -x -T 2 -R"$X,$Y,440,180" "$OUT/desktop.png"
"$OUT/taps" esc >/dev/null

echo "[3/3] To'liq ekranli oyna (o'z oynamiz — egasining oynalariga tegmaymiz)"
("$OUT/fswin" >/dev/null 2>&1 &)
screencapture -x -T 4 -R"$X,$Y,440,180" "$OUT/_warmup.png"   # o'tish animatsiyasini kutamiz
"$OUT/taps" tap2 >/dev/null
screencapture -x -T 2 -R"$X,$Y,440,180" "$OUT/fullscreen.png"
"$OUT/taps" esc >/dev/null
pkill -f "$OUT/fswin" 2>/dev/null || true

echo
echo "Skrinshotlar (kapsula ikkalasida ham pastda, markazda ko'rinishi SHART):"
echo "  ish stoli:   $OUT/desktop.png"
echo "  to'liq ekran: $OUT/fullscreen.png"
