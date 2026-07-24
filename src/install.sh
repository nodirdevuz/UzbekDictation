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
    echo "[1/5] /Applications da nusxa yo'q — to'liq ko'chiramiz"
    cp -R "$BUILT" "$APP"
else
    echo "[1/5] Binarnik yangilanmoqda (modellar joyida qoladi)"
    pkill -f RubaiSTTDictation 2>/dev/null || true
    sleep 1
    cp "$BUILT/Contents/MacOS/RubaiSTTDictation" "$APP/Contents/MacOS/RubaiSTTDictation"
    cp "$BUILT/Contents/Info.plist" "$APP/Contents/Info.plist"
fi

echo "[2/5] Modellar tekshirilmoqda"
for m in ggml-rubaistt.bin ggml-multilingual.bin; do
    if [ -f "$APP/Contents/Resources/$m" ]; then
        echo "  ✓ $m"
    else
        echo "  ✗ $m TOPILMADI — diktovka ishlamaydi!" >&2
    fi
done

echo "[3/5] Imzolash"
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

echo "[4/5] Ishga tushirish"
open "$APP"
sleep 3

echo "[5/5] Login'da avtomatik ishga tushishi"
if launchctl list 2>/dev/null | grep -q com.rubaistt.dictation; then
    echo "  ✓ ro'yxatdan o'tgan"
else
    echo "  ! menyudagi «Login'da ishga tushirish» bandini yoqing"
fi

echo
echo "Tayyor. Ishlayotgan nusxa: $APP"
