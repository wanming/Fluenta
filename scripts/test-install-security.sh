#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_script="${script_dir}/install.sh"
temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT

fail() {
  echo "$1" >&2
  exit 1
}

if grep -q 'continuing without checksum verification' "$install_script"; then
  fail "install.sh must not continue when checksum verification is unavailable."
fi
if ! grep -q 'Could not download checksum asset' "$install_script"; then
  fail "install.sh must fail explicitly when the checksum asset cannot be downloaded."
fi
if ! grep -q 'Could not find release asset' "$install_script"; then
  fail "install.sh must fail explicitly when the DMG asset cannot be found."
fi
if ! grep -Fq 'hdiutil verify "$dmg_path"' "$install_script"; then
  fail "install.sh must verify the downloaded DMG structure."
fi
if ! grep -Fq 'spctl --assess --type open --context context:primary-signature "$dmg_path"' "$install_script"; then
  fail "install.sh must assess the downloaded DMG with the primary-signature context."
fi
if ! grep -Fq 'hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_dir" -plist' "$install_script"; then
  fail "install.sh must mount the DMG read-only and capture structured device metadata."
fi
if ! grep -Fq 'pending_mount_devices=()' "$install_script" ||
  ! grep -Fq 'attach_succeeded=1' "$install_script" ||
  ! grep -Fq 'system-entities' "$install_script"; then
  fail "install.sh must retain every safe mounted device before validating the unique mount."
fi
if ! grep -Fq 'find "$mount_dir" -mindepth 1 -maxdepth 1 -print0' "$install_script" ||
  ! grep -Fq 'readlink "$applications_link"' "$install_script"; then
  fail "install.sh must verify the exact top-level DMG payload."
fi
if ! grep -Fq 'codesign --verify --deep --strict "$source_app"' "$install_script"; then
  fail "install.sh must verify the mounted app signature."
fi
if ! grep -Fq 'spctl --assess --type execute "$source_app"' "$install_script"; then
  fail "install.sh must assess the mounted app as executable code."
fi
if ! grep -Fq 'com.tomwan.inklet' "$install_script" ||
  ! grep -Fq 'CFBundleIdentifier' "$install_script"; then
  fail "install.sh must enforce the production bundle identifier inline."
fi
if ! grep -Fq 'NSMicrophoneUsageDescription' "$install_script" ||
  ! grep -Fq 'NSAppleEventsUsageDescription' "$install_script"; then
  fail "install.sh must enforce the direct-distribution privacy plist inline."
fi
if ! grep -Fq 'com.apple.security.device.audio-input' "$install_script" ||
  ! grep -Fq -- '--entitlements :-' "$install_script" ||
  ! grep -Fq -- '--arch "$architecture"' "$install_script"; then
  fail "install.sh must enforce the one-key entitlement allowlist per architecture."
fi
if ! grep -Fq 'lipo -archs' "$install_script" || ! grep -Fq 'runtime_found' "$install_script"; then
  fail "install.sh must enforce Hardened Runtime per architecture."
fi
if ! grep -Fq 'embedded.provisionprofile' "$install_script" ||
  ! grep -Fq '_MASReceipt' "$install_script"; then
  fail "install.sh must reject provisioning profiles and App Store receipts."
fi
if grep -Fq 'verify-direct-app.sh' "$install_script"; then
  fail "install.sh must remain standalone instead of downloading or invoking the repository verifier."
fi
if grep -Eq 'codesign .*--verbose=[234][[:space:]]+"\$source_app"$|spctl .*-[vV]' "$install_script"; then
  fail "install.sh must capture signature and Gatekeeper metadata instead of printing it."
fi
if grep -Eq 'xattr([[:space:]].*)?(-d|-c|--no-quarantine)|--no-quarantine' "$install_script"; then
  fail "install.sh must preserve the downloaded app quarantine attribute."
fi

fake_bin="${temp_root}/fake-bin"
mkdir -p "$fake_bin"

cat >"${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url=""
output_path=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-o" ]]; then
    output_path="$argument"
    previous=""
    continue
  fi
  if [[ "$argument" == "-o" ]]; then
    previous="-o"
    continue
  fi
  if [[ "$argument" == https://* ]]; then
    url="$argument"
  fi
done

case "$url" in
  */releases)
    printf '%s\n' '[{"draft":false,"prerelease":false,"assets":[{"name":"Inklet.dmg","url":"https://fixture.invalid/Inklet.dmg","browser_download_url":"https://fixture.invalid/Inklet.dmg"},{"name":"Inklet.dmg.sha256","url":"https://fixture.invalid/Inklet.dmg.sha256","browser_download_url":"https://fixture.invalid/Inklet.dmg.sha256"}]}]'
    ;;
  */Inklet.dmg)
    printf 'fixture dmg\n' >"$output_path"
    printf '%s\n' curl-dmg >>"$TEST_COMMAND_LOG"
    ;;
  */Inklet.dmg.sha256)
    if [[ "$TEST_FAILURE_MODE" == "checksum" ]]; then
      printf '%064d  Inklet.dmg\n' 0 >"$output_path"
    else
      printf '%064d  Inklet.dmg\n' 1 >"$output_path"
    fi
    printf '%s\n' curl-checksum >>"$TEST_COMMAND_LOG"
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat >"${fake_bin}/shasum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%064d  %s\n' 1 "${@: -1}"
EOF

cat >"${fake_bin}/hdiutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'hdiutil:%s\n' "$*" >>"$TEST_COMMAND_LOG"
case "${1:-}" in
  verify)
    [[ "$TEST_FAILURE_MODE" != "hdiutil-verify" ]]
    ;;
  attach)
    mountpoint=""
    previous=""
    for argument in "$@"; do
      if [[ "$previous" == "-mountpoint" ]]; then
        mountpoint="$argument"
        break
      fi
      previous="$argument"
    done
    [[ -n "$mountpoint" ]]
    mkdir -p "$mountpoint"
    if [[ "$TEST_FAILURE_MODE" != "missing-app" ]]; then
      /bin/cp -R "$TEST_FIXTURE_APP" "$mountpoint/Inklet.app"
    fi
    if [[ "$TEST_FAILURE_MODE" == "app-symlink" ]]; then
      rm -rf "$mountpoint/Inklet.app"
      ln -s "$TEST_FIXTURE_APP" "$mountpoint/Inklet.app"
    fi
    case "$TEST_FAILURE_MODE" in
      missing-applications)
        ;;
      applications-directory)
        mkdir "$mountpoint/Applications"
        ;;
      applications-wrong-target)
        ln -s /Unexpected "$mountpoint/Applications"
        ;;
      applications-relative-target)
        ln -s ApplicationsRelative "$mountpoint/Applications"
        ;;
      *)
        ln -s /Applications "$mountpoint/Applications"
        ;;
    esac
    case "$TEST_FAILURE_MODE" in
      extra-top-file)
        touch "$mountpoint/Unexpected.txt"
        ;;
      extra-hidden-file)
        touch "$mountpoint/.unexpected"
        ;;
      extra-top-directory)
        mkdir "$mountpoint/Unexpected"
        ;;
      newline-top-file)
        touch "$mountpoint/"$'Unexpected\nfile'
        ;;
    esac
    printf '%s\n' "$mountpoint" >"$TEST_MOUNT_STATE"
    printf 'mount-target:%s\n' "$mountpoint" >>"$TEST_COMMAND_LOG"
    : >"$TEST_DEVICE_STATE"
    case "$TEST_FAILURE_MODE" in
      attach-zero-mounted|attach-missing-device|attach-unsafe-device)
        ;;
      attach-two-mounted)
        printf '/dev/disk99s1\n/dev/disk100s2\n' >"$TEST_DEVICE_STATE"
        ;;
      attach-mixed-devices)
        printf '/dev/disk99s1\n' >"$TEST_DEVICE_STATE"
        ;;
      *)
        printf '/dev/disk99s1\n' >"$TEST_DEVICE_STATE"
        ;;
    esac
    while IFS= read -r expected_device; do
      printf 'device-target:%s\n' "$expected_device" >>"$TEST_COMMAND_LOG"
    done <"$TEST_DEVICE_STATE"
    MOUNT_POINT="$mountpoint" FAILURE_MODE="$TEST_FAILURE_MODE" /usr/bin/python3 - <<'PY'
import os
import plistlib
import sys

mount_point = os.environ["MOUNT_POINT"]
failure_mode = os.environ["FAILURE_MODE"]
parent = {"dev-entry": "/dev/disk99"}
mounted = {"dev-entry": "/dev/disk99s1", "mount-point": mount_point}

if failure_mode == "attach-zero-mounted":
    entities = [parent]
elif failure_mode == "attach-two-mounted":
    entities = [
        parent,
        mounted,
        {"dev-entry": "/dev/disk100s2", "mount-point": mount_point + "-other"},
    ]
elif failure_mode == "attach-wrong-mountpoint":
    entities = [parent, {"dev-entry": "/dev/disk99s1", "mount-point": mount_point + "-wrong"}]
elif failure_mode == "attach-missing-device":
    entities = [parent, {"mount-point": mount_point}]
elif failure_mode == "attach-unsafe-device":
    entities = [parent, {"dev-entry": "/dev/disk99s1;unexpected", "mount-point": mount_point}]
elif failure_mode == "attach-mixed-devices":
    entities = [
        parent,
        mounted,
        {"dev-entry": "/dev/disk100s2;unexpected", "mount-point": mount_point + "-unsafe"},
        {"mount-point": mount_point + "-missing"},
    ]
else:
    entities = [parent, mounted]

plistlib.dump({"system-entities": entities}, sys.stdout.buffer)
PY
    ;;
  detach)
    [[ -s "$TEST_MOUNT_STATE" ]]
    if [[ -s "$TEST_DEVICE_STATE" ]]; then
      grep -Fxq -- "${2:-}" "$TEST_DEVICE_STATE"
    else
      [[ "${2:-}" == "$(<"$TEST_MOUNT_STATE")" ]]
    fi
    printf 'detach-target:%s\n' "${2:-}" >>"$TEST_COMMAND_LOG"
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat >"${fake_bin}/spctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'spctl:%s\n' "$*" >>"$TEST_COMMAND_LOG"
if [[ "$*" == *"--type open"* && "$TEST_FAILURE_MODE" == "dmg-spctl" ]]; then
  exit 1
fi
if [[ "$*" == *"--type execute"* && "$TEST_FAILURE_MODE" == "app-spctl" ]]; then
  exit 1
fi
EOF

cat >"${fake_bin}/lipo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'lipo:%s\n' "$*" >>"$TEST_COMMAND_LOG"
printf '%s\n' 'arm64 x86_64'
EOF

cat >"${fake_bin}/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'codesign:%s\n' "$*" >>"$TEST_COMMAND_LOG"
if [[ "${1:-}" == "--verify" ]]; then
  count=0
  if [[ -f "$TEST_SIGNATURE_COUNT" ]]; then
    count="$(<"$TEST_SIGNATURE_COUNT")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" >"$TEST_SIGNATURE_COUNT"
  if [[ "$TEST_FAILURE_MODE" == "initial-signature" && "$count" == "1" ]]; then
    exit 1
  fi
  if [[ ( "$TEST_FAILURE_MODE" == "final-signature" || "$TEST_FAILURE_MODE" == "mutation" ) &&
    "$count" == "2" ]]; then
    exit 1
  fi
  exit 0
fi

if [[ "$*" == *"--entitlements :-"* ]]; then
  if [[ "$TEST_FAILURE_MODE" == "mutation" ]]; then
    app_path="${@: -1}"
    plutil -replace CFBundleVersion -string changed-after-initial-verification \
      "$app_path/Contents/Info.plist"
    touch "$TEST_MUTATION_MARKER"
  fi
  if [[ "$TEST_FAILURE_MODE" == "extra-entitlement" ]]; then
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.device.audio-input</key><true/></dict></plist>'
  else
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>'
  fi
  exit 0
fi

if [[ "$*" == *"--verbose=4"* ]]; then
  if [[ "$TEST_FAILURE_MODE" == "no-runtime" ]]; then
    printf '%s\n' 'CodeDirectory v=20500 size=1 flags=0x0(none) hashes=1+0 location=embedded'
  else
    printf '%s\n' 'CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+0 location=embedded'
  fi
  exit 0
fi

exit 1
EOF

cat >"${fake_bin}/ditto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ditto:%s\n' "$*" >>"$TEST_COMMAND_LOG"
mkdir -p "${@: -1}"
EOF

for command_name in osascript pkill; do
  cat >"${fake_bin}/${command_name}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s:%s\n' "$(basename "$0")" "$*" >>"$TEST_COMMAND_LOG"
EOF
done

cat >"${fake_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sudo:%s\n' "$*" >>"$TEST_COMMAND_LOG"
exit 97
EOF

chmod +x "${fake_bin}"/*

make_fixture() {
  local case_dir="$1"
  local failure_mode="$2"
  local fixture_app="${case_dir}/Fixture.app"
  local bundle_id="com.tomwan.inklet"

  if [[ "$failure_mode" == "wrong-bundle-id" ]]; then
    bundle_id="com.tomwan.inklet.unexpected"
  fi

  mkdir -p "${fixture_app}/Contents/MacOS"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${fixture_app}/Contents/MacOS/Inklet"
  chmod +x "${fixture_app}/Contents/MacOS/Inklet"
  cat >"${fixture_app}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Inklet</string>
  <key>CFBundleIdentifier</key>
  <string>${bundle_id}</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Microphone access is required for voice input.</string>
</dict>
</plist>
EOF

  case "$failure_mode" in
    missing-microphone)
      plutil -remove NSMicrophoneUsageDescription "${fixture_app}/Contents/Info.plist"
      ;;
    invalid-microphone-type)
      plutil -replace NSMicrophoneUsageDescription -json '["Unexpected usage"]' \
        "${fixture_app}/Contents/Info.plist"
      ;;
    apple-events)
      plutil -insert NSAppleEventsUsageDescription -string "Unexpected usage" \
        "${fixture_app}/Contents/Info.plist"
      ;;
    profile)
      printf 'fixture\n' >"${fixture_app}/Contents/embedded.provisionprofile"
      ;;
    dangling-profile)
      ln -s "${case_dir}/missing-profile" "${fixture_app}/Contents/embedded.provisionprofile"
      ;;
    receipt)
      mkdir -p "${fixture_app}/Contents/_MASReceipt"
      printf 'fixture\n' >"${fixture_app}/Contents/_MASReceipt/receipt"
      ;;
    dangling-receipt)
      ln -s "${case_dir}/missing-receipt" "${fixture_app}/Contents/_MASReceipt"
      ;;
  esac

  printf '%s\n' "$fixture_app"
}

run_installer_case() {
  local case_name="$1"
  local failure_mode="$2"
  local expected_status="$3"
  local case_dir="${temp_root}/${case_name}"
  local command_log="${case_dir}/commands.log"
  local output_log="${case_dir}/output.log"
  local signature_count="${case_dir}/signature-count"
  local mutation_marker="${case_dir}/mutation-applied"
  local install_dir="${case_dir}/Applications"
  local mount_state="${case_dir}/mount-state"
  local device_state="${case_dir}/device-state"
  local script_under_test="${4:-$install_script}"
  local fixture_app
  local status

  mkdir -p "$case_dir" "$install_dir"
  fixture_app="$(make_fixture "$case_dir" "$failure_mode")"
  : >"$command_log"

  set +e
  env \
    PATH="${fake_bin}:$PATH" \
    TMPDIR="$case_dir" \
    GITHUB_TOKEN="installer-secret-output-marker" \
    INKLET_INSTALL_DIR="$install_dir" \
    TEST_COMMAND_LOG="$command_log" \
    TEST_FIXTURE_APP="$fixture_app" \
    TEST_FAILURE_MODE="$failure_mode" \
    TEST_SIGNATURE_COUNT="$signature_count" \
    TEST_MUTATION_MARKER="$mutation_marker" \
    TEST_MOUNT_STATE="$mount_state" \
    TEST_DEVICE_STATE="$device_state" \
    bash "$script_under_test" >"$output_log" 2>&1
  status=$?
  set -e

  if [[ "$expected_status" == "success" && "$status" != "0" ]]; then
    fail "install.sh must accept the fully verified fixture (${case_name})."
  fi
  if [[ "$expected_status" == "failure" && "$status" == "0" ]]; then
    fail "install.sh must reject the invalid fixture (${case_name})."
  fi
  if grep -Eq 'installer-secret-output-marker|Authority=|TeamIdentifier=|Developer ID Application:' "$output_log"; then
    fail "install.sh must not expose credentials or signing identities (${case_name})."
  fi
  if [[ "$expected_status" == "failure" ]] && grep -q '^ditto:' "$command_log"; then
    fail "install.sh must fail before installing an unverified fixture (${case_name})."
  fi
}

assert_detach_contract() {
  local command_log="$1"
  local required_predecessor_pattern="$2"
  local expected_target_kind="${3:-device}"
  local expected_targets
  local actual_targets
  local predecessor_line
  local detach_line

  if [[ "$expected_target_kind" == "device" ]]; then
    expected_targets="$(sed -n 's/^device-target://p' "$command_log" | LC_ALL=C sort)"
  else
    expected_targets="$(sed -n 's/^mount-target://p' "$command_log" | LC_ALL=C sort)"
  fi
  actual_targets="$(sed -n 's/^detach-target://p' "$command_log" | LC_ALL=C sort)"
  if [[ -z "$expected_targets" || "$actual_targets" != "$expected_targets" ]] ||
    [[ "$(grep -c '^hdiutil:detach ' "$command_log")" != "$(printf '%s\n' "$expected_targets" | awk 'END { print NR }')" ]] ||
    [[ "$(grep -c '^detach-target:' "$command_log")" != "$(printf '%s\n' "$expected_targets" | awk 'END { print NR }')" ]]; then
    return 1
  fi
  predecessor_line="$(grep -nE "$required_predecessor_pattern" "$command_log" | tail -n 1 | cut -d: -f1)"
  detach_line="$(grep -n '^hdiutil:detach ' "$command_log" | head -n 1 | cut -d: -f1)"
  if [[ -z "$predecessor_line" || -z "$detach_line" ]] ||
    ((predecessor_line >= detach_line)); then
    return 1
  fi
}

run_installer_case valid valid success
valid_log="${temp_root}/valid/commands.log"
required_success_commands=(
  '^hdiutil:verify .*/Inklet\.dmg$'
  '^spctl:--assess --type open --context context:primary-signature .*/Inklet\.dmg$'
  '^hdiutil:attach .*/Inklet\.dmg -readonly -nobrowse -mountpoint .* -plist$'
  '^lipo:-archs .*/Inklet\.app/Contents/MacOS/Inklet$'
  '^spctl:--assess --type execute .*/Inklet\.app$'
  '^ditto:.*/Inklet\.app .*/Applications/Inklet\.app$'
)
for command_pattern in "${required_success_commands[@]}"; do
  if ! grep -Eq "$command_pattern" "$valid_log"; then
    fail "install.sh valid path is missing a required verification or install command."
  fi
done
if [[ "$(grep -c '^codesign:--verify --deep --strict ' "$valid_log")" != "2" ]]; then
  fail "install.sh must verify app integrity before and after inline inspection."
fi
if [[ "$(grep -c '^codesign:-d --arch .* --entitlements :- ' "$valid_log")" != "2" ]] ||
  [[ "$(grep -c '^codesign:-d --arch .* --verbose=4 ' "$valid_log")" != "2" ]]; then
  fail "install.sh must inspect entitlements and runtime for every architecture."
fi

command_line() {
  local pattern="$1"
  local log_path="$2"
  grep -nE "$pattern" "$log_path" | head -n 1 | cut -d: -f1
}

valid_order=(
  "$(command_line '^hdiutil:verify ' "$valid_log")"
  "$(command_line '^spctl:--assess --type open ' "$valid_log")"
  "$(command_line '^hdiutil:attach ' "$valid_log")"
  "$(command_line '^codesign:--verify --deep --strict ' "$valid_log")"
  "$(command_line '^lipo:-archs ' "$valid_log")"
  "$(command_line '^codesign:-d --arch .* --entitlements :- ' "$valid_log")"
  "$(command_line '^codesign:-d --arch .* --verbose=4 ' "$valid_log")"
  "$(grep -n '^codesign:--verify --deep --strict ' "$valid_log" | tail -n 1 | cut -d: -f1)"
  "$(command_line '^spctl:--assess --type execute ' "$valid_log")"
  "$(command_line '^ditto:' "$valid_log")"
)
for ((index = 1; index < ${#valid_order[@]}; index += 1)); do
  if [[ -z "${valid_order[index - 1]}" || -z "${valid_order[index]}" ]] ||
    ((valid_order[index - 1] >= valid_order[index])); then
    fail "install.sh must verify every final artifact before installation."
  fi
done
if ! assert_detach_contract "$valid_log" '^ditto:.*Inklet\.app .*/Applications/Inklet\.app$'; then
  fail "install.sh must detach the mounted image exactly once after successful validation and installation."
fi

run_installer_case checksum checksum failure
if grep -Eq '^(hdiutil|spctl|codesign|ditto):' "${temp_root}/checksum/commands.log"; then
  fail "A checksum mismatch must abort before DMG verification or installation."
fi

run_installer_case hdiutil-verify hdiutil-verify failure
if grep -Eq '^(spctl|codesign|ditto):' "${temp_root}/hdiutil-verify/commands.log"; then
  fail "A malformed DMG must abort before Gatekeeper, mounting, or installation."
fi

run_installer_case dmg-spctl dmg-spctl failure
if grep -Eq '^hdiutil:attach |^codesign:|^ditto:' "${temp_root}/dmg-spctl/commands.log"; then
  fail "A rejected DMG must abort before mounting or installation."
fi

attach_metadata_failures=(
  attach-zero-mounted
  attach-missing-device
  attach-unsafe-device
)
for attach_metadata_failure in "${attach_metadata_failures[@]}"; do
  run_installer_case "$attach_metadata_failure" "$attach_metadata_failure" failure
  metadata_log="${temp_root}/${attach_metadata_failure}/commands.log"
  if grep -Eq '^codesign:|^ditto:' "$metadata_log"; then
    fail "Invalid structured mount metadata must abort before app validation or installation."
  fi
  if ! assert_detach_contract "$metadata_log" '^hdiutil:attach ' mountpoint; then
    fail "A structured mount metadata failure must detach the requested mount point as fallback."
  fi
done

attach_device_cleanup_failures=(
  attach-wrong-mountpoint
  attach-two-mounted
  attach-mixed-devices
)
for attach_device_cleanup_failure in "${attach_device_cleanup_failures[@]}"; do
  run_installer_case "$attach_device_cleanup_failure" "$attach_device_cleanup_failure" failure
  cleanup_log="${temp_root}/${attach_device_cleanup_failure}/commands.log"
  if grep -Eq '^codesign:|^ditto:' "$cleanup_log"; then
    fail "Invalid structured mount metadata must abort before app validation or installation."
  fi
  if ! assert_detach_contract "$cleanup_log" '^hdiutil:attach ' device; then
    fail "Every safe device from rejected mount metadata must be detached exactly once."
  fi
  if grep -Fq "detach-target:$(sed -n 's/^mount-target://p' "$cleanup_log")" "$cleanup_log"; then
    fail "A rejected mount with safe device metadata must not detach only the requested mount point."
  fi
done

invalid_payload_cases=(
  missing-app
  app-symlink
  extra-top-file
  extra-hidden-file
  extra-top-directory
  newline-top-file
  missing-applications
  applications-directory
  applications-wrong-target
  applications-relative-target
)
for invalid_payload_case in "${invalid_payload_cases[@]}"; do
  run_installer_case "$invalid_payload_case" "$invalid_payload_case" failure
  payload_log="${temp_root}/${invalid_payload_case}/commands.log"
  if grep -Eq '^codesign:|^ditto:' "$payload_log"; then
    fail "An invalid top-level DMG payload must abort before app validation or installation."
  fi
  if ! assert_detach_contract "$payload_log" '^hdiutil:attach ' device; then
    fail "An invalid top-level DMG payload must detach the parsed mounted device."
  fi
done

invalid_app_cases=(
  wrong-bundle-id
  missing-microphone
  invalid-microphone-type
  apple-events
  extra-entitlement
  no-runtime
  profile
  dangling-profile
  receipt
  dangling-receipt
  app-spctl
  initial-signature
  final-signature
  mutation
)
for invalid_app_case in "${invalid_app_cases[@]}"; do
  run_installer_case "$invalid_app_case" "$invalid_app_case" failure
done
if ! assert_detach_contract "${temp_root}/wrong-bundle-id/commands.log" '^hdiutil:attach '; then
  fail "install.sh must detach the mounted image when app validation fails."
fi
if [[ ! -e "${temp_root}/mutation/mutation-applied" ]]; then
  fail "The mutation case must alter state between initial and final signature verification."
fi

cleanup_mutation_script="${temp_root}/install-without-cleanup.sh"
sed '/^trap cleanup EXIT$/d' "$install_script" >"$cleanup_mutation_script"
chmod +x "$cleanup_mutation_script"
run_installer_case cleanup-mutation valid success "$cleanup_mutation_script"
if assert_detach_contract "${temp_root}/cleanup-mutation/commands.log" \
  '^ditto:.*Inklet\.app .*/Applications/Inklet\.app$'; then
  fail "The detach behavior assertion must reject an installer without its cleanup trap."
fi

echo "install.sh security checks passed."
