#!/usr/bin/env bash
set -euo pipefail

# End-to-end helper for local signed release generation.
#
# This script intentionally leaves sensitive setup out of the repository:
# - Apple Developer Team selection stays in local Xcode settings
# - notarytool credentials stay in local keychain profiles

usage() {
  cat <<'USAGE'
Usage:
  scripts/release/make_signed_release.sh --keychain-profile <notarytool-profile-name> [--team-id <TEAM_ID>]

Environment:
  TEAM_ID=<TEAM_ID> may be used instead of --team-id.
USAGE
}

KEYCHAIN_PROFILE=""
TEAM_ID="${TEAM_ID:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keychain-profile)
      KEYCHAIN_PROFILE="$2"
      shift 2
      ;;
    --team-id)
      TEAM_ID="$2"
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

if [[ -z "${KEYCHAIN_PROFILE}" ]]; then
  echo "error: --keychain-profile is required." >&2
  usage
  exit 1
fi

ARCHIVE_SCRIPT="${SCRIPT_DIR}/archive_and_export.sh"
NOTARISE_SCRIPT="${SCRIPT_DIR}/notarise_and_package.sh"

if [[ ! -x "${ARCHIVE_SCRIPT}" || ! -x "${NOTARISE_SCRIPT}" ]]; then
  echo "error: expected executable scripts in ${SCRIPT_DIR}" >&2
  exit 1
fi

if [[ -n "${TEAM_ID}" ]]; then
  TEAM_ID="${TEAM_ID}" "${ARCHIVE_SCRIPT}"
else
  "${ARCHIVE_SCRIPT}"
fi

APP_PATH="$(find "${ROOT_DIR}/dist/export" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "${APP_PATH}" ]]; then
  echo "error: could not locate exported .app in ${ROOT_DIR}/dist/export" >&2
  exit 1
fi

"${NOTARISE_SCRIPT}" \
  --app-path "${APP_PATH}" \
  --keychain-profile "${KEYCHAIN_PROFILE}"
