#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
verifier="${script_dir}/verify-direct-app.sh"
expected_bundle_id="com.tomwan.inklet.fixture"
test_identity_marker="configured-signing-marker"
test_team_marker="TESTTEAM01"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  echo "$1" >&2
  exit 1
}

assert_safe_output() {
  local output_path="$1"

  if grep -Eq 'Authority=|TeamIdentifier=|Developer ID Application:' "$output_path"; then
    fail "Verifier output must not expose signing metadata."
  fi

  if grep -Fq "$test_identity_marker" "$output_path" ||
    grep -Fq "$test_team_marker" "$output_path"; then
    fail "Verifier output must not expose configured signing values."
  fi
}

assert_generic_failure_output() {
  local output_path="$1"

  assert_safe_output "$output_path"
  if [[ "$(awk 'END { print NR }' "$output_path")" != "1" ]] ||
    ! grep -Eq '^Verification failed: [a-z ]+\.$' "$output_path"; then
    fail "Verifier failure output must be generic for $(basename "$output_path")."
  fi
}

make_app() {
  local destination="$1"
  local bundle_id="${2:-$expected_bundle_id}"
  local executable_name="Fixture"

  mkdir -p "${destination}/Contents/MacOS"
  cp "${repo_root}/StoreSupport/Info.plist" "${destination}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${executable_name}" "${destination}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${bundle_id}" "${destination}/Contents/Info.plist"
  cp /usr/bin/true "${destination}/Contents/MacOS/${executable_name}"
  chmod +x "${destination}/Contents/MacOS/${executable_name}"
}

make_thin_app() {
  local destination="$1"
  local architecture="$2"
  local thin_executable="${temp_dir}/thin-${architecture}"

  make_app "$destination"
  lipo "${destination}/Contents/MacOS/Fixture" -thin "$architecture" -output "$thin_executable"
  mv "$thin_executable" "${destination}/Contents/MacOS/Fixture"
  chmod +x "${destination}/Contents/MacOS/Fixture"
}

sign_app() {
  local app_path="$1"
  local entitlements_path="$2"
  local runtime="${3:-1}"
  local log_path="${temp_dir}/codesign.log"
  local -a arguments=(--force --sign -)

  if [[ "$runtime" == "1" ]]; then
    arguments+=(--options runtime)
  fi
  arguments+=(--entitlements "$entitlements_path" "$app_path")

  if ! codesign "${arguments[@]}" >"$log_path" 2>&1; then
    fail "Could not sign a direct-distribution test fixture."
  fi
}

copy_app() {
  local source="$1"
  local destination="$2"

  ditto "$source" "$destination"
}

expect_verifier_success() {
  local app_path="$1"
  local output_path="${temp_dir}/verifier-success.log"

  if ! env \
    INKLET_SIGN_IDENTITY="$test_identity_marker" \
    APPLE_TEAM_ID="$test_team_marker" \
    "$verifier" "$app_path" "$expected_bundle_id" >"$output_path" 2>&1; then
    fail "Verifier must accept the valid direct-distribution fixture."
  fi
  assert_safe_output "$output_path"
}

expect_verifier_failure() {
  local check_name="$1"
  shift
  local output_path="${temp_dir}/verifier-${check_name}.log"

  if env \
    INKLET_SIGN_IDENTITY="$test_identity_marker" \
    APPLE_TEAM_ID="$test_team_marker" \
    "$verifier" "$@" >"$output_path" 2>&1; then
    fail "Verifier must reject the ${check_name} fixture."
  fi
  assert_generic_failure_output "$output_path"
}

valid_app="${temp_dir}/Valid.app"
make_app "$valid_app"
sign_app "$valid_app" "${repo_root}/StoreSupport/Inklet.entitlements"

if [[ ! -x "$verifier" ]]; then
  fail "verify-direct-app.sh is missing or not executable."
fi

expect_verifier_success "$valid_app"

mutation_app="${temp_dir}/MutationAfterVerification.app"
copy_app "$valid_app" "$mutation_app"
if ! /usr/bin/codesign --verify --deep --strict "$mutation_app" >"${temp_dir}/mutation-initial-signature.log" 2>&1; then
  fail "Mutation fixture must start with a valid overall signature."
fi

mutation_bin="${temp_dir}/mutation-bin"
mkdir -p "$mutation_bin"
cat >"${mutation_bin}/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 4 && "$1" == "--verify" && "$2" == "--deep" && "$3" == "--strict" &&
  ! -e "${TEST_STUB_DIR}/mutation-applied" ]]; then
  if ! /usr/bin/codesign "$@" >"${TEST_STUB_DIR}/mutation-first-verification.log" 2>&1; then
    exit 1
  fi
  if ! plutil -replace CFBundleVersion -string "changed-after-verification" \
    "$4/Contents/Info.plist" >"${TEST_STUB_DIR}/mutation.log" 2>&1; then
    exit 1
  fi
  touch "${TEST_STUB_DIR}/mutation-applied"
  exit 0
fi

exec /usr/bin/codesign "$@"
EOF
chmod +x "${mutation_bin}/codesign"

mutation_output="${temp_dir}/mutation-after-verification.log"
set +e
env \
  PATH="${mutation_bin}:$PATH" \
  TEST_STUB_DIR="$temp_dir" \
  INKLET_SIGN_IDENTITY="$test_identity_marker" \
  APPLE_TEAM_ID="$test_team_marker" \
  "$verifier" "$mutation_app" "$expected_bundle_id" >"$mutation_output" 2>&1
mutation_status=$?
set -e
if /usr/bin/codesign --verify --deep --strict "$mutation_app" >"${temp_dir}/mutation-final-signature.log" 2>&1; then
  fail "Mutation fixture must have an invalid signature after the first verification."
fi
if [[ "$mutation_status" == "0" ]]; then
  fail "Verifier must reject a bundle mutated after its first signature verification."
fi
assert_generic_failure_output "$mutation_output"

mixed_architecture_entitlements="${temp_dir}/mixed-architecture.entitlements"
cp "${repo_root}/StoreSupport/Inklet.entitlements" "$mixed_architecture_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$mixed_architecture_entitlements"

valid_slice_app="${temp_dir}/ValidSlice.app"
make_thin_app "$valid_slice_app" arm64e
sign_app "$valid_slice_app" "${repo_root}/StoreSupport/Inklet.entitlements"

invalid_slice_app="${temp_dir}/InvalidSlice.app"
make_thin_app "$invalid_slice_app" x86_64
sign_app "$invalid_slice_app" "$mixed_architecture_entitlements" 0

mixed_architecture_app="${temp_dir}/MixedArchitecture.app"
copy_app "$valid_slice_app" "$mixed_architecture_app"
lipo -create \
  "${valid_slice_app}/Contents/MacOS/Fixture" \
  "${invalid_slice_app}/Contents/MacOS/Fixture" \
  -output "${temp_dir}/mixed-architecture-executable"
mv "${temp_dir}/mixed-architecture-executable" "${mixed_architecture_app}/Contents/MacOS/Fixture"
chmod +x "${mixed_architecture_app}/Contents/MacOS/Fixture"
if ! codesign --verify --deep --strict "$mixed_architecture_app" >"${temp_dir}/mixed-architecture-signature.log" 2>&1; then
  fail "Mixed-architecture fixture must have a valid overall signature."
fi
expect_verifier_failure "mixed-architecture-contract" "$mixed_architecture_app" "$expected_bundle_id"

sandbox_entitlements="${temp_dir}/sandbox.entitlements"
cp "${repo_root}/StoreSupport/Inklet.entitlements" "$sandbox_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$sandbox_entitlements"
sandbox_app="${temp_dir}/Sandbox.app"
copy_app "$valid_app" "$sandbox_app"
sign_app "$sandbox_app" "$sandbox_entitlements"
expect_verifier_failure "sandbox-entitlement" "$sandbox_app" "$expected_bundle_id"

automation_entitlements="${temp_dir}/automation.entitlements"
cp "${repo_root}/StoreSupport/Inklet.entitlements" "$automation_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.automation.apple-events bool true' "$automation_entitlements"
automation_app="${temp_dir}/Automation.app"
copy_app "$valid_app" "$automation_app"
sign_app "$automation_app" "$automation_entitlements"
expect_verifier_failure "automation-entitlement" "$automation_app" "$expected_bundle_id"

false_audio_entitlements="${temp_dir}/false-audio.entitlements"
cp "${repo_root}/StoreSupport/Inklet.entitlements" "$false_audio_entitlements"
/usr/libexec/PlistBuddy -c 'Set :com.apple.security.device.audio-input false' "$false_audio_entitlements"
false_audio_app="${temp_dir}/FalseAudio.app"
copy_app "$valid_app" "$false_audio_app"
sign_app "$false_audio_app" "$false_audio_entitlements"
expect_verifier_failure "false-audio-entitlement" "$false_audio_app" "$expected_bundle_id"

numeric_audio_entitlements="${temp_dir}/numeric-audio.entitlements"
cp "${repo_root}/StoreSupport/Inklet.entitlements" "$numeric_audio_entitlements"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.device.audio-input' "$numeric_audio_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.device.audio-input integer 1' "$numeric_audio_entitlements"
numeric_audio_app="${temp_dir}/NumericAudio.app"
copy_app "$valid_app" "$numeric_audio_app"
sign_app "$numeric_audio_app" "$numeric_audio_entitlements"
expect_verifier_failure "numeric-audio-entitlement" "$numeric_audio_app" "$expected_bundle_id"

wrong_bundle_app="${temp_dir}/WrongBundle.app"
copy_app "$valid_app" "$wrong_bundle_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.tomwan.inklet.unexpected' "${wrong_bundle_app}/Contents/Info.plist"
sign_app "$wrong_bundle_app" "${repo_root}/StoreSupport/Inklet.entitlements"
expect_verifier_failure "wrong-bundle-identifier" "$wrong_bundle_app" "$expected_bundle_id"

profile_app="${temp_dir}/Profile.app"
copy_app "$valid_app" "$profile_app"
printf 'not a provisioning profile\n' >"${profile_app}/Contents/embedded.provisionprofile"
sign_app "$profile_app" "${repo_root}/StoreSupport/Inklet.entitlements"
expect_verifier_failure "embedded-provisioning-profile" "$profile_app" "$expected_bundle_id"

dangling_profile_app="${temp_dir}/DanglingProfile.app"
copy_app "$valid_app" "$dangling_profile_app"
ln -s "${temp_dir}/missing-profile" "${dangling_profile_app}/Contents/embedded.provisionprofile"
sign_app "$dangling_profile_app" "${repo_root}/StoreSupport/Inklet.entitlements"

signature_bypass_bin="${temp_dir}/signature-bypass-bin"
mkdir -p "$signature_bypass_bin"
cat >"${signature_bypass_bin}/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 4 && "$1" == "--verify" && "$2" == "--deep" && "$3" == "--strict" ]]; then
  exit 0
fi
exec /usr/bin/codesign "$@"
EOF
chmod +x "${signature_bypass_bin}/codesign"

dangling_profile_output="${temp_dir}/dangling-profile.log"
if env \
  PATH="${signature_bypass_bin}:$PATH" \
  INKLET_SIGN_IDENTITY="$test_identity_marker" \
  APPLE_TEAM_ID="$test_team_marker" \
  "$verifier" "$dangling_profile_app" "$expected_bundle_id" >"$dangling_profile_output" 2>&1; then
  fail "Verifier must reject the dangling provisioning profile fixture."
fi
assert_generic_failure_output "$dangling_profile_output"

no_runtime_app="${temp_dir}/NoRuntime.app"
copy_app "$valid_app" "$no_runtime_app"
sign_app "$no_runtime_app" "${repo_root}/StoreSupport/Inklet.entitlements" 0
expect_verifier_failure "missing-hardened-runtime" "$no_runtime_app" "$expected_bundle_id"

no_microphone_app="${temp_dir}/NoMicrophone.app"
copy_app "$valid_app" "$no_microphone_app"
plutil -remove NSMicrophoneUsageDescription "${no_microphone_app}/Contents/Info.plist"
sign_app "$no_microphone_app" "${repo_root}/StoreSupport/Inklet.entitlements"
expect_verifier_failure "missing-microphone-usage" "$no_microphone_app" "$expected_bundle_id"

invalid_microphone_type_app="${temp_dir}/InvalidMicrophoneType.app"
copy_app "$valid_app" "$invalid_microphone_type_app"
plutil -replace NSMicrophoneUsageDescription -json '["Unexpected usage"]' \
  "${invalid_microphone_type_app}/Contents/Info.plist"
sign_app "$invalid_microphone_type_app" "${repo_root}/StoreSupport/Inklet.entitlements"
expect_verifier_failure "invalid-microphone-usage-type" "$invalid_microphone_type_app" "$expected_bundle_id"

apple_events_app="${temp_dir}/AppleEvents.app"
copy_app "$valid_app" "$apple_events_app"
plutil -insert NSAppleEventsUsageDescription -string "Unexpected usage" "${apple_events_app}/Contents/Info.plist"
sign_app "$apple_events_app" "${repo_root}/StoreSupport/Inklet.entitlements"
expect_verifier_failure "apple-events-usage" "$apple_events_app" "$expected_bundle_id"

receipt_app="${temp_dir}/Receipt.app"
copy_app "$valid_app" "$receipt_app"
mkdir -p "${receipt_app}/Contents/_MASReceipt"
printf 'not a receipt\n' >"${receipt_app}/Contents/_MASReceipt/receipt"
sign_app "$receipt_app" "${repo_root}/StoreSupport/Inklet.entitlements"
expect_verifier_failure "app-store-receipt" "$receipt_app" "$expected_bundle_id"

dangling_receipt_app="${temp_dir}/DanglingReceipt.app"
copy_app "$valid_app" "$dangling_receipt_app"
ln -s "${temp_dir}/missing-receipt" "${dangling_receipt_app}/Contents/_MASReceipt"
sign_app "$dangling_receipt_app" "${repo_root}/StoreSupport/Inklet.entitlements"
if ! codesign --verify --deep --strict "$dangling_receipt_app" >"${temp_dir}/dangling-receipt-signature.log" 2>&1; then
  fail "Dangling receipt fixture must have a valid overall signature."
fi
expect_verifier_failure "dangling-app-store-receipt" "$dangling_receipt_app" "$expected_bundle_id"

tampered_app="${temp_dir}/Tampered.app"
copy_app "$valid_app" "$tampered_app"
printf '\0' >>"${tampered_app}/Contents/MacOS/Fixture"
expect_verifier_failure "invalid-signature" "$tampered_app" "$expected_bundle_id"

expect_verifier_failure "missing-app" "${temp_dir}/Missing.app" "$expected_bundle_id"
expect_verifier_failure "invalid-arguments" "$valid_app" "$expected_bundle_id" --unexpected
expect_verifier_failure "non-developer-id-release" "$valid_app" "$expected_bundle_id" --release

release_requirement="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"${test_team_marker}\""
release_requirement_binary="${temp_dir}/release-requirement.bin"
if ! csreq -r "=${release_requirement}" -b "$release_requirement_binary" >"${temp_dir}/csreq.log" 2>&1; then
  fail "The exact release requirement must compile with the system requirement compiler."
fi
if /usr/bin/codesign --verify --deep --strict -R "=${release_requirement}" \
  "$mixed_architecture_app" >"${temp_dir}/adhoc-release-requirement.log" 2>&1; then
  fail "The real Apple anchor requirement must reject an ad-hoc app."
fi

fake_bin="${temp_dir}/fake-bin"
mkdir -p "$fake_bin"
cat >"${fake_bin}/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

architecture=""
requirement=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "--arch" ]]; then
    architecture="$argument"
  elif [[ "$previous" == "-R" ]]; then
    requirement="$argument"
  fi
  previous="$argument"
done

if [[ -n "$requirement" ]]; then
  expected_requirement="=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"${TEST_TEAM_MARKER}\""
  if [[ "$requirement" != "$expected_requirement" ||
    ( "$architecture" != "arm64e" && "$architecture" != "x86_64" ) ]]; then
    exit 1
  fi
  overall_count="$(awk 'END { print NR }' "${TEST_STUB_DIR}/release-policy-overall.log")"
  printf '%s:%s\n' "$overall_count" "$architecture" >>"${TEST_STUB_DIR}/release-policy-architectures.log"
  exit 0
fi

if [[ $# -eq 4 && "$1" == "--verify" && "$2" == "--deep" && "$3" == "--strict" ]]; then
  printf '%s\n' overall >>"${TEST_STUB_DIR}/release-policy-overall.log"
fi

for argument in "$@"; do
  if [[ "$argument" == "--verbose=4" ]]; then
    metadata_path="${TEST_STUB_DIR}/metadata.log"
    if ! /usr/bin/codesign "$@" >"$metadata_path" 2>&1; then
      exit 1
    fi
    sed -E '/^(Authority|TeamIdentifier|Timestamp)=/d' "$metadata_path"
    echo "Authority=Developer ID Application:${TEST_IDENTITY_MARKER}"
    echo "Timestamp=stubbed"
    echo "TeamIdentifier=${TEST_TEAM_MARKER}"
    exit 0
  fi
done

exec /usr/bin/codesign "$@"
EOF
chmod +x "${fake_bin}/codesign"

release_valid_universal_app="${temp_dir}/ReleaseValidUniversal.app"
copy_app "$valid_slice_app" "$release_valid_universal_app"
release_valid_x86_app="${temp_dir}/ReleaseValidX86.app"
make_thin_app "$release_valid_x86_app" x86_64
sign_app "$release_valid_x86_app" "${repo_root}/StoreSupport/Inklet.entitlements"
lipo -create \
  "${valid_slice_app}/Contents/MacOS/Fixture" \
  "${release_valid_x86_app}/Contents/MacOS/Fixture" \
  -output "${temp_dir}/release-valid-universal-executable"
mv "${temp_dir}/release-valid-universal-executable" "${release_valid_universal_app}/Contents/MacOS/Fixture"
chmod +x "${release_valid_universal_app}/Contents/MacOS/Fixture"

release_policy_success_output="${temp_dir}/release-policy-success.log"
if ! env \
  PATH="${fake_bin}:$PATH" \
  TEST_STUB_DIR="$temp_dir" \
  TEST_IDENTITY_MARKER="$test_identity_marker" \
  TEST_TEAM_MARKER="$test_team_marker" \
  APPLE_TEAM_ID="$test_team_marker" \
  "$verifier" "$release_valid_universal_app" "$expected_bundle_id" --release >"$release_policy_success_output" 2>&1; then
  fail "Release verifier must pass only when every architecture receives the exact release requirement."
fi
assert_safe_output "$release_policy_success_output"
if [[ "$(awk 'END { print NR }' "${temp_dir}/release-policy-overall.log")" != "2" ]] ||
  [[ "$(sort "${temp_dir}/release-policy-architectures.log" | paste -sd ' ' -)" != \
    "1:arm64e 1:x86_64 2:arm64e 2:x86_64" ]]; then
  fail "Release verification must reapply the exact requirement after final integrity verification."
fi

invalid_team_output="${temp_dir}/release-invalid-team.log"
if APPLE_TEAM_ID='INVALID" or true' \
  "$verifier" "$valid_app" "$expected_bundle_id" --release >"$invalid_team_output" 2>&1; then
  fail "Release verification must reject unsafe team identifiers."
fi
assert_generic_failure_output "$invalid_team_output"

release_output="${temp_dir}/release-without-team.log"
if env -u APPLE_TEAM_ID "$verifier" "$valid_app" "$expected_bundle_id" --release >"$release_output" 2>&1; then
  fail "Release verification must require a configured team."
fi
assert_generic_failure_output "$release_output"

workspace_failure_output="${temp_dir}/temporary-workspace-failure.log"
if TMPDIR="${temp_dir}/missing-temporary-parent" \
  "$verifier" "$valid_app" "$expected_bundle_id" >"$workspace_failure_output" 2>&1; then
  fail "Verifier must fail when it cannot create a temporary workspace."
fi
assert_generic_failure_output "$workspace_failure_output"

builder="${script_dir}/build-macos-app-bundle.sh"
builder_identity_marker="configured-builder-signing-marker"
builder_failure_output="${temp_dir}/builder-signing-failure.log"
if env \
  INKLET_APP_NAME="Builder Fixture" \
  INKLET_BUNDLE_ID="$expected_bundle_id" \
  INKLET_OUTPUT_DIR="${temp_dir}/builder-output" \
  INKLET_SIGN_IDENTITY="$builder_identity_marker" \
  "$builder" >"$builder_failure_output" 2>&1; then
  fail "build-macos-app-bundle.sh must fail for an unavailable signing identity."
fi
if grep -Fq "$builder_identity_marker" "$builder_failure_output"; then
  fail "build-macos-app-bundle.sh must redact signing failures."
fi
if [[ "$(tail -n 1 "$builder_failure_output")" != "Signing failed." ]]; then
  fail "build-macos-app-bundle.sh must report only a generic signing failure."
fi
assert_safe_output "$builder_failure_output"

if ! grep -Fq 'dist/direct' "$builder"; then
  fail "build-macos-app-bundle.sh must default to the direct output directory."
fi
if ! grep -Eq 'codesign|arguments' "$builder" || ! grep -Fq -- '--options runtime' "$builder"; then
  fail "build-macos-app-bundle.sh must enable Hardened Runtime."
fi
if ! grep -Fq 'INKLET_REQUIRE_TIMESTAMP' "$builder" || ! grep -Fq -- '--timestamp' "$builder"; then
  fail "build-macos-app-bundle.sh must gate secure timestamps explicitly."
fi
if ! grep -Fq 'verify-direct-app.sh' "$builder" || ! grep -Fq -- '--release' "$builder"; then
  fail "build-macos-app-bundle.sh must verify normal and release app bundles."
fi
if grep -Eq 'codesign -d|Entitlements:' "$builder"; then
  fail "build-macos-app-bundle.sh must not dump signature metadata."
fi
if grep -Eq '(echo|printf).*sign_identity|set -x' "$builder"; then
  fail "build-macos-app-bundle.sh must not print signing identities."
fi

echo "Direct distribution checks passed."
