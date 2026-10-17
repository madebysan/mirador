#!/bin/bash
set -euo pipefail
ANDROID_SENDER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export JAVA_HOME="${ANDROID_SENDER_JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_SENDER_SDK:-/opt/homebrew/share/android-commandlinetools}"
cd "$ANDROID_SENDER_ROOT"
./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug --no-daemon
