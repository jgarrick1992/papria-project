#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
SDK_ROOT=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}

# Android Gradle Plugin 8 requires a modern JDK. Keep the unit-test entrypoint
# reproducible when the interactive shell still points at an older Java.
java_major=0
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    java_major=$("$JAVA_HOME/bin/java" -version 2>&1 | sed -nE 's/.*version "([0-9]+)(\.[0-9]+)?.*/\1/p' | head -n 1)
fi
case "$java_major" in
    ''|*[!0-9]*|[0-9]|1[0-6])
        echo "A JDK 17 or newer is required. Set JAVA_HOME to its installation." >&2
        exit 1
        ;;
esac

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    for candidate in "$SDK_ROOT"/ndk/*; do
        if [ -d "$candidate" ]; then
            ANDROID_NDK_HOME="$candidate"
        fi
    done
    export ANDROID_NDK_HOME
fi

exec "$PROJECT_DIR/gradlew" -p "$PROJECT_DIR" :app:testDebugUnitTest "$@"
