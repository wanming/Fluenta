#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -w "/Applications" ]]; then
  echo "Administrator access is required to replace /Applications/Inklet Local.app."
  sudo -v
fi

echo "Resetting local Inklet state and removing the installed local app..."
"${repo_root}/scripts/reset-local-state.sh" --scope local --remove-installed-app

echo
echo "Building, installing, and opening a fresh local app..."
"${repo_root}/scripts/run-local-app.sh"
