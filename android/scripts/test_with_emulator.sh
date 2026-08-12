#!/usr/bin/env bash
set -euo pipefail

# Reuse the developer's AVD when present; otherwise create a deterministic
# fallback and run the connected instrumentation suite. The AVD is a local
# test tool and is never part of the repository or application package.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
java_major() {
    "${1}/bin/java" -version 2>&1 |
        sed -nE 's/.*version "([0-9]+)(\.[0-9]+)?.*/\1/p' |
        head -n 1
}
java_version=""
if [[ -n "${PAPRIA_JAVA_HOME:-}" ]]; then
    JAVA_HOME="$PAPRIA_JAVA_HOME"
elif [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
    java_version="$(java_major "$JAVA_HOME")"
    if [[ "$java_version" =~ ^[0-9]+$ ]] && (( java_version >= 17 )); then
        :
    else
        echo "A JDK 17 or newer is required. Set PAPRIA_JAVA_HOME or JAVA_HOME." >&2
        exit 1
    fi
else
    echo "Set PAPRIA_JAVA_HOME or JAVA_HOME to a JDK 17 or newer installation." >&2
    exit 1
fi
export JAVA_HOME
ADB="$SDK_ROOT/platform-tools/adb"
EMULATOR="$SDK_ROOT/emulator/emulator"
AVDMANAGER="$SDK_ROOT/cmdline-tools/latest/bin/avdmanager"
SDKMANAGER="$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
AVD_NAME="${PAPRIA_AVD_NAME:-Papria_API33}"
EMULATOR_PORT="${PAPRIA_EMULATOR_PORT:-5554}"
SYSTEM_IMAGE="${PAPRIA_SYSTEM_IMAGE:-system-images;android-33;google_apis_playstore;arm64-v8a}"
EMULATOR_LOG="${PAPRIA_EMULATOR_LOG:-${TMPDIR:-/tmp}/papria-emulator.log}"
ADB_LOG="${PAPRIA_ADB_LOG:-${TMPDIR:-/tmp}/papria-adb.log}"

for tool in "$ADB" "$EMULATOR" "$AVDMANAGER" "$SDKMANAGER"; do
    [[ -x "$tool" ]] || { echo "Missing Android SDK tool: $tool" >&2; exit 1; }
done

if ! "$ADB" start-server >"$ADB_LOG" 2>&1; then
    echo "Android ADB could not start; see $ADB_LOG" >&2
    exit 1
fi

version_greater() {
    local -a left right
    local i left_part right_part
    IFS=. read -r -a left <<< "$1"
    IFS=. read -r -a right <<< "$2"
    for ((i = 0; i < ${#left[@]} || i < ${#right[@]}; i++)); do
        left_part="${left[i]:-0}"
        right_part="${right[i]:-0}"
        if (( 10#$left_part > 10#$right_part )); then
            return 0
        elif (( 10#$left_part < 10#$right_part )); then
            return 1
        fi
    done
    return 1
}

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    selected_ndk=""
    selected_ndk_version=""
    for ndk_root in "$SDK_ROOT/ndk" "$SDK_ROOT/sdk/ndk"; do
        [[ -d "$ndk_root" ]] || continue
        for candidate_ndk in "$ndk_root"/*; do
            [[ -d "$candidate_ndk" ]] || continue
            candidate_version="${candidate_ndk##*/}"
            [[ "$candidate_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
            if [[ -z "$selected_ndk_version" ]] ||
                version_greater "$candidate_version" "$selected_ndk_version"; then
                selected_ndk="$candidate_ndk"
                selected_ndk_version="$candidate_version"
            fi
        done
    done
    [[ -n "$selected_ndk" ]] || {
        echo "No installed Android NDK found under $SDK_ROOT" >&2
        exit 1
    }
    ANDROID_NDK_HOME="$selected_ndk"
fi
export ANDROID_NDK_HOME

if ! "$AVDMANAGER" list avd | grep -q "^    Name: ${AVD_NAME}$"; then
    existing_avd="$("$EMULATOR" -list-avds | sed -n '1p')"
    if [[ -n "$existing_avd" ]]; then
        AVD_NAME="$existing_avd"
    else
        "$SDKMANAGER" "$SYSTEM_IMAGE"
        printf 'no\n' | "$AVDMANAGER" create avd \
            --force \
            --name "$AVD_NAME" \
            --package "$SYSTEM_IMAGE" \
            --device "pixel_2"
    fi
fi

serial="emulator-${EMULATOR_PORT}"
serial_state="$("$ADB" -s "$serial" get-state 2>/dev/null || true)"
if [[ "$serial_state" == "device" ]]; then
    running_avd="$("$ADB" -s "$serial" emu avd name 2>/dev/null | sed -n '1p' | tr -d '\r' || true)"
    if [[ -z "$running_avd" ]]; then
        echo "ADB serial $serial is online, but its AVD name could not be read." >&2
        echo "Choose an unused PAPRIA_EMULATOR_PORT; the existing emulator was not stopped." >&2
        exit 1
    fi
    if [[ "$running_avd" != "$AVD_NAME" ]]; then
        echo "ADB serial $serial is already running AVD '$running_avd', but PAPRIA_AVD_NAME requires '$AVD_NAME'." >&2
        echo "Choose an unused PAPRIA_EMULATOR_PORT or set PAPRIA_AVD_NAME to '$running_avd'; the existing emulator was not stopped." >&2
        exit 1
    fi
elif [[ "$serial_state" == "offline" ]]; then
    echo "ADB serial $serial is offline and cannot be reused safely." >&2
    echo "Wait for it to come online or choose an unused PAPRIA_EMULATOR_PORT; the existing emulator was not stopped." >&2
    exit 1
else
    "$EMULATOR" -avd "$AVD_NAME" -port "$EMULATOR_PORT" -no-snapshot -no-audio -no-boot-anim \
        -gpu swiftshader_indirect >"$EMULATOR_LOG" 2>&1 &
    emulator_pid=$!
    cleanup() {
        if kill -0 "$emulator_pid" >/dev/null 2>&1; then
            kill "$emulator_pid" >/dev/null 2>&1 || true
        fi
    }
    trap cleanup EXIT
fi

for attempt in $(seq 1 120); do
    if "$ADB" -s "$serial" get-state >/dev/null 2>&1; then
        break
    fi
    if [[ "$attempt" -eq 120 ]]; then
        echo "Android emulator did not expose adb; see $EMULATOR_LOG" >&2
        exit 1
    fi
    sleep 2
done
for attempt in $(seq 1 120); do
    booted="$("$ADB" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
    [[ "$booted" == "1" ]] && break
    [[ "$attempt" -eq 120 ]] && {
        echo "Android emulator did not finish booting; see $EMULATOR_LOG" >&2
        exit 1
    }
    sleep 2
done

"$ADB" -s "$serial" shell settings put system screen_off_timeout 1800000
"$ANDROID_DIR/gradlew" --no-daemon -p "$ANDROID_DIR" :app:connectedDebugAndroidTest
