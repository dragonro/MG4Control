#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="com.mg4.control.emulator"
ACTIVITY_NAME="com.mg4.control.MainActivity"
APK_PATH="$ROOT_DIR/app/build/outputs/apk/emulator/debug/app-emulator-debug.apk"
MG4_EMULATOR_SIZE="${MG4_EMULATOR_SIZE:-1280x480}"
MG4_EMULATOR_DENSITY="${MG4_EMULATOR_DENSITY:-160}"

if [[ -z "${ANDROID_HOME:-}" && -d "$HOME/Library/Android/sdk" ]]; then
  export ANDROID_HOME="$HOME/Library/Android/sdk"
fi

find_tool() {
  local tool="$1"

  if command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
    return
  fi

  if [[ -n "${ANDROID_HOME:-}" && -x "$ANDROID_HOME/emulator/$tool" ]]; then
    echo "$ANDROID_HOME/emulator/$tool"
    return
  fi

  if [[ -n "${ANDROID_HOME:-}" && -x "$ANDROID_HOME/platform-tools/$tool" ]]; then
    echo "$ANDROID_HOME/platform-tools/$tool"
    return
  fi

  if [[ -n "${ANDROID_SDK_ROOT:-}" && -x "$ANDROID_SDK_ROOT/emulator/$tool" ]]; then
    echo "$ANDROID_SDK_ROOT/emulator/$tool"
    return
  fi

  if [[ -n "${ANDROID_SDK_ROOT:-}" && -x "$ANDROID_SDK_ROOT/platform-tools/$tool" ]]; then
    echo "$ANDROID_SDK_ROOT/platform-tools/$tool"
    return
  fi

  if [[ -x "$HOME/Library/Android/sdk/emulator/$tool" ]]; then
    echo "$HOME/Library/Android/sdk/emulator/$tool"
    return
  fi

  if [[ -x "$HOME/Library/Android/sdk/platform-tools/$tool" ]]; then
    echo "$HOME/Library/Android/sdk/platform-tools/$tool"
    return
  fi

  if [[ -n "${ANDROID_HOME:-}" && -x "$ANDROID_HOME/cmdline-tools/latest/bin/$tool" ]]; then
    echo "$ANDROID_HOME/cmdline-tools/latest/bin/$tool"
    return
  fi

  if [[ -n "${ANDROID_SDK_ROOT:-}" && -x "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/$tool" ]]; then
    echo "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/$tool"
    return
  fi

  if [[ -x "$HOME/Library/Android/sdk/cmdline-tools/latest/bin/$tool" ]]; then
    echo "$HOME/Library/Android/sdk/cmdline-tools/latest/bin/$tool"
    return
  fi

  return 1
}

ADB="$(find_tool adb || true)"
EMULATOR="$(find_tool emulator || true)"
SDKMANAGER="$(find_tool sdkmanager || true)"

if [[ -z "$ADB" ]]; then
  echo "adb not found. Add Android SDK platform-tools to PATH or set ANDROID_HOME." >&2
  exit 1
fi

cd "$ROOT_DIR"

first_emulator_serial() {
  "$ADB" devices | awk 'NR > 1 && $1 ~ /^emulator-/ && $2 == "device" { print $1; exit }'
}

wait_for_boot() {
  local boot_completed=""
  for _ in {1..180}; do
    boot_completed="$("$ADB" -s "$EMULATOR_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    [[ "$boot_completed" == "1" ]] && return 0
    sleep 1
  done

  echo "Timed out waiting for Android to finish booting on $EMULATOR_SERIAL." >&2
  "$ADB" -s "$EMULATOR_SERIAL" emu kill >/dev/null 2>&1 || true
  exit 1
}

configure_mg4_display() {
  echo "Configuring MG4 infotainment display: ${MG4_EMULATOR_SIZE}, density ${MG4_EMULATOR_DENSITY}"
  "$ADB" -s "$EMULATOR_SERIAL" shell wm size "$MG4_EMULATOR_SIZE"
  "$ADB" -s "$EMULATOR_SERIAL" shell wm density "$MG4_EMULATOR_DENSITY"
  "$ADB" -s "$EMULATOR_SERIAL" shell settings put system accelerometer_rotation 0 || true
  "$ADB" -s "$EMULATOR_SERIAL" shell settings put system user_rotation 1 || true
}

avd_system_dir() {
  local avd_name="$1"
  local config="$HOME/.android/avd/${avd_name}.avd/config.ini"
  local image_dir=""

  [[ -f "$config" ]] || return 1
  image_dir="$(awk -F= '$1 == "image.sysdir.1" { print $2; exit }' "$config")"
  [[ -n "$image_dir" ]] || return 1

  if [[ "$image_dir" = /* ]]; then
    echo "$image_dir"
  else
    echo "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}/$image_dir"
  fi
}

validate_avd_system_image() {
  local avd_name="$1"
  local system_dir=""

  system_dir="$(avd_system_dir "$avd_name" || true)"
  if [[ -z "$system_dir" || ! -d "$system_dir" ]]; then
    echo "AVD '$avd_name' has no valid system image directory." >&2
    exit 1
  fi

  if ! find "$system_dir" -maxdepth 2 -type f \( -name 'system.img' -o -name 'super.img' \) | grep -q .; then
    echo "AVD '$avd_name' points to an incomplete Android system image:" >&2
    echo "  $system_dir" >&2
    echo "The emulator will fail with: No initial system image for this configuration." >&2
    if [[ -n "$SDKMANAGER" ]]; then
      echo "Repair it with:" >&2
      echo "  \"$SDKMANAGER\" --uninstall \"system-images;android-36;google_apis;arm64-v8a\"" >&2
      echo "  \"$SDKMANAGER\" --install \"system-images;android-36;google_apis;arm64-v8a\"" >&2
    fi
    exit 1
  fi
}

EMULATOR_SERIAL="$(first_emulator_serial)"

if [[ -z "$EMULATOR_SERIAL" ]]; then
  if [[ -z "$EMULATOR" ]]; then
    echo "No running emulator found, and emulator binary is unavailable." >&2
    exit 1
  fi

  AVD_NAME="${1:-}"
  if [[ -z "$AVD_NAME" ]]; then
    AVD_NAME="$("$EMULATOR" -list-avds | head -n 1)"
  fi

  if [[ -z "$AVD_NAME" ]]; then
    echo "No Android Virtual Device found. Create one in Android Studio first." >&2
    exit 1
  fi

  validate_avd_system_image "$AVD_NAME"

  echo "Starting emulator: $AVD_NAME at MG4 infotainment resolution ${MG4_EMULATOR_SIZE}"
  : > /tmp/mg4control-emulator.log
  nohup "$EMULATOR" -avd "$AVD_NAME" -no-snapshot-load >/tmp/mg4control-emulator.log 2>&1 &
  EMULATOR_PID=$!

  for _ in {1..120}; do
    if ! kill -0 "$EMULATOR_PID" 2>/dev/null; then
      echo "Emulator process exited before registering with adb." >&2
      tail -80 /tmp/mg4control-emulator.log >&2 || true
      exit 1
    fi
    EMULATOR_SERIAL="$(first_emulator_serial)"
    [[ -n "$EMULATOR_SERIAL" ]] && break
    sleep 1
  done

  if [[ -z "$EMULATOR_SERIAL" ]]; then
    echo "Timed out waiting for emulator. See /tmp/mg4control-emulator.log." >&2
    tail -80 /tmp/mg4control-emulator.log >&2 || true
    exit 1
  fi
fi

echo "Using emulator: $EMULATOR_SERIAL"
wait_for_boot
configure_mg4_display

echo "Building emulatorDebug APK"
./gradlew :app:assembleEmulatorDebug

echo "Installing $APK_PATH"
"$ADB" -s "$EMULATOR_SERIAL" install -r "$APK_PATH"

echo "Launching $PACKAGE_NAME"
"$ADB" -s "$EMULATOR_SERIAL" shell am start -n "$PACKAGE_NAME/$ACTIVITY_NAME"

echo "Streaming app logs. Press Ctrl+C to stop."
"$ADB" -s "$EMULATOR_SERIAL" logcat -v time | grep --line-buffered -E "MG4_|AndroidRuntime|$PACKAGE_NAME"
