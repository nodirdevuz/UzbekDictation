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
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$ROOT/sherpa-onnx/lib/libsherpa-onnx-c-api.a" ]; then
    echo "sherpa-onnx $VER..."
    curl -fsSL -o "$TMP/lib.tar.bz2" "$REL/$VER/sherpa-onnx-$VER-osx-arm64-static-no-tts-lib.tar.bz2"
    tar xjf "$TMP/lib.tar.bz2" -C "$TMP"
    mkdir -p "$ROOT/sherpa-onnx/include/sherpa-onnx/c-api"
    rm -rf "$ROOT/sherpa-onnx/lib"
    mv "$TMP/sherpa-onnx-$VER-osx-arm64-static-no-tts-lib/lib" "$ROOT/sherpa-onnx/lib"
    curl -fsSL -o "$ROOT/sherpa-onnx/include/sherpa-onnx/c-api/c-api.h" \
        "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$VER/sherpa-onnx/c-api/c-api.h"
fi

if [ ! -f "$MODEL_DIR/model.int8.onnx" ]; then
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
echo "Готово: $ROOT/sherpa-onnx, $MODEL_DIR, $P_DIR"
