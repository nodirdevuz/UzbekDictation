#!/bin/bash
# RubaiSTT Dictation — build.sh dan keyingi TO'G'RI o'rnatish.
#
# Nega alohida skript kerak: build.sh ilovani ~/Applications ga yig'adi, lekin
# tizim login'da /Applications dagi nusxani ishga tushiradi va MODELLAR ham
# faqat o'sha yerda. Agar faqat ~/Applications yangilansa, kompyuter qayta
# yuklangandan keyin eski versiya qaytib keladi — aynan shu holat 25.07.2026 da
# kuzatilgan.
#
# Shuning uchun bu skript: yangi binarnikni /Applications ga qo'yadi (modellarga
# tegmaydi), barqaror sertifikat bilan imzolaydi, login item'ni yoqadi va
# ilovani qayta ishga tushiradi.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
BUILT="$HOME/Applications/RubaiSTT Dictation.app"
APP="/Applications/RubaiSTT Dictation.app"
LOCAL_ID="RubaiSTT Local Signing"

[ -f "$BUILT/Contents/MacOS/RubaiSTTDictation" ] || { echo "Avval src/build.sh ni ishga tushiring" >&2; exit 1; }

if [ ! -d "$APP" ]; then
    echo "[1/6] /Applications da nusxa yo'q — to'liq ko'chiramiz"
    cp -R "$BUILT" "$APP"
else
    echo "[1/6] Binarnik yangilanmoqda (modellar joyida qoladi)"
    pkill -f RubaiSTTDictation 2>/dev/null || true
    sleep 1
    cp "$BUILT/Contents/MacOS/RubaiSTTDictation" "$APP/Contents/MacOS/RubaiSTTDictation"
    cp "$BUILT/Contents/MacOS/rubai-asr" "$APP/Contents/MacOS/rubai-asr"
    cp "$BUILT/Contents/Info.plist" "$APP/Contents/Info.plist"
fi

echo "[2/6] Modellar tekshirilmoqda"
# Имя должно совпадать с Whisper.modelFile в dictate.swift (папка Parakeet v3)
MODEL="parakeet-v3"
if [ ! -f "$APP/Contents/Resources/$MODEL/encoder.int8.onnx" ] && [ -f "$HOME/rubai-stt/models/$MODEL/encoder.int8.onnx" ]; then
    rm -rf "$APP/Contents/Resources/$MODEL"
    cp -R "$HOME/rubai-stt/models/$MODEL" "$APP/Contents/Resources/$MODEL"
fi
# Старые модели Whisper больше не используются — освобождаем место
rm -f "$APP"/Contents/Resources/ggml-*.bin
if [ -f "$APP/Contents/Resources/$MODEL/encoder.int8.onnx" ]; then
    echo "  ✓ $MODEL"
else
    echo "  ✗ $MODEL TOPILMADI — diktovka ishlamaydi! (tools/fetch-gigaam.sh)" >&2
fi

echo "[3/6] Imzolash"
xattr -cr "$APP" 2>/dev/null || true
if security find-certificate -c "$LOCAL_ID" >/dev/null 2>&1; then
    codesign --force --deep --sign "$LOCAL_ID" --entitlements "$SRC/entitlements.plist" "$APP" 2>/dev/null \
        || codesign --force --deep --sign "$LOCAL_ID" "$APP"
    echo "  imzo: $LOCAL_ID (ruxsatlar saqlanadi)"
else
    codesign --force --deep --sign - --entitlements "$SRC/entitlements.plist" "$APP" 2>/dev/null \
        || codesign --force --deep --sign - "$APP"
    echo "  DIQQAT: ad-hoc imzo — har build'dan keyin Accessibility ruxsatini qayta berish kerak bo'ladi" >&2
fi

echo "[4/6] Ishga tushirish"
open "$APP"
sleep 3

echo "[5/6] launchd-sug'urta (jarayon o'lsa, 2 daqiqada qaytadan ko'taradi)"
# Приложение само лечит зависания (src/supervisor.swift), но если процесс УМЕР (краш, kill),
# кроме launchd его поднять некому. Выход из меню («Выйти») ставит метку user-quit — тогда не поднимаем.
KA="$HOME/Library/LaunchAgents/com.rubaistt.dictation.keepalive.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$KA" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.rubaistt.dictation.keepalive</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>[ -e "$HOME/Library/Application Support/RubaiSTT/user-quit" ] &amp;&amp; exit 0; /usr/bin/pgrep -x RubaiSTTDictation &gt;/dev/null || /usr/bin/open -a "/Applications/RubaiSTT Dictation.app"</string>
    </array>
    <key>StartInterval</key><integer>120</integer>
    <key>RunAtLoad</key><false/>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PL
launchctl bootout "gui/$(id -u)" "$KA" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$KA" && echo "  ✓ keepalive o'rnatildi"

echo "[6/6] Login'da avtomatik ishga tushishi"
if launchctl list 2>/dev/null | grep -q com.rubaistt.dictation; then
    echo "  ✓ ro'yxatdan o'tgan"
else
    echo "  ! menyudagi «Login'da ishga tushirish» bandini yoqing"
fi

echo
echo "Tayyor. Ishlayotgan nusxa: $APP"
