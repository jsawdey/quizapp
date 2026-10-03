#!/bin/bash
# Installs the Flutter SDK, the Android SDK and the app's Dart packages so
# `flutter analyze`, `flutter test`, `flutter build apk` and the Python tool
# tests work in Claude Code cloud sessions.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Pinned so every session analyzes, tests and builds with the same toolchain.
# To upgrade, change this to another tag from https://github.com/flutter/flutter/tags.
FLUTTER_VERSION="3.47.6"
FLUTTER_HOME="/opt/flutter-${FLUTTER_VERSION}"

# Android command-line tools 23.0 and the SDK packages Flutter 3.47 builds with
# (see compileSdkVersion and ndkVersion in the Flutter Gradle plugin's
# FlutterExtension.kt). Requires dl.google.com in the network allowlist.
ANDROID_HOME="/opt/android-sdk"
ANDROID_CMDLINE_TOOLS_ZIP="commandlinetools-linux-16111833_latest.zip"
ANDROID_CMDLINE_TOOLS_SHA1="e025545c62a8e64c7559119566a569fb1dec5f60"
ANDROID_PACKAGES=(
  "platform-tools"
  "platforms;android-36"
  "build-tools;36.0.0"
  "ndk;28.2.13676358"
)

persist_env() {
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    echo "$1" >> "${CLAUDE_ENV_FILE}"
  fi
}

# --- Flutter -----------------------------------------------------------------

if [ ! -x "${FLUTTER_HOME}/bin/flutter" ]; then
  echo "Installing Flutter ${FLUTTER_VERSION} into ${FLUTTER_HOME}"
  rm -rf "${FLUTTER_HOME}.tmp"
  git clone --quiet --depth 1 --branch "${FLUTTER_VERSION}" \
    https://github.com/flutter/flutter.git "${FLUTTER_HOME}.tmp"
  mv "${FLUTTER_HOME}.tmp" "${FLUTTER_HOME}"
fi

export PATH="${FLUTTER_HOME}/bin:${PATH}"
persist_env "export PATH=\"${FLUTTER_HOME}/bin:\$PATH\""

# The first run downloads the Dart SDK and builds the flutter tool; the
# container is cached afterwards, so later sessions skip this.
flutter --disable-analytics > /dev/null
flutter --version

# --- Android SDK -------------------------------------------------------------

SDKMANAGER="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"
if [ ! -x "${SDKMANAGER}" ]; then
  echo "Installing Android command-line tools into ${ANDROID_HOME}"
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/tools.zip" \
    "https://dl.google.com/android/repository/${ANDROID_CMDLINE_TOOLS_ZIP}"
  echo "${ANDROID_CMDLINE_TOOLS_SHA1}  ${tmp}/tools.zip" | sha1sum --check --quiet
  unzip -q "${tmp}/tools.zip" -d "${tmp}"
  mkdir -p "${ANDROID_HOME}/cmdline-tools"
  rm -rf "${ANDROID_HOME}/cmdline-tools/latest"
  mv "${tmp}/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest"
  rm -rf "${tmp}"
fi

export ANDROID_HOME ANDROID_SDK_ROOT="${ANDROID_HOME}"
export PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"
persist_env "export ANDROID_HOME=\"${ANDROID_HOME}\""
persist_env "export ANDROID_SDK_ROOT=\"${ANDROID_HOME}\""
persist_env "export PATH=\"${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:\$PATH\""

# Only call sdkmanager when a package is missing: it fetches the package
# index on every run, which would slow down every session start.
missing=()
for package in "${ANDROID_PACKAGES[@]}"; do
  if [ ! -f "${ANDROID_HOME}/${package//;//}/package.xml" ]; then
    missing+=("${package}")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Installing Android SDK packages: ${missing[*]}"
  yes | "${SDKMANAGER}" --licenses > /dev/null || true
  "${SDKMANAGER}" --install "${missing[@]}" > /dev/null
fi

flutter config --android-sdk "${ANDROID_HOME}" > /dev/null

# --- Dart packages -----------------------------------------------------------

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}"
flutter pub get
