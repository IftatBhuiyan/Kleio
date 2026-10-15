#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="Kleio"
DIST_APP_PATH="$ROOT_DIR/dist/$APP_NAME.app"
PACKAGE_SCRIPT="$ROOT_DIR/script/build_and_package_macos.sh"

REBUILD=0
DO_CLEAN=0

while (( $# > 0 )); do
    case "$1" in
        --rebuild)
            REBUILD=1
            ;;
        --clean)
            REBUILD=1
            DO_CLEAN=1
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
    shift
done

if (( REBUILD )) || [[ ! -d "$DIST_APP_PATH" ]]; then
    if (( DO_CLEAN )); then
        "$PACKAGE_SCRIPT" --clean
    else
        "$PACKAGE_SCRIPT"
    fi
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
open "$DIST_APP_PATH"

echo "Opened $DIST_APP_PATH"
