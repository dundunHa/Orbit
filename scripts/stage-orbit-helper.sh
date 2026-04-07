#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TAURI_DIR="$ROOT_DIR/src-tauri"
TARGET_TRIPLE="${TAURI_ENV_TARGET_TRIPLE:-$(rustc --print host-tuple)}"
CLI_NAME="orbit-cli"
HELPER_NAME="orbit-helper"
TARGET_ROOT="${CARGO_TARGET_DIR:-$TAURI_DIR/target}"
case "$TARGET_ROOT" in
  /*) ;;
  *) TARGET_ROOT="$TAURI_DIR/$TARGET_ROOT" ;;
esac
HELPER_SRC="$TARGET_ROOT/$TARGET_TRIPLE/release/$CLI_NAME"
HELPER_DST="$TAURI_DIR/binaries/$HELPER_NAME-$TARGET_TRIPLE"

mkdir -p "$TAURI_DIR/binaries"

(
  cd "$TAURI_DIR"
  cargo build --release --target "$TARGET_TRIPLE" --bin "$CLI_NAME"
)

cp "$HELPER_SRC" "$HELPER_DST"
chmod 755 "$HELPER_DST"
