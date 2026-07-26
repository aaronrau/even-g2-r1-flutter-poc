#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
MODEL_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$MODEL_TMP_DIR"' EXIT HUP INT TERM

WHISPER_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.en.tar.bz2
VAD_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
WHISPER_ARCHIVE="$MODEL_TMP_DIR/whisper.tar.bz2"
WHISPER_DIR="$MODEL_TMP_DIR/sherpa-onnx-whisper-tiny.en"
VAD_FILE="$MODEL_TMP_DIR/silero_vad.onnx"

command -v curl >/dev/null 2>&1 || {
  echo "curl is required" >&2
  exit 1
}
command -v sha256sum >/dev/null 2>&1 || {
  echo "sha256sum is required" >&2
  exit 1
}

curl --fail --location --retry 3 --output "$WHISPER_ARCHIVE" "$WHISPER_URL"
curl --fail --location --retry 3 --output "$VAD_FILE" "$VAD_URL"
tar -xjf "$WHISPER_ARCHIVE" -C "$MODEL_TMP_DIR"

check_hash() {
  expected=$1
  file=$2
  printf '%s  %s\n' "$expected" "$file" | sha256sum --check --status
}

check_hash dc7de696432d97a3d64387800b230ac69d18e5e4efea0eec0613209dd8b7b0c9 \
  "$WHISPER_DIR/tiny.en-encoder.onnx"
check_hash 54d5a5fd2a757175aeb70a837a8404fc9c31b659610724694f5a0e2c51715f94 \
  "$WHISPER_DIR/tiny.en-decoder.onnx"
check_hash 306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930 \
  "$WHISPER_DIR/tiny.en-tokens.txt"
check_hash a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28 \
  "$VAD_FILE"

mkdir -p "$PROJECT_DIR/assets/models/whisper" "$PROJECT_DIR/assets/models/vad"
install -m 0644 "$WHISPER_DIR/tiny.en-encoder.onnx" \
  "$PROJECT_DIR/assets/models/whisper/tiny.en-encoder.onnx"
install -m 0644 "$WHISPER_DIR/tiny.en-decoder.onnx" \
  "$PROJECT_DIR/assets/models/whisper/tiny.en-decoder.onnx"
install -m 0644 "$WHISPER_DIR/tiny.en-tokens.txt" \
  "$PROJECT_DIR/assets/models/whisper/tiny.en-tokens.txt"
install -m 0644 "$VAD_FILE" \
  "$PROJECT_DIR/assets/models/vad/silero_vad.onnx"

echo "Speech models are installed and verified."
