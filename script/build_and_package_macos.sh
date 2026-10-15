#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
PROJECT_PATH="$ROOT_DIR/WhisperSpeech.xcodeproj"
SCHEME="WhisperSpeech"
CONFIGURATION="${CONFIGURATION:-Debug}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
DERIVED_DATA_PATH="$ROOT_DIR/.build/derived-data-macos"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Kleio"
BUILT_APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
DIST_APP_PATH="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-macOS.zip"

DO_CLEAN=0

while (( $# > 0 )); do
    case "$1" in
        --clean)
            DO_CLEAN=1
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
    shift
done

mkdir -p "$DIST_DIR"

if (( DO_CLEAN )); then
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        clean build
else
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        build
fi

if [[ ! -d "$BUILT_APP_PATH" ]]; then
    echo "Built app not found at $BUILT_APP_PATH" >&2
    exit 1
fi

rm -rf "$DIST_APP_PATH" "$ZIP_PATH"
ditto "$BUILT_APP_PATH" "$DIST_APP_PATH"
mkdir -p "$DIST_APP_PATH/Contents/Resources/OpenSource"
cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD-PARTY-NOTICES.md" "$DIST_APP_PATH/Contents/Resources/OpenSource/"
# Added notices change the bundle seal; re-sign using the selected local/distribution identity.
if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --preserve-metadata=entitlements,requirements,flags,runtime "$DIST_APP_PATH"
else
    codesign --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp \
        --preserve-metadata=entitlements,requirements,flags,runtime "$DIST_APP_PATH"
fi
ditto -c -k --sequesterRsrc --keepParent "$DIST_APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"

echo "Packaged app: $DIST_APP_PATH"
echo "Packaged zip: $ZIP_PATH"
