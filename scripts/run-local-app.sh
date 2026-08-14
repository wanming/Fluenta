#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="Inklet Local"
bundle_id="com.tomwan.inklet.local"
output_dir="${repo_root}/dist/local"
app_path="${output_dir}/${app_name}.app"
install_path="/Applications/${app_name}.app"
dry_run=0
allow_adhoc=0

usage() {
  cat <<'EOF'
Usage: scripts/run-local-app.sh [--dry-run] [--allow-adhoc]

Build, install, and open /Applications/Inklet Local.app with a stable signing
identity so macOS Accessibility permission is preserved across local runs.

Signing identity resolution:
  1. INKLET_LOCAL_SIGN_IDENTITY
  2. INKLET_SIGN_IDENTITY
  3. First local code signing identity hash from the keychain

Options:
  --dry-run      Print the workflow without building or installing.
  --allow-adhoc  Allow ad-hoc signing when no signing identity exists.
  -h, --help     Show this help.
EOF
}

run() {
  local display="$1"
  shift
  echo "+ ${display}"
  if [[ "$dry_run" == "0" ]]; then
    "$@"
  fi
}

detect_sign_identity() {
  security find-identity -v -p codesigning 2>/dev/null |
    awk '/^[[:space:]]*[0-9]+\)/ && $2 ~ /^[A-Fa-f0-9]{40}$/ { print $2; exit }'
}

wait_for_process_exit() {
  local process_name="$1"
  local attempt

  for attempt in {1..50}; do
    if ! pgrep -x "$process_name" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  pkill -9 -x "$process_name" >/dev/null 2>&1 || true
  for attempt in {1..20}; do
    if ! pgrep -x "$process_name" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  echo "Could not stop existing ${process_name} process." >&2
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
      ;;
    --allow-adhoc)
      allow_adhoc=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -f "${repo_root}/.env.local" ]]; then
  # shellcheck disable=SC1091
  source "${repo_root}/.env.local"
fi

sign_identity="${INKLET_LOCAL_SIGN_IDENTITY:-${INKLET_SIGN_IDENTITY:-}}"
if [[ -z "$sign_identity" ]]; then
  sign_identity="$(detect_sign_identity || true)"
fi

if [[ -z "$sign_identity" ]]; then
  if [[ "$allow_adhoc" == "1" ]]; then
    sign_identity="-"
  else
    cat >&2 <<'EOF'
No local code signing identity was found.

Set INKLET_LOCAL_SIGN_IDENTITY in .env.local, or install a local code signing
certificate. Ad-hoc signing is refused by default because it can make macOS ask
for Accessibility permission again after every rebuild.
EOF
    exit 1
  fi
fi

if [[ "$sign_identity" == "-" && "$allow_adhoc" != "1" ]]; then
  cat >&2 <<'EOF'
Refusing ad-hoc signing for local runs.

Use a stable signing identity for /Applications/Inklet Local.app so macOS keeps
the Accessibility permission across rebuilds.
EOF
  exit 1
fi

run "env INKLET_APP_NAME=${app_name} INKLET_BUNDLE_ID=${bundle_id} INKLET_OUTPUT_DIR=${output_dir} INKLET_SIGN_IDENTITY=<hidden> scripts/build-macos-app-bundle.sh" \
  env \
  INKLET_APP_NAME="$app_name" \
  INKLET_BUNDLE_ID="$bundle_id" \
  INKLET_OUTPUT_DIR="$output_dir" \
  INKLET_SIGN_IDENTITY="$sign_identity" \
  "${repo_root}/scripts/build-macos-app-bundle.sh"

run "${repo_root}/scripts/verify-direct-app.sh ${app_path} ${bundle_id}" \
  "${repo_root}/scripts/verify-direct-app.sh" "$app_path" "$bundle_id"

run "osascript -e 'tell application \"${app_name}\" to quit'" \
  osascript -e "tell application \"${app_name}\" to quit" >/dev/null 2>&1 || true
run "pkill -x '${app_name}'" \
  pkill -x "$app_name" >/dev/null 2>&1 || true
run "pgrep -x '${app_name}' until no process remains" \
  wait_for_process_exit "$app_name"

if [[ -w "/Applications" ]]; then
  run "rm -rf ${install_path}" rm -rf "$install_path"
  run "ditto ${app_path} ${install_path}" ditto "$app_path" "$install_path"
else
  run "sudo rm -rf ${install_path}" sudo rm -rf "$install_path"
  run "sudo ditto ${app_path} ${install_path}" sudo ditto "$app_path" "$install_path"
fi

run "${repo_root}/scripts/verify-direct-app.sh ${install_path} ${bundle_id}" \
  "${repo_root}/scripts/verify-direct-app.sh" "$install_path" "$bundle_id"

run "open -n ${install_path}" open -n "$install_path"
