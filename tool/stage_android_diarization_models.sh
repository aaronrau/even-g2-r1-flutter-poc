#!/usr/bin/env sh
set -eu

PACKAGE=dev.opensourceglasses.even_g2_r1_poc
DEVICE_SERIAL=
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_MODEL_ROOT=$SCRIPT_DIR/../models/diarization

usage() {
  echo "Usage: $0 --device ANDROID_SERIAL" >&2
}

if [ "${1:-}" = "--device" ] && [ "$#" -ge 2 ]; then
  DEVICE_SERIAL=$2
  shift 2
fi
if [ "$#" -ne 0 ] || [ -z "$DEVICE_SERIAL" ]; then
  usage
  exit 2
fi

if [ -n "${ADB:-}" ]; then
  ADB_BIN=$ADB
elif [ -n "${ANDROID_HOME:-}" ] &&
  [ -x "$ANDROID_HOME/platform-tools/adb" ]; then
  ADB_BIN=$ANDROID_HOME/platform-tools/adb
elif [ -n "${ANDROID_SDK_ROOT:-}" ] &&
  [ -x "$ANDROID_SDK_ROOT/platform-tools/adb" ]; then
  ADB_BIN=$ANDROID_SDK_ROOT/platform-tools/adb
else
  ADB_BIN=$(command -v adb || true)
fi

if [ -z "$ADB_BIN" ] || [ ! -x "$ADB_BIN" ]; then
  echo "adb is required. Set ADB, ANDROID_HOME, or ANDROID_SDK_ROOT." >&2
  exit 1
fi

adb_target() {
  "$ADB_BIN" -s "$DEVICE_SERIAL" "$@"
}

state=$(adb_target get-state 2>/dev/null || true)
if [ "$state" != "device" ]; then
  echo "The explicitly selected Android device is not connected and authorized." >&2
  exit 1
fi
if ! adb_target shell pm path "$PACKAGE" >/dev/null 2>&1; then
  echo "Install Work Bench before staging diarization models." >&2
  exit 1
fi

SOURCE_DIR=${WORKBENCH_DIARIZATION_MODEL_DIR:-$REPOSITORY_MODEL_ROOT}
MODEL_FILES="segmentation.int8.onnx nemo_en_titanet_small.onnx"

for file in $MODEL_FILES; do
  if [ ! -f "$SOURCE_DIR/$file" ]; then
    echo "Missing diarization model: $file" >&2
    exit 1
  fi
  file_size=$(wc -c <"$SOURCE_DIR/$file")
  if [ "$file_size" -lt 1024 ] &&
    grep -q '^version https://git-lfs.github.com/spec/v1$' \
      "$SOURCE_DIR/$file"; then
    echo "Unresolved Git LFS pointer for $file." >&2
    echo "Run: git lfs pull --include='models/diarization/**'" >&2
    exit 1
  fi
done

(
  cd "$SOURCE_DIR"
  sha256sum --check "$REPOSITORY_MODEL_ROOT/SHA256SUMS"
)

REMOTE_TMP=/data/local/tmp/workbench-diarization-models
adb_target shell mkdir -p "$REMOTE_TMP"
adb_target shell run-as "$PACKAGE" \
  mkdir -p files/workbench/models/diarization
for file in $MODEL_FILES; do
  adb_target push "$SOURCE_DIR/$file" "$REMOTE_TMP/$file" >/dev/null 2>&1
  adb_target shell run-as "$PACKAGE" \
    cp "$REMOTE_TMP/$file" "files/workbench/models/diarization/$file"
  adb_target shell rm -f "$REMOTE_TMP/$file"
done

echo "Diarization models staged in Work Bench app-private storage."
