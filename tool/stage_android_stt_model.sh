#!/usr/bin/env sh
set -eu

PACKAGE=dev.opensourceglasses.even_g2_r1_poc
DEVICE_SERIAL=${ANDROID_SERIAL:-}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_MODEL_ROOT=$SCRIPT_DIR/../models/stt

usage() {
  echo "Usage: $0 [--device ANDROID_SERIAL] {parakeet-110m|parakeet-0.6b}" >&2
}

if [ "${1:-}" = "--device" ]; then
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
    usage
    exit 2
  fi
  DEVICE_SERIAL=$2
  shift 2
fi

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi
MODEL_ID=$1

if [ -n "${ADB:-}" ]; then
  ADB_BIN=$ADB
elif [ -n "${ANDROID_HOME:-}" ] && [ -x "$ANDROID_HOME/platform-tools/adb" ]; then
  ADB_BIN=$ANDROID_HOME/platform-tools/adb
elif [ -x "$HOME/Android/Sdk/platform-tools/adb" ]; then
  ADB_BIN=$HOME/Android/Sdk/platform-tools/adb
else
  ADB_BIN=$(command -v adb || true)
fi

if [ -z "$ADB_BIN" ] || [ ! -x "$ADB_BIN" ]; then
  echo "adb is required" >&2
  exit 1
fi

adb_target() {
  if [ -n "$DEVICE_SERIAL" ]; then
    "$ADB_BIN" -s "$DEVICE_SERIAL" "$@"
  else
    "$ADB_BIN" "$@"
  fi
}

if [ -n "$DEVICE_SERIAL" ]; then
  state=$(adb_target get-state 2>/dev/null || true)
  if [ "$state" != "device" ]; then
    echo "Android device $DEVICE_SERIAL is not connected and authorized." >&2
    exit 1
  fi
else
  devices=$(
    "$ADB_BIN" devices |
      awk 'NR > 1 && $2 == "device" { count++ } END { print count + 0 }'
  )
  if [ "$devices" -ne 1 ]; then
    echo "Expected exactly one connected Android device; found $devices." >&2
    echo "Pass --device ANDROID_SERIAL when more than one is connected." >&2
    exit 1
  fi
fi
if ! adb_target shell pm path "$PACKAGE" >/dev/null 2>&1; then
  echo "Install Work Bench before staging an external model." >&2
  exit 1
fi

case "$MODEL_ID" in
  parakeet-110m)
    MODEL_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8.tar.bz2
    ARCHIVE_DIR_NAME=sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8
    MODEL_FILES="model.int8.onnx tokens.txt"
    ;;
  parakeet-0.6b)
    MODEL_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2
    ARCHIVE_DIR_NAME=sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8
    MODEL_FILES="encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt"
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [ -n "${WORKBENCH_STT_MODEL_DIR:-}" ]; then
  SOURCE_DIR=$WORKBENCH_STT_MODEL_DIR
elif [ -f "$REPOSITORY_MODEL_ROOT/$MODEL_ID/tokens.txt" ]; then
  SOURCE_DIR=$REPOSITORY_MODEL_ROOT/$MODEL_ID
else
  CACHE_BASE=${XDG_CACHE_HOME:-"$HOME/.cache"}
  MODEL_CACHE=$CACHE_BASE/workbench-stt-models
  ARCHIVE=$MODEL_CACHE/$MODEL_ID.tar.bz2
  SOURCE_DIR=$MODEL_CACHE/$ARCHIVE_DIR_NAME
  mkdir -p "$MODEL_CACHE"
  if [ ! -f "$SOURCE_DIR/tokens.txt" ]; then
    command -v curl >/dev/null 2>&1 || {
      echo "curl is required" >&2
      exit 1
    }
    curl --fail --location --retry 5 --retry-all-errors \
      --continue-at - --output "$ARCHIVE" "$MODEL_URL"
    tar -xjf "$ARCHIVE" -C "$MODEL_CACHE"
  fi
fi

expected_hash() {
  case "$1" in
    model.int8.onnx)
      echo 9177a9146cf32ee0cc8152276ef95116f312018d316be37ccf57f7efea81fc1a
      ;;
    encoder.int8.onnx)
      echo acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247
      ;;
    decoder.int8.onnx)
      echo 179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e
      ;;
    joiner.int8.onnx)
      echo 3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3
      ;;
    tokens.txt)
      if [ "$MODEL_ID" = "parakeet-110m" ]; then
        echo 450e56bd2f036fe5b6aa821865838cc5aa9d8b0106134ce9a9ba0664abe6cd10
      else
        echo d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d
      fi
      ;;
  esac
}

for file in $MODEL_FILES; do
  if [ ! -f "$SOURCE_DIR/$file" ]; then
    echo "Missing $MODEL_ID file: $file" >&2
    exit 1
  fi
  file_size=$(wc -c <"$SOURCE_DIR/$file")
  if [ "$file_size" -lt 1024 ] &&
    grep -q '^version https://git-lfs.github.com/spec/v1$' \
      "$SOURCE_DIR/$file"; then
    echo "$MODEL_ID has an unresolved Git LFS pointer for $file." >&2
    echo "Run: git lfs pull --include='models/stt/**'" >&2
    exit 1
  fi
  printf '%s  %s\n' "$(expected_hash "$file")" "$SOURCE_DIR/$file" |
    sha256sum --check --status
done

REMOTE_TMP=/data/local/tmp/workbench-"$MODEL_ID"
adb_target shell mkdir -p "$REMOTE_TMP"
adb_target shell run-as "$PACKAGE" \
  mkdir -p "files/workbench/models/$MODEL_ID"
for file in $MODEL_FILES; do
  adb_target push "$SOURCE_DIR/$file" "$REMOTE_TMP/$file" >/dev/null
  adb_target shell run-as "$PACKAGE" \
    cp "$REMOTE_TMP/$file" "files/workbench/models/$MODEL_ID/$file"
  adb_target shell rm -f "$REMOTE_TMP/$file"
done

echo "$MODEL_ID staged in Work Bench app-private storage."
