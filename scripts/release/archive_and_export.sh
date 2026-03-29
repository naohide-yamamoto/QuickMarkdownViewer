#!/usr/bin/env bash
set -euo pipefail

# Build a Release archive and export a signed .app bundle.
#
# This script intentionally does not store credentials or team secrets.
# It reads signing context from local Xcode configuration (or TEAM_ID env var),
# so each developer can keep credentials private on their own machine.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PROJECT_PATH="${PROJECT_PATH:-${ROOT_DIR}/QuickMarkdownViewer.xcodeproj}"
SCHEME="${SCHEME:-QuickMarkdownViewer}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${ROOT_DIR}/dist/QuickMarkdownViewer.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-${ROOT_DIR}/dist/export}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install Xcode command line tools first." >&2
  exit 1
fi

if [[ ! -d "${PROJECT_PATH}" ]]; then
  echo "error: project not found at ${PROJECT_PATH}" >&2
  exit 1
fi

# Allow TEAM_ID override, but fall back to the team currently resolved by Xcode.
TEAM_ID="${TEAM_ID:-}"
if [[ -z "${TEAM_ID}" ]]; then
  TEAM_ID="$(xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ DEVELOPMENT_TEAM = / {print $2; exit}')"
fi

if [[ -z "${TEAM_ID}" ]]; then
  echo "error: could not resolve DEVELOPMENT_TEAM." >&2
  echo "hint: set your Team in Xcode Signing & Capabilities, or run with TEAM_ID=..." >&2
  exit 1
fi

# Create export options dynamically so team identifiers are never committed.
TMP_EXPORT_OPTIONS="$(mktemp "${TMPDIR:-/tmp}/qmv-export-options.XXXXXX.plist")"
cleanup() {
  rm -f "${TMP_EXPORT_OPTIONS}"
}
trap cleanup EXIT

cat > "${TMP_EXPORT_OPTIONS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
</dict>
</plist>
PLIST

rm -rf "${ARCHIVE_PATH}" "${EXPORT_PATH}"
mkdir -p "$(dirname "${ARCHIVE_PATH}")" "${EXPORT_PATH}"

echo "==> Archiving ${SCHEME} (${CONFIGURATION})"
if [[ -n "${TEAM_ID}" ]]; then
  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'generic/platform=macOS' \
    -archivePath "${ARCHIVE_PATH}" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    archive
else
  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'generic/platform=macOS' \
    -archivePath "${ARCHIVE_PATH}" \
    archive
fi

echo "==> Exporting signed app bundle"
xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist "${TMP_EXPORT_OPTIONS}" \
  -allowProvisioningUpdates

APP_PATH="$(find "${EXPORT_PATH}" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "${APP_PATH}" ]]; then
  echo "error: export completed but no .app was found in ${EXPORT_PATH}" >&2
  exit 1
fi

echo "==> Export complete"
echo "Archive: ${ARCHIVE_PATH}"
echo "App:     ${APP_PATH}"
