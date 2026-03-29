#!/usr/bin/env bash
set -euo pipefail

# Install repository-managed Git hooks for local signing hygiene.
#
# This command is safe to re-run. It points the local repository config to
# .githooks and ensures hook scripts are executable.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HOOKS_DIR="${ROOT_DIR}/.githooks"

if [[ ! -d "${HOOKS_DIR}" ]]; then
  echo "error: expected hooks directory at ${HOOKS_DIR}" >&2
  exit 1
fi

chmod +x "${HOOKS_DIR}/pre-commit" "${HOOKS_DIR}/pre-push"

git -C "${ROOT_DIR}" config core.hooksPath .githooks

echo "Installed local hooks path: $(git -C "${ROOT_DIR}" config --get core.hooksPath)"
echo "Active hooks:"
ls -1 "${HOOKS_DIR}" | sed 's/^/  - /'
