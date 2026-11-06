#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="${TMPDIR:-/private/tmp}/stay-relevant-macos"
mkdir -p "$RUN_DIR"
cp -RX "$ROOT/lib" "$ROOT/macos" "$ROOT/pubspec.yaml" \
  "$ROOT/pubspec.lock" "$ROOT/.metadata" "$ROOT/analysis_options.yaml" "$RUN_DIR/"
cd "$RUN_DIR"
flutter pub get
flutter run -d macos
