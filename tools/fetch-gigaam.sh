#!/bin/bash
# Скачивает движок sherpa-onnx (статические библиотеки + заголовок) в ./sherpa-onnx
# и модель GigaAM v3 (CTC + пунктуация) в ~/rubai-stt/models/gigaam-v3-ctc-punct.
# Запускать один раз перед src/build.sh.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER=v2.0.0
REL=https://github.com/k2-fsa/sherpa-onnx/releases/download
MODEL_NAME=sherpa-onnx-nemo-ctc-punct-giga-am-v3-russian-2025-12-16
MODEL_DIR="$HOME/rubai-stt/models/gigaam-v3-ctc-punct"
# Архитектура: arm64 (Apple Silicon) или x64 (Intel). Можно задать вручную: ARCH=x64 bash tools/fetch-gigaam.sh
if [ -z "$ARCH" ]; then
    case "$(uname -m)" in arm64) ARCH=arm64 ;; *) ARCH=x64 ;; esac
fi
[ "$ARCH" = "x86_64" ] && ARCH=x64
PKG="sherpa-onnx-$VER-osx-$ARCH-static-no-tts-lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Библиотеки другой архитектуры (скопировали папку с другого Mac) — скачиваем заново
if [ -f "$ROOT/sherpa-onnx/.arch" ] && [ "$(cat "$ROOT/sherpa-onnx/.arch")" != "$ARCH" ]; then
    rm -rf "$ROOT/sherpa-onnx/lib"
fi
if [ ! -f "$ROOT/sherpa-onnx/lib/libsherpa-onnx-c-api.a" ]; then
    echo "sherpa-onnx $VER ($ARCH)..."
    curl -fsSL -o "$TMP/lib.tar.bz2" "$REL/$VER/$PKG.tar.bz2"
    tar xjf "$TMP/lib.tar.bz2" -C "$TMP"
    mkdir -p "$ROOT/sherpa-onnx/include/sherpa-onnx/c-api"
    rm -rf "$ROOT/sherpa-onnx/lib"
    mv "$TMP/$PKG/lib" "$ROOT/sherpa-onnx/lib"
    echo "$ARCH" > "$ROOT/sherpa-onnx/.arch"
    curl -fsSL -o "$ROOT/sherpa-onnx/include/sherpa-onnx/c-api/c-api.h" \
        "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$VER/sherpa-onnx/c-api/c-api.h"
fi

# GigaAM (только русский) — запасная модель, по умолчанию не качаем: WITH_GIGAAM=1 bash tools/fetch-gigaam.sh
if [ -n "$WITH_GIGAAM" ] && [ ! -f "$MODEL_DIR/model.int8.onnx" ]; then
    echo "GigaAM v3..."
    curl -fsSL -o "$TMP/m.tar.bz2" "$REL/asr-models/$MODEL_NAME.tar.bz2"
    tar xjf "$TMP/m.tar.bz2" -C "$TMP"
    mkdir -p "$MODEL_DIR"
    cp "$TMP/$MODEL_NAME/model.int8.onnx" "$TMP/$MODEL_NAME/tokens.txt" "$TMP/$MODEL_NAME/LICENSE" "$MODEL_DIR/"
fi
# Основная модель с 25.10.2026 — Parakeet TDT v3 (NVIDIA, русский + английский).
P_NAME=sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8
P_DIR="$HOME/rubai-stt/models/parakeet-v3"
if [ ! -f "$P_DIR/encoder.int8.onnx" ]; then
    echo "Parakeet v3..."
    curl -fsSL -o "$TMP/p.tar.bz2" "$REL/asr-models/$P_NAME.tar.bz2"
    tar xjf "$TMP/p.tar.bz2" -C "$TMP"
    mkdir -p "$P_DIR"
    cp "$TMP/$P_NAME"/{encoder,decoder,joiner}.int8.onnx "$TMP/$P_NAME/tokens.txt" "$P_DIR/"
fi
echo "Готово ($ARCH): $ROOT/sherpa-onnx, $P_DIR"
