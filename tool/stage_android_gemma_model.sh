#!/usr/bin/env sh
set -eu

PACKAGE=dev.opensourceglasses.even_g2_r1_poc
MODEL_ID=gemma-4-e4b-it
MODEL_FILE=gemma-4-E4B-it.litertlm
MODEL_BYTES=3659530240
MODEL_SHA256=0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0
DEVICE_SERIAL=${ANDROID_SERIAL:-}
SOURCE_FILE=${WORKBENCH_GEMMA_MODEL_FILE:-}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_MODEL_DIR=$SCRIPT_DIR/../models/llm/$MODEL_ID

usage() {
  echo "Usage: $0 [--device ANDROID_SERIAL] [--model-file FILE]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --device)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      DEVICE_SERIAL=$2
      shift 2
      ;;
    --model-file)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      SOURCE_FILE=$2
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

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
  if [ -n "$DEVICE_SERIAL" ]; then
    "$ADB_BIN" -s "$DEVICE_SERIAL" "$@"
  else
    "$ADB_BIN" "$@"
  fi
}

if [ -n "$DEVICE_SERIAL" ]; then
  state=$(adb_target get-state 2>/dev/null || true)
  if [ "$state" != "device" ]; then
    echo "The selected Android device is not connected and authorized." >&2
    exit 1
  fi
else
  devices=$(
    "$ADB_BIN" devices |
      awk 'NR > 1 && $2 == "device" { count++ } END { print count + 0 }'
  )
  if [ "$devices" -ne 1 ]; then
    echo "Expected exactly one authorized Android device; found $devices." >&2
    echo "Pass --device <android-serial> when more than one is connected." >&2
    exit 1
  fi
fi

if ! adb_target shell pm path "$PACKAGE" >/dev/null 2>&1; then
  echo "Install the Work Bench debug app before staging Gemma." >&2
  exit 1
fi

SOURCE_MODE=file
if [ -z "$SOURCE_FILE" ]; then
  SOURCE_MODE=parts
  set -- "$REPOSITORY_MODEL_DIR/$MODEL_FILE".part-*
  if [ "$#" -ne 4 ] || [ ! -f "$1" ]; then
    echo "Gemma Git LFS chunks are missing." >&2
    echo "Run: git lfs pull --include='models/llm/**'" >&2
    exit 1
  fi
  source_bytes=0
  for part in "$@"; do
    part_size=$(wc -c <"$part")
    if [ "$part_size" -lt 1024 ] &&
      grep -q '^version https://git-lfs.github.com/spec/v1$' "$part"; then
      echo "Gemma has an unresolved Git LFS pointer: ${part##*/}" >&2
      echo "Run: git lfs pull --include='models/llm/**'" >&2
      exit 1
    fi
    source_bytes=$((source_bytes + part_size))
  done
  if [ "$source_bytes" -ne "$MODEL_BYTES" ]; then
    echo "Combined Gemma chunk length does not match the pinned release." >&2
    exit 1
  fi
elif [ ! -f "$SOURCE_FILE" ]; then
  echo "Gemma model file not found." >&2
  exit 1
elif [ "$(wc -c <"$SOURCE_FILE")" -ne "$MODEL_BYTES" ]; then
  echo "Gemma model byte length does not match the pinned release." >&2
  exit 1
fi

stream_source() {
  if [ "$SOURCE_MODE" = "file" ]; then
    cat "$SOURCE_FILE"
    return
  fi
  for part in "$@"; do
    cat "$part"
  done
}

source_hash=$(stream_source "$@" | sha256sum | awk '{print $1}')
if [ "$source_hash" != "$MODEL_SHA256" ]; then
  echo "Gemma model SHA-256 validation failed." >&2
  exit 1
fi

available_kb=$(
  adb_target shell df -k /data 2>/dev/null |
    awk 'NR > 1 { value=$4 } END { gsub(/[^0-9]/, "", value); print value + 0 }'
)
required_kb=5000000
if [ "$available_kb" -lt "$required_kb" ]; then
  echo "At least 5 GB of free device storage is required." >&2
  exit 1
fi

REMOTE_DIR=files/workbench/models/$MODEL_ID
REMOTE_MODEL=$REMOTE_DIR/$MODEL_FILE
REMOTE_PART=$REMOTE_MODEL.part
adb_target shell run-as "$PACKAGE" mkdir -p "$REMOTE_DIR"
adb_target shell run-as "$PACKAGE" rm -f "$REMOTE_PART"

if [ "$SOURCE_MODE" = "parts" ]; then
  adb_target shell run-as "$PACKAGE" touch "$REMOTE_PART"
  REMOTE_CHUNK=
  cleanup_chunk() {
    if [ -n "$REMOTE_CHUNK" ]; then
      adb_target shell rm -f "$REMOTE_CHUNK" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_chunk EXIT HUP INT TERM
  copied_bytes=0
  chunk_index=0
  for part in "$@"; do
    REMOTE_CHUNK=/data/local/tmp/workbench-gemma-"$chunk_index".part
    adb_target push "$part" "$REMOTE_CHUNK" >/dev/null 2>&1
    adb_target shell \
      "run-as $PACKAGE sh -c \"cat '$REMOTE_CHUNK' >> '$REMOTE_PART'\""
    adb_target shell rm -f "$REMOTE_CHUNK"
    REMOTE_CHUNK=
    part_size=$(wc -c <"$part")
    copied_bytes=$((copied_bytes + part_size))
    echo "Gemma copy: $copied_bytes of $MODEL_BYTES bytes."
    chunk_index=$((chunk_index + 1))
  done
  trap - EXIT HUP INT TERM
else
  stream_source "$@" |
    adb_target shell \
      "run-as $PACKAGE sh -c \"cat > '$REMOTE_PART'\""
fi

device_hash=$(
  adb_target shell run-as "$PACKAGE" sha256sum "$REMOTE_PART" |
    awk '{print $1}'
)
if [ "$device_hash" != "$MODEL_SHA256" ]; then
  adb_target shell run-as "$PACKAGE" rm -f "$REMOTE_PART"
  echo "The copied Gemma model failed device-side SHA-256 validation." >&2
  exit 1
fi

adb_target shell \
  "run-as $PACKAGE sh -c \"mv '$REMOTE_PART' '$REMOTE_MODEL' && printf '%s\\n' '$MODEL_SHA256' > '$REMOTE_MODEL.verified'\""

echo "Gemma 4 E4B staged and verified in Work Bench app-private storage."
