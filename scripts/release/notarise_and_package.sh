#!/usr/bin/env bash
set -euo pipefail

# Submit the exported app for notarisation, staple the ticket, and prepare
# distributable artefacts (ZIP + SHA256 checksum).
#
# Credentials are intentionally sourced from the local notarytool keychain
# profile so no Apple secrets are committed to the repository.

usage() {
  cat <<'USAGE'
Usage:
  scripts/release/notarise_and_package.sh \
    --app-path <path-to-Quick Markdown Viewer.app> \
    --keychain-profile <notarytool-profile-name> \
    [--output-dir <directory>]
USAGE
}

APP_PATH=""
KEYCHAIN_PROFILE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/dist/release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="$2"
      shift 2
      ;;
    --keychain-profile)
      KEYCHAIN_PROFILE="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${APP_PATH}" || -z "${KEYCHAIN_PROFILE}" ]]; then
  echo "error: --app-path and --keychain-profile are required." >&2
  usage
  exit 1
fi

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app bundle not found at ${APP_PATH}" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found. Install Xcode command line tools first." >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
APP_BASENAME="$(basename "${APP_PATH}" .app)"
# Release asset names are sanitised so public artefact filenames are stable
# and shell-friendly (no spaces).
ASSET_BASENAME="$(printf '%s' "${APP_BASENAME}" | tr -cd '[:alnum:]_-')"
if [[ -z "${ASSET_BASENAME}" ]]; then
  echo "error: could not derive a valid release asset base name from ${APP_BASENAME}" >&2
  exit 1
fi
ZIP_PATH="${OUTPUT_DIR}/${ASSET_BASENAME}-macOS.zip"
SHA256_PATH="${OUTPUT_DIR}/${ASSET_BASENAME}-macOS-SHA256.txt"

echo "==> Creating release ZIP"
rm -f "${ZIP_PATH}" "${SHA256_PATH}"
ditto -c -k --norsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "==> Submitting ZIP for notarisation"
xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${KEYCHAIN_PROFILE}" --wait

echo "==> Stapling notarisation ticket to app"
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

echo "==> Gatekeeper validation"
spctl -a -t exec -vv "${APP_PATH}"

echo "==> Writing SHA256 checksum"
(
  cd "${OUTPUT_DIR}"
  shasum -a 256 "$(basename "${ZIP_PATH}")" > "$(basename "${SHA256_PATH}")"
)

echo "==> Release artefacts ready"
echo "App:      ${APP_PATH}"
echo "ZIP:      ${ZIP_PATH}"
echo "Checksum: ${SHA256_PATH}"
