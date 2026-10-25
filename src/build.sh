#!/bin/bash
# RubaiSTT Dictation — native macOS ilovasini build qiladi.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"
# Движок распознавания — sherpa-onnx + GigaAM v3 (с 25.10.2026, вместо whisper.cpp).
# Библиотеки скачивает tools/fetch-gigaam.sh. Только arm64 (Apple Silicon).
SO="$ROOT/sherpa-onnx"
APP="$HOME/Applications/RubaiSTT Dictation.app"
if [ ! -f "$SO/lib/libsherpa-onnx-c-api.a" ]; then
    echo "Xato: sherpa-onnx topilmadi ($SO). Avval tools/fetch-gigaam.sh ni ishga tushiring." >&2
    exit 1
fi

# Kompyuterni qizdirmaslik uchun past prioritet bilan
NICE="nice -n 10"

# Command Line Tools бывают «наполовину обновлены»: новейший SDK собран более новым
# Swift, чем установленный компилятор, и сборка падает («this SDK is not supported by
# the compiler»). Тогда берём самый свежий SDK, который этот компилятор понимает.
if [ -z "$SDKROOT" ]; then
    probe="$(mktemp -d)"
    echo 'import AppKit' > "$probe/p.swift"
    for sdk in $(xcrun --show-sdk-path) $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
        if SDKROOT="$sdk" swiftc -typecheck "$probe/p.swift" >/dev/null 2>&1; then
            export SDKROOT="$sdk"; break
        fi
    done
    rm -rf "$probe"
    echo "SDK: ${SDKROOT:-standart}"
fi

COMMON_FW="-framework Foundation -framework Accelerate -framework AVFoundation \
    -framework AppKit -framework QuartzCore -framework CoreGraphics \
    -framework Carbon -framework ApplicationServices"

echo "[1/4] Kompilyatsiya + linking (arm64)..."
L="$SO/lib"
# Модель живёт в отдельном процессе rubai-asr (asr_helper.c): его закрывают в простое,
# и вся память sherpa-onnx уходит. Приложение с ним говорит через asr_client.c.
$NICE clang -O2 -arch arm64 -mmacosx-version-min=13.0 "$SRC/asr_helper.c" -I"$SO/include" -I"$SRC" \
    "$L/libsherpa-onnx-c-api.a" "$L/libsherpa-onnx-core.a" "$L/libsherpa-onnx-fstfar.a" \
    "$L/libsherpa-onnx-fst.a" "$L/libsherpa-onnx-kaldifst-core.a" "$L/libkaldi-native-fbank-core.a" \
    "$L/libkaldi-decoder-core.a" "$L/libkissfft-float.a" "$L/libssentencepiece_core.a" \
    "$L/libutf8proc.a" "$L/libonnxruntime.a" \
    -framework Foundation -framework CoreML -lc++ -o "$SRC/rubai-asr"
$NICE clang -c "$SRC/asr_client.c" -arch arm64 -O2 -mmacosx-version-min=13.0 -o "$SRC/asr_client.o"
$NICE swiftc -O -target arm64-apple-macos13.0 "$SRC/dictate.swift" "$SRC/audio.swift" "$SRC/terms.swift" "$SRC/supervisor.swift" "$SRC/asr_client.o" \
    -import-objc-header "$SRC/Bridging.h" \
    $COMMON_FW \
    -o "$SRC/RubaiSTTDictation"
rm -f "$SRC/asr_client.o"

echo "[3/4] .app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/RubaiSTTDictation" "$APP/Contents/MacOS/RubaiSTTDictation"
cp "$SRC/rubai-asr" "$APP/Contents/MacOS/rubai-asr"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>RubaiSTT Dictation</string>
    <key>CFBundleDisplayName</key><string>RubaiSTT Dictation</string>
    <key>CFBundleIdentifier</key><string>com.rubaistt.dictation</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>RubaiSTTDictation</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key><string>Микрофон нужен, чтобы превращать голос в текст.</string>
</dict>
</plist>
PLIST

echo "[4/4] Imzolash..."
xattr -cr "$APP" 2>/dev/null || true
# Barqaror lokal sertifikat bo'lsa — o'sha bilan imzolaymiz. Ad-hoc imzoda har
# qayta build'da cdhash o'zgaradi va macOS Accessibility ruxsatini bekor qiladi;
# bitta sertifikat bilan esa ruxsat saqlanib qoladi.
LOCAL_ID="RubaiSTT Local Signing"
if security find-certificate -c "$LOCAL_ID" >/dev/null 2>&1; then
    echo "  imzo: $LOCAL_ID"
    codesign --force --deep --sign "$LOCAL_ID" --entitlements "$SRC/entitlements.plist" "$APP" 2>/dev/null \
        || codesign --force --deep --sign "$LOCAL_ID" "$APP"
else
    echo "  imzo: ad-hoc"
    codesign --force --deep --sign - --entitlements "$SRC/entitlements.plist" "$APP" 2>/dev/null \
        || codesign --force --deep --sign - "$APP"
fi

echo "Tayyor: $APP"
