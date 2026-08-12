#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
reset_script="${script_dir}/reset-local-state.sh"
rebuild_script="${script_dir}/reset-rebuild-install.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/inklet-reset-tests.XXXXXX")"
test_home="${test_root}/home"
test_tmp="${test_root}/tmp"
stub_bin="${test_root}/bin"
command_log="${test_root}/commands.log"
mkdir -p "${test_home}/nested" "${test_tmp}/nested" "$stub_bin"
canonical_test_home="$(cd -P -- "$test_home" && pwd -P)"
canonical_test_tmp="$(cd -P -- "$test_tmp" && pwd -P)"
trap '/bin/rm -rf "$test_root"' EXIT

fail() {
  echo "$1" >&2
  exit 1
}

cat >"${stub_bin}/command-stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command_name="${0##*/}"
{
  printf '%s' "$command_name"
  printf '\t%s' "$@"
  printf '\n'
} >>"${RESET_TEST_COMMAND_LOG:?}"

if [[ "$command_name" == "security" ]]; then
  echo "KEYCHAIN_SECRET_MARKER"
fi
EOF
chmod +x "${stub_bin}/command-stub"
for stubbed_command in defaults find osascript pkill rm security sudo tccutil; do
  ln -s command-stub "${stub_bin}/${stubbed_command}"
done

reset_environment=(
  HOME="$test_home"
  TMPDIR="$test_tmp"
  RESET_TEST_COMMAND_LOG="$command_log"
  PATH="${stub_bin}:/usr/bin:/bin:/usr/sbin:/sbin"
)

expect_invalid_arguments() {
  local check_name="$1"
  shift
  local output_file="${test_root}/${check_name}.log"

  : >"$command_log"
  if env "${reset_environment[@]}" "$reset_script" "$@" >"$output_file" 2>&1; then
    fail "reset-local-state.sh must reject ${check_name} arguments."
  fi
  if [[ -s "$command_log" ]]; then
    fail "reset-local-state.sh must reject ${check_name} arguments before mutation."
  fi
}

expect_invalid_arguments "missing-scope"
expect_invalid_arguments "missing-scope-value" --scope
expect_invalid_arguments "unknown-scope" --scope staging
expect_invalid_arguments "unknown-argument" --scope local --unexpected
expect_invalid_arguments "multiple-scopes" --scope local --scope production

expect_unsafe_base_rejected() {
  local check_name="$1"
  local unsafe_home="$2"
  local unsafe_tmp="$3"
  local output_file="${test_root}/${check_name}.log"

  : >"$command_log"
  if env \
    HOME="$unsafe_home" \
    TMPDIR="$unsafe_tmp" \
    RESET_TEST_COMMAND_LOG="$command_log" \
    PATH="${stub_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$reset_script" --scope local >"$output_file" 2>&1; then
    fail "reset-local-state.sh must reject ${check_name}."
  fi
  if [[ -s "$command_log" ]]; then
    fail "reset-local-state.sh must reject ${check_name} before mutation."
  fi
  if grep -Fq 'Selected destructive reset scope:' "$output_file"; then
    fail "reset-local-state.sh must reject ${check_name} before printing targets."
  fi
}

expect_unsafe_base_rejected "root-home-dotdot" "/.." "$test_tmp"
expect_unsafe_base_rejected "root-home-nested-dotdot" "/tmp/../.." "$test_tmp"
expect_unsafe_base_rejected "root-home-double-slash" "//" "$test_tmp"
expect_unsafe_base_rejected "root-tmp-dotdot" "$test_home" "/.."
expect_unsafe_base_rejected "root-tmp-nested-dotdot" "$test_home" "/tmp/../.."

expect_unsafe_parent_rejected() {
  local check_name="$1"
  local unsafe_home="$2"
  local unsafe_tmp="$3"
  local output_file="${test_root}/${check_name}.log"

  : >"$command_log"
  if env \
    HOME="$unsafe_home" \
    TMPDIR="$unsafe_tmp" \
    RESET_TEST_COMMAND_LOG="$command_log" \
    PATH="${stub_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$reset_script" --scope local >"$output_file" 2>&1; then
    fail "reset-local-state.sh must reject ${check_name}."
  fi
  if [[ -s "$command_log" ]]; then
    fail "reset-local-state.sh must reject ${check_name} before mutation."
  fi
  if grep -Fq 'Selected destructive reset scope:' "$output_file"; then
    fail "reset-local-state.sh must reject ${check_name} before printing targets."
  fi
}

symlink_outside="${test_root}/outside-reset-base"
library_symlink_home="${test_root}/library-symlink-home"
application_support_symlink_home="${test_root}/application-support-symlink-home"
containers_symlink_home="${test_root}/containers-symlink-home"
library_file_home="${test_root}/library-file-home"
application_support_file_home="${test_root}/application-support-file-home"
mkdir -p \
  "$symlink_outside" \
  "$library_symlink_home" \
  "${application_support_symlink_home}/Library" \
  "${containers_symlink_home}/Library" \
  "$library_file_home" \
  "${application_support_file_home}/Library"
ln -s "$symlink_outside" "${library_symlink_home}/Library"
ln -s "$symlink_outside" "${application_support_symlink_home}/Library/Application Support"
ln -s "$symlink_outside" "${containers_symlink_home}/Library/Containers"
: >"${library_file_home}/Library"
: >"${application_support_file_home}/Library/Application Support"

expect_unsafe_parent_rejected "library-parent-symlink" "$library_symlink_home" "$test_tmp"
expect_unsafe_parent_rejected \
  "application-support-parent-symlink" \
  "$application_support_symlink_home" \
  "$test_tmp"
expect_unsafe_parent_rejected \
  "containers-parent-symlink" \
  "$containers_symlink_home" \
  "$test_tmp"
expect_unsafe_parent_rejected "library-parent-file" "$library_file_home" "$test_tmp"
expect_unsafe_parent_rejected \
  "application-support-parent-file" \
  "$application_support_file_home" \
  "$test_tmp"

run_scope() {
  local scope_name="$1"
  local remove_installed_app="${2:-0}"
  local output_file="${test_root}/${scope_name}-${remove_installed_app}.log"
  local -a arguments=(--scope "$scope_name")

  if [[ "$remove_installed_app" == "1" ]]; then
    arguments+=(--remove-installed-app)
  fi

  : >"$command_log"
  if ! env "${reset_environment[@]}" "$reset_script" "${arguments[@]}" >"$output_file" 2>&1; then
    sed -n '1,200p' "$output_file" >&2
    fail "reset-local-state.sh must accept --scope ${scope_name}."
  fi
  if grep -Fq 'KEYCHAIN_SECRET_MARKER' "$output_file"; then
    fail "reset-local-state.sh must not print Keychain command output."
  fi

  local summary_line
  local action_line
  summary_line="$(grep -nF "Selected destructive reset scope: ${scope_name}" "$output_file" | cut -d: -f1)"
  action_line="$(grep -n '^+' "$output_file" | head -n 1 | cut -d: -f1)"
  if [[ -z "$summary_line" || -z "$action_line" || "$summary_line" -ge "$action_line" ]]; then
    fail "reset-local-state.sh must print the selected scope before acting."
  fi

  cp "$command_log" "${test_root}/${scope_name}-${remove_installed_app}.commands"
}

assert_log_line() {
  local log_file="$1"
  local expected_line="$2"

  if ! grep -Fxq "$expected_line" "$log_file"; then
    fail "Missing reset command: ${expected_line}"
  fi
}

assert_output_line() {
  local output_file="$1"
  local expected_line="$2"

  if ! grep -Fxq "$expected_line" "$output_file"; then
    fail "Missing reset scope target: ${expected_line}"
  fi
}

local_bundle="com.tomwan.inklet.local"
production_bundle="com.tomwan.inklet"
local_support="${canonical_test_home}/Library/Application Support/${local_bundle}"
production_support="${canonical_test_home}/Library/Application Support/${production_bundle}"
local_container="${canonical_test_home}/Library/Containers/${local_bundle}"
production_container="${canonical_test_home}/Library/Containers/${production_bundle}"
local_diagnostic="${canonical_test_tmp}/InkletSelectionActions.${local_bundle}.log"
production_diagnostic="${canonical_test_tmp}/InkletSelectionActions.${production_bundle}.log"
local_service="Inklet.Local.ProviderAPIKey"
production_service="Inklet.ProviderAPIKey"
local_app="/Applications/Inklet Local.app"
production_app="/Applications/Inklet.app"

assert_canonicalized_base_paths() {
  local check_name="$1"
  local home_input="$2"
  local tmp_input="$3"
  local output_file="${test_root}/${check_name}.log"
  local commands_file="${test_root}/${check_name}.commands"

  : >"$command_log"
  if ! env \
    HOME="$home_input" \
    TMPDIR="$tmp_input" \
    RESET_TEST_COMMAND_LOG="$command_log" \
    PATH="${stub_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$reset_script" --scope local >"$output_file" 2>&1; then
    sed -n '1,200p' "$output_file" >&2
    fail "reset-local-state.sh must accept and canonicalize ${check_name}."
  fi
  cp "$command_log" "$commands_file"

  assert_output_line "$output_file" "  Application Support: ${local_support}"
  assert_output_line "$output_file" "  Legacy container: ${local_container}"
  assert_output_line "$output_file" "  Diagnostics: ${local_diagnostic}"
  assert_log_line "$commands_file" $'rm\t-rf\t'"${local_support}"
  assert_log_line "$commands_file" $'rm\t-rf\t'"${local_container}"
  assert_log_line "$commands_file" $'rm\t-f\t'"${local_diagnostic}"
  if grep -Eq '(^|/)\.\.(/|$)' "$output_file" "$commands_file"; then
    fail "Canonical reset targets must not retain dot-dot components."
  fi
}

assert_canonicalized_base_paths \
  "safe-home-dotdot" \
  "${test_home}/nested/.." \
  "$test_tmp"
assert_canonicalized_base_paths \
  "safe-tmp-dotdot" \
  "$test_home" \
  "${test_tmp}/nested/.."

symlink_tmp="${test_root}/tmp-symlink"
ln -s "$test_tmp" "$symlink_tmp"
assert_canonicalized_base_paths \
  "safe-tmp-symlink-input" \
  "$test_home" \
  "$symlink_tmp"

final_symlink_home="${test_root}/final-target-symlink-home"
final_symlink_tmp="${test_root}/final-target-symlink-tmp"
final_symlink_outside="${test_root}/final-target-symlink-outside"
mkdir -p \
  "${final_symlink_home}/Library/Application Support" \
  "${final_symlink_home}/Library/Containers" \
  "$final_symlink_tmp" \
  "$final_symlink_outside"
canonical_final_symlink_home="$(cd -P -- "$final_symlink_home" && pwd -P)"
canonical_final_symlink_tmp="$(cd -P -- "$final_symlink_tmp" && pwd -P)"
final_symlink_support="${canonical_final_symlink_home}/Library/Application Support/${local_bundle}"
final_symlink_container="${canonical_final_symlink_home}/Library/Containers/${local_bundle}"
final_symlink_diagnostic="${canonical_final_symlink_tmp}/InkletSelectionActions.${local_bundle}.log"
ln -s "$final_symlink_outside" "$final_symlink_support"
ln -s "$final_symlink_outside" "$final_symlink_container"
ln -s "${final_symlink_outside}/diagnostic.log" "$final_symlink_diagnostic"

: >"$command_log"
final_symlink_output="${test_root}/final-target-symlinks.log"
if ! env \
  HOME="$final_symlink_home" \
  TMPDIR="$final_symlink_tmp" \
  RESET_TEST_COMMAND_LOG="$command_log" \
  PATH="${stub_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$reset_script" --scope local >"$final_symlink_output" 2>&1; then
  sed -n '1,200p' "$final_symlink_output" >&2
  fail "reset-local-state.sh must allow an exact final target that is a symlink."
fi
assert_output_line "$final_symlink_output" "  Application Support: ${final_symlink_support}"
assert_output_line "$final_symlink_output" "  Legacy container: ${final_symlink_container}"
assert_output_line "$final_symlink_output" "  Diagnostics: ${final_symlink_diagnostic}"
assert_log_line "$command_log" $'rm\t-rf\t'"${final_symlink_support}"
assert_log_line "$command_log" $'rm\t-rf\t'"${final_symlink_container}"
assert_log_line "$command_log" $'rm\t-f\t'"${final_symlink_diagnostic}"
if grep -Fq "$final_symlink_outside" "$final_symlink_output" "$command_log"; then
  fail "Reset output and commands must name only the exact symlink target, not its destination."
fi
if [[ ! -L "$final_symlink_support" || ! -L "$final_symlink_container" ||
  ! -L "$final_symlink_diagnostic" ]]; then
  fail "Stubbed reset commands must not mutate final symlink targets."
fi

run_scope local
local_output="${test_root}/local-0.log"
local_commands="${test_root}/local-0.commands"
assert_output_line "$local_output" "  Bundle ID: ${local_bundle}"
assert_output_line "$local_output" "  Application Support: ${local_support}"
assert_output_line "$local_output" "  Legacy container: ${local_container}"
assert_output_line "$local_output" "  Keychain service: ${local_service}"
assert_output_line "$local_output" "  Diagnostics: ${local_diagnostic}"
assert_output_line "$local_output" "  Installed app: ${local_app}"
assert_log_line "$local_commands" $'defaults\tdelete\tcom.tomwan.inklet.local'
assert_log_line "$local_commands" $'tccutil\treset\tAccessibility\tcom.tomwan.inklet.local'
assert_log_line "$local_commands" $'tccutil\treset\tMicrophone\tcom.tomwan.inklet.local'
assert_log_line \
  "$local_commands" \
  $'security\tdelete-generic-password\t-s\tInklet.Local.ProviderAPIKey\t-a\topenai'
assert_log_line "$local_commands" $'rm\t-rf\t'"${local_support}"
assert_log_line "$local_commands" $'rm\t-rf\t'"${local_container}"
assert_log_line "$local_commands" $'rm\t-f\t'"${local_diagnostic}"
if grep -Fxq $'defaults\tdelete\tcom.tomwan.inklet' "$local_commands" ||
  grep -Fxq "  Application Support: ${production_support}" "$local_output" ||
  grep -Fxq "  Legacy container: ${production_container}" "$local_output" ||
  grep -Fq "$production_diagnostic" "$local_output" ||
  grep -Fq "$production_service" "$local_output" ||
  grep -Fq "$production_app" "$local_output"; then
  fail "The local reset scope must not name production targets."
fi
if grep -Fxq $'security\tdelete-generic-password\t-s\tInklet.Local.ProviderAPIKey' \
  "$local_commands"; then
  fail "The local reset scope must not delete a Keychain service without its account."
fi
if grep -Fq $'\t/Applications/' "$local_commands"; then
  fail "Installed apps must be kept unless --remove-installed-app is passed."
fi

run_scope production
production_output="${test_root}/production-0.log"
production_commands="${test_root}/production-0.commands"
assert_output_line "$production_output" "  Bundle ID: ${production_bundle}"
assert_output_line "$production_output" "  Application Support: ${production_support}"
assert_output_line "$production_output" "  Legacy container: ${production_container}"
assert_output_line "$production_output" "  Keychain service: ${production_service}"
assert_output_line "$production_output" "  Diagnostics: ${production_diagnostic}"
assert_output_line "$production_output" "  Installed app: ${production_app}"
assert_log_line "$production_commands" $'defaults\tdelete\tcom.tomwan.inklet'
assert_log_line "$production_commands" $'tccutil\treset\tAccessibility\tcom.tomwan.inklet'
assert_log_line "$production_commands" $'tccutil\treset\tMicrophone\tcom.tomwan.inklet'
assert_log_line \
  "$production_commands" \
  $'security\tdelete-generic-password\t-s\tInklet.ProviderAPIKey\t-a\topenai'
assert_log_line "$production_commands" $'rm\t-rf\t'"${production_support}"
assert_log_line "$production_commands" $'rm\t-rf\t'"${production_container}"
assert_log_line "$production_commands" $'rm\t-f\t'"${production_diagnostic}"
if grep -Fq "$local_bundle" "$production_output" ||
  grep -Fq "$local_support" "$production_output" ||
  grep -Fq "$local_container" "$production_output" ||
  grep -Fq "$local_diagnostic" "$production_output" ||
  grep -Fq "$local_service" "$production_output" ||
  grep -Fq "$local_app" "$production_output"; then
  fail "The production reset scope must not name local targets."
fi
if grep -Fxq $'security\tdelete-generic-password\t-s\tInklet.ProviderAPIKey' \
  "$production_commands"; then
  fail "The production reset scope must not delete a Keychain service without its account."
fi
if grep -Fq $'\t/Applications/' "$production_commands"; then
  fail "Installed apps must be kept unless --remove-installed-app is passed."
fi

run_scope all 1
all_output="${test_root}/all-1.log"
all_commands="${test_root}/all-1.commands"
for expected_target in \
  "$local_bundle" "$production_bundle" \
  "$local_support" "$production_support" \
  "$local_container" "$production_container" \
  "$local_diagnostic" "$production_diagnostic" \
  "$local_service" "$production_service" \
  "$local_app" "$production_app"; do
  if ! grep -Fq "$expected_target" "$all_output"; then
    fail "The all reset scope must include ${expected_target}."
  fi
done
for expected_command in \
  $'defaults\tdelete\tcom.tomwan.inklet.local' \
  $'defaults\tdelete\tcom.tomwan.inklet' \
  $'tccutil\treset\tAccessibility\tcom.tomwan.inklet.local' \
  $'tccutil\treset\tMicrophone\tcom.tomwan.inklet.local' \
  $'tccutil\treset\tAccessibility\tcom.tomwan.inklet' \
  $'tccutil\treset\tMicrophone\tcom.tomwan.inklet' \
  $'security\tdelete-generic-password\t-s\tInklet.Local.ProviderAPIKey\t-a\topenai' \
  $'security\tdelete-generic-password\t-s\tInklet.ProviderAPIKey\t-a\topenai' \
  $'rm\t-rf\t'"${local_support}" \
  $'rm\t-rf\t'"${production_support}" \
  $'rm\t-rf\t'"${local_container}" \
  $'rm\t-rf\t'"${production_container}" \
  $'rm\t-f\t'"${local_diagnostic}" \
  $'rm\t-f\t'"${production_diagnostic}"; do
  assert_log_line "$all_commands" "$expected_command"
done
if grep -Eq $'^security\tdelete-generic-password\t-s\t(.*ProviderAPIKey)$' "$all_commands"; then
  fail "The all reset scope must not delete a Keychain service without its account."
fi
if [[ "$(grep -c $'^security\tdelete-generic-password\t' "$all_commands")" != "2" ]]; then
  fail "The all reset scope must issue exactly one account-qualified Keychain deletion per bundle."
fi
for installed_app in "$local_app" "$production_app"; do
  if ! grep -Eq $'^(rm\t-rf|sudo\trm\t-rf)\t'"${installed_app//./\\.}"'$' "$all_commands"; then
    fail "--remove-installed-app must remove ${installed_app}."
  fi
done

if grep -Eq $'tccutil\treset\t(AppleEvents|Automation)(\t|$)' "$all_commands"; then
  fail "reset-local-state.sh must never reset AppleEvents or Automation."
fi
tcc_count="$(grep -c $'^tccutil\t' "$all_commands")"
if [[ "$tcc_count" != "4" ]]; then
  fail "reset-local-state.sh must reset only Accessibility and Microphone for each bundle."
fi

allowed_removal_targets=(
  "$local_support"
  "$production_support"
  "$local_container"
  "$production_container"
  "$local_diagnostic"
  "$production_diagnostic"
  "$local_app"
  "$production_app"
)
while IFS=$'\t' read -r command_name first_argument second_argument removal_target; do
  if [[ "$command_name" == "sudo" ]]; then
    if [[ "$first_argument" != "rm" ]]; then
      fail "sudo must only wrap exact installed-app removal."
    fi
  elif [[ "$command_name" != "rm" ]]; then
    continue
  else
    removal_target="$second_argument"
  fi

  allowed=0
  for allowed_target in "${allowed_removal_targets[@]}"; do
    if [[ "$removal_target" == "$allowed_target" ]]; then
      allowed=1
      break
    fi
  done
  if [[ "$allowed" != "1" || "$removal_target" == *'*'* || "$removal_target" == *'?'* ||
    "$removal_target" == "$test_home" || "$removal_target" == "/Applications" ||
    "$removal_target" == "${test_home}/Library/Application Support" ||
    "$removal_target" == "${test_home}/Library/Containers" ]]; then
    fail "Reset removal target is not an exact approved path: ${removal_target}"
  fi
done <"$all_commands"

dry_run_log="${test_root}/dry-run.log"
: >"$command_log"
if ! env "${reset_environment[@]}" "$reset_script" --scope local --dry-run >"$dry_run_log" 2>&1; then
  fail "reset-local-state.sh must support a safe scoped dry run."
fi
if [[ -s "$command_log" ]]; then
  fail "reset-local-state.sh --dry-run must not execute reset commands."
fi
for exact_target in "$local_support" "$local_container" "$local_diagnostic"; do
  if ! grep -Fq "$exact_target" "$dry_run_log"; then
    fail "Scoped dry run must print exact target ${exact_target}."
  fi
done

expected_reset_line='"${repo_root}/scripts/reset-local-state.sh" --scope local --remove-installed-app'
expected_runner_line='"${repo_root}/scripts/run-local-app.sh"'
if ! grep -Fxq "$expected_reset_line" "$rebuild_script"; then
  fail "reset-rebuild-install.sh must reset only the local scope and remove the local app."
fi
if ! grep -Fxq "$expected_runner_line" "$rebuild_script"; then
  fail "reset-rebuild-install.sh must use run-local-app.sh."
fi
reset_line_number="$(grep -nFx "$expected_reset_line" "$rebuild_script" | cut -d: -f1)"
runner_line_number="$(grep -nFx "$expected_runner_line" "$rebuild_script" | cut -d: -f1)"
if [[ "$reset_line_number" -ge "$runner_line_number" ]] ||
  [[ "$(grep -Fc 'reset-local-state.sh' "$rebuild_script")" != "1" ]] ||
  [[ "$(grep -Fc 'run-local-app.sh' "$rebuild_script")" != "1" ]]; then
  fail "reset-rebuild-install.sh must run exactly one local reset before exactly one local runner."
fi

echo "reset-local-state.sh checks passed."
