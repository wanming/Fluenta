#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
app_name="Inklet Local"
bundle_id="com.tomwan.inklet.local"
app_path="${repo_root}/dist/local/${app_name}.app"
install_path="/Applications/${app_name}.app"

# shellcheck disable=SC1091
source "${repo_root}/VERSION"

dry_run_output="$(INKLET_SIGN_IDENTITY="LOCAL_TEST_IDENTITY" "${script_dir}/run-local-app.sh" --dry-run)"
fake_bin="$(mktemp -d)"
trap 'rm -rf "$fake_bin"' EXIT

cat >"${fake_bin}/security" <<'EOF'
#!/usr/bin/env bash
echo '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Local Test Signing"'
EOF
chmod +x "${fake_bin}/security"

auto_detect_output="$(
  env \
    -u INKLET_SIGN_IDENTITY \
    -u INKLET_LOCAL_SIGN_IDENTITY \
    PATH="${fake_bin}:$PATH" \
    "${script_dir}/run-local-app.sh" --dry-run
)"

if ! grep -q 'INKLET_APP_NAME=Inklet Local' <<<"$dry_run_output"; then
  echo "run-local-app.sh must build the local app name." >&2
  exit 1
fi

if ! grep -q "INKLET_BUNDLE_ID=${bundle_id}" <<<"$dry_run_output"; then
  echo "run-local-app.sh must build the local bundle identifier." >&2
  exit 1
fi

if ! grep -q "INKLET_OUTPUT_DIR=${repo_root}/dist/local" <<<"$dry_run_output"; then
  echo "run-local-app.sh must use the local output directory." >&2
  exit 1
fi

if ! grep -q "INKLET_VERSION=${INKLET_VERSION}" <<<"$dry_run_output"; then
  echo "run-local-app.sh must build the version declared in VERSION." >&2
  exit 1
fi

if ! grep -q "INKLET_BUILD_NUMBER=${INKLET_BUILD_NUMBER}" <<<"$dry_run_output"; then
  echo "run-local-app.sh must build the build number declared in VERSION." >&2
  exit 1
fi

if [[ "$(grep -Fc 'verify-direct-app.sh' <<<"$dry_run_output" || true)" != "2" ]]; then
  echo "run-local-app.sh must verify both built and installed app bundles." >&2
  exit 1
fi

if ! grep -Fq "verify-direct-app.sh ${app_path} ${bundle_id}" <<<"$dry_run_output"; then
  echo "run-local-app.sh must verify the built local app." >&2
  exit 1
fi

if ! grep -Fq "verify-direct-app.sh ${install_path} ${bundle_id}" <<<"$dry_run_output"; then
  echo "run-local-app.sh must verify the installed local app." >&2
  exit 1
fi

install_line="$(grep -nF "ditto ${app_path} ${install_path}" <<<"$dry_run_output" | tail -n 1 | cut -d: -f1)"
installed_verifier_line="$(grep -nF "verify-direct-app.sh ${install_path} ${bundle_id}" <<<"$dry_run_output" | cut -d: -f1)"
open_line="$(grep -nF "open -n ${install_path}" <<<"$dry_run_output" | cut -d: -f1)"
if [[ -z "$install_line" || -z "$installed_verifier_line" || -z "$open_line" ||
  "$install_line" -ge "$installed_verifier_line" || "$installed_verifier_line" -ge "$open_line" ]]; then
  echo "run-local-app.sh must verify the installed app after copying and before opening." >&2
  exit 1
fi

if grep -q 'LOCAL_TEST_IDENTITY' <<<"$dry_run_output"; then
  echo "run-local-app.sh must not print signing identities." >&2
  exit 1
fi

if ! grep -q 'INKLET_SIGN_IDENTITY=<hidden>' <<<"$auto_detect_output"; then
  echo "run-local-app.sh must auto-detect a stable local signing identity." >&2
  exit 1
fi

if grep -Eq '[A-F]{40}|Local Test Signing' <<<"$auto_detect_output"; then
  echo "run-local-app.sh must redact auto-detected signing identities." >&2
  exit 1
fi

if ! grep -q "pgrep -x '${app_name}'" <<<"$dry_run_output"; then
  echo "run-local-app.sh must wait for the previous local app process to exit." >&2
  exit 1
fi

if ! grep -q "open -n ${install_path}" <<<"$dry_run_output"; then
  echo "run-local-app.sh must force-launch a new local app instance after reinstalling." >&2
  exit 1
fi

if INKLET_SIGN_IDENTITY="-" "${script_dir}/run-local-app.sh" --dry-run >/dev/null 2>&1; then
  echo "run-local-app.sh must reject ad-hoc signing by default." >&2
  exit 1
fi

if grep -q "identity '\\\${sign_identity}'" "${script_dir}/build-macos-app-bundle.sh"; then
  echo "build-macos-app-bundle.sh must not print signing identities." >&2
  exit 1
fi

if ! grep -Fq -- '--options runtime' "${script_dir}/build-macos-app-bundle.sh"; then
  echo "build-macos-app-bundle.sh must sign with Hardened Runtime." >&2
  exit 1
fi

echo "run-local-app.sh checks passed."
