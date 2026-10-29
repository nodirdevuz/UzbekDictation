#!/bin/bash
# RubaiSTT Dictation — установка одной командой на любой Mac (Apple Silicon или Intel), macOS 13+.
#   git clone https://github.com/nodirdevuz/UzbekDictation ~/UzbekDictation && bash ~/UzbekDictation/setup.sh
# Шаги: Command Line Tools → движок sherpa-onnx + модель Parakeet v3 (~640 МБ) → сертификат подписи →
# сборка → установка в /Applications, автозапуск, сторож. В конце открывает нужные разрешения.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
echo "==> RubaiSTT Dictation: установка ($(uname -m), macOS $(sw_vers -productVersion))"

MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MAJOR" -lt 13 ]; then
    echo "Нужна macOS 13 Ventura или новее (сейчас $(sw_vers -productVersion))." >&2; exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
    echo "Нужны Xcode Command Line Tools. Сейчас откроется окно установки — нажмите «Установить»,"
    echo "дождитесь конца и запустите setup.sh ещё раз."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

echo "==> [1/4] Движок и модель"
bash "$ROOT/tools/fetch-gigaam.sh"

echo "==> [2/4] Сертификат подписи"
bash "$ROOT/tools/make-signing-cert.sh"

echo "==> [3/4] Сборка"
bash "$ROOT/src/build.sh"

echo "==> [4/4] Установка"
bash "$ROOT/src/install.sh"

cat <<'TXT'

✅ Установлено. В меню-баре появилась иконка 🎙️.

ПОСЛЕДНИЙ ШАГ — разрешения (окно откроется само), включить «RubaiSTT Dictation»:
  1. Конфиденциальность → Универсальный доступ (Accessibility) — слышать ⌘⌘ и вставлять текст
  2. Конфиденциальность → Микрофон — macOS спросит сама при первой диктовке, нажать «Разрешить»
  Если ⌘⌘ всё равно не срабатывает — включить ещё «Мониторинг ввода» (Input Monitoring).
После включения: выйти из приложения через меню 🎙️ и открыть снова (или перезагрузить Mac).

Как пользоваться: ⌘⌘ (дважды Command) — говорить, ⌘ один раз — текст вставится. Esc — отмена.
TXT
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
