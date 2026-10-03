#!/bin/bash
# Installs the Flutter SDK and the app's Dart packages so `flutter analyze`,
# `flutter test` and the Python tool tests work in Claude Code cloud sessions.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Pinned so every session analyzes and tests with the same toolchain.
# To upgrade, change this to another tag from https://github.com/flutter/flutter/tags.
FLUTTER_VERSION="3.47.6"
FLUTTER_HOME="/opt/flutter-${FLUTTER_VERSION}"

if [ ! -x "${FLUTTER_HOME}/bin/flutter" ]; then
  echo "Installing Flutter ${FLUTTER_VERSION} into ${FLUTTER_HOME}"
  rm -rf "${FLUTTER_HOME}.tmp"
  git clone --quiet --depth 1 --branch "${FLUTTER_VERSION}" \
    https://github.com/flutter/flutter.git "${FLUTTER_HOME}.tmp"
  mv "${FLUTTER_HOME}.tmp" "${FLUTTER_HOME}"
fi

export PATH="${FLUTTER_HOME}/bin:${PATH}"
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"${FLUTTER_HOME}/bin:\$PATH\"" >> "${CLAUDE_ENV_FILE}"
fi

# The first run downloads the Dart SDK and builds the flutter tool; the
# container is cached afterwards, so later sessions skip this.
flutter --disable-analytics > /dev/null
flutter --version

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}"
flutter pub get
