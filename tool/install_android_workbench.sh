#!/usr/bin/env sh
set -eu

PACKAGE=dev.opensourceglasses.even_g2_r1_poc
DEVICE_SERIAL=
APK=
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

usage() {
  echo "Usage: $0 --device ANDROID_SERIAL [--apk APK]" >&2
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
    --apk)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      APK=$2
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [ -z "$DEVICE_SERIAL" ]; then
  echo "An explicit Android serial is required to prevent installing on the wrong phone." >&2
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

echo "Verifying packaged Parakeet and Gemma Git LFS models."
(
  cd "$REPOSITORY_ROOT/models/stt"
  sha256sum --check SHA256SUMS
)
(
  cd "$REPOSITORY_ROOT/models/llm"
  sha256sum --check SHA256SUMS
)

if [ -z "$APK" ]; then
  (
    cd "$REPOSITORY_ROOT"
    flutter build apk --debug --target-platform android-arm64
  )
  APK=$REPOSITORY_ROOT/build/app/outputs/flutter-apk/app-debug.apk
fi
if [ ! -f "$APK" ]; then
  echo "APK not found: $APK" >&2
  exit 1
fi

echo "Installing Work Bench on the explicitly selected Android device."
adb_target install -r "$APK" >/dev/null
adb_target shell am force-stop "$PACKAGE"

ADB=$ADB_BIN "$SCRIPT_DIR/stage_android_stt_model.sh" \
  --device "$DEVICE_SERIAL" parakeet-0.6b
ADB=$ADB_BIN "$SCRIPT_DIR/stage_android_stt_model.sh" \
  --device "$DEVICE_SERIAL" parakeet-110m
ADB=$ADB_BIN "$SCRIPT_DIR/stage_android_gemma_model.sh" \
  --device "$DEVICE_SERIAL"

adb_target shell am start -W -n "$PACKAGE/.MainActivity" >/dev/null
echo "Work Bench installed with Parakeet 0.6B, Parakeet 110M, and Gemma 4 E4B."
echo "All model files are app-owned; Android root was not used."
