#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "Verification failed: $1." >&2
  exit 1
}

if [[ $# -ne 2 && $# -ne 3 ]]; then
  fail "arguments"
fi

app_path="$1"
expected_bundle_id="$2"
release_mode=0

if [[ $# -eq 3 ]]; then
  if [[ "$3" != "--release" ]]; then
    fail "arguments"
  fi
  release_mode=1
fi

if [[ -z "$expected_bundle_id" || ! -d "$app_path" || "$app_path" != *.app ||
  ! -f "${app_path}/Contents/Info.plist" || ! -d "${app_path}/Contents/MacOS" ]]; then
  fail "app bundle"
fi

if ! temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inklet-direct-verification.XXXXXX" 2>/dev/null)"; then
  fail "temporary workspace"
fi
trap 'rm -rf "$temp_dir" >/dev/null 2>&1' EXIT

signature_log="${temp_dir}/signature.log"
if ! codesign --verify --deep --strict "$app_path" >"$signature_log" 2>&1; then
  fail "signature"
fi

plist_log="${temp_dir}/plist.log"
info_plist="${app_path}/Contents/Info.plist"
if ! plutil -lint "$info_plist" >"$plist_log" 2>&1; then
  fail "info plist"
fi

bundle_executable_type="${temp_dir}/bundle-executable-type.txt"
bundle_executable_name="${temp_dir}/bundle-executable-name.txt"
if ! plutil -type CFBundleExecutable "$info_plist" >"$bundle_executable_type" 2>"$plist_log" ||
  [[ "$(<"$bundle_executable_type")" != "string" ]] ||
  ! plutil -extract CFBundleExecutable raw -o "$bundle_executable_name" "$info_plist" >"$plist_log" 2>&1; then
  fail "bundle executable"
fi

executable_name="$(<"$bundle_executable_name")"
if [[ -z "$executable_name" || "$executable_name" == "." || "$executable_name" == ".." ||
  "$executable_name" == */* || "$executable_name" == *$'\n'* || "$executable_name" == *$'\r'* ]]; then
  fail "bundle executable"
fi

main_executable="${app_path}/Contents/MacOS/${executable_name}"
if [[ ! -f "$main_executable" || -L "$main_executable" || ! -x "$main_executable" ]]; then
  fail "bundle executable"
fi

architecture_path="${temp_dir}/architectures.txt"
architecture_log="${temp_dir}/architectures.log"
if ! lipo -archs "$main_executable" >"$architecture_path" 2>"$architecture_log" ||
  [[ "$(awk 'END { print NR }' "$architecture_path")" != "1" ]] ||
  ! grep -Eq '^[A-Za-z0-9_]+( [A-Za-z0-9_]+)*$' "$architecture_path"; then
  fail "architectures"
fi
architecture_list="$(<"$architecture_path")"
IFS=' ' read -r -a architectures <<<"$architecture_list"

bundle_id_path="${temp_dir}/bundle-id.txt"
if ! plutil -extract CFBundleIdentifier raw -o "$bundle_id_path" "$info_plist" >"$plist_log" 2>&1 ||
  [[ "$(<"$bundle_id_path")" != "$expected_bundle_id" ]]; then
  fail "bundle identifier"
fi

microphone_usage_path="${temp_dir}/microphone-usage.txt"
microphone_usage_type_path="${temp_dir}/microphone-usage-type.txt"
if ! plutil -type NSMicrophoneUsageDescription "$info_plist" >"$microphone_usage_type_path" 2>"$plist_log" ||
  [[ "$(<"$microphone_usage_type_path")" != "string" ]] ||
  ! plutil -extract NSMicrophoneUsageDescription raw -o "$microphone_usage_path" "$info_plist" >"$plist_log" 2>&1 ||
  [[ ! -s "$microphone_usage_path" ]]; then
  fail "microphone usage"
fi

apple_events_usage_path="${temp_dir}/apple-events-usage.txt"
if plutil -extract NSAppleEventsUsageDescription raw -o "$apple_events_usage_path" "$info_plist" >"$plist_log" 2>&1; then
  fail "apple events usage"
fi

if [[ -e "${app_path}/Contents/embedded.provisionprofile" ||
  -L "${app_path}/Contents/embedded.provisionprofile" ]]; then
  fail "provisioning profile"
fi

if [[ -e "${app_path}/Contents/_MASReceipt" || -L "${app_path}/Contents/_MASReceipt" ]]; then
  fail "app store receipt"
fi

if [[ "$release_mode" == "1" ]]; then
  if [[ ! "${APPLE_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]]; then
    fail "release team"
  fi
  release_requirement="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"${APPLE_TEAM_ID}\""
fi

expected_entitlements="${temp_dir}/expected-entitlements.plist"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0">' \
  '<dict>' \
  '  <key>com.apple.security.device.audio-input</key>' \
  '  <true/>' \
  '</dict>' \
  '</plist>' >"$expected_entitlements"
expected_binary="${temp_dir}/expected-entitlements.binary.plist"
if ! plutil -convert binary1 -o "$expected_binary" "$expected_entitlements" >"$plist_log" 2>&1; then
  fail "entitlement allowlist"
fi

for architecture in "${architectures[@]}"; do
  entitlements_log="${temp_dir}/entitlements-${architecture}.log"
  if ! codesign -d --arch "$architecture" --entitlements :- "$app_path" >"$entitlements_log" 2>&1; then
    fail "entitlements"
  fi

  entitlements_path="${temp_dir}/effective-entitlements-${architecture}.plist"
  sed -n '/^<?xml /,$p' "$entitlements_log" >"$entitlements_path"
  if ! plutil -lint "$entitlements_path" >"$plist_log" 2>&1; then
    fail "entitlements"
  fi

  effective_binary="${temp_dir}/effective-entitlements-${architecture}.binary.plist"
  if ! plutil -convert binary1 -o "$effective_binary" "$entitlements_path" >"$plist_log" 2>&1 ||
    ! cmp -s "$effective_binary" "$expected_binary"; then
    fail "entitlement allowlist"
  fi

  signature_details="${temp_dir}/signature-details-${architecture}.log"
  if ! codesign -d --arch "$architecture" --verbose=4 "$app_path" >"$signature_details" 2>&1; then
    fail "signature metadata"
  fi

  flags_value="$(sed -nE 's/^CodeDirectory .* flags=([^ ]+).*/\1/p' "$signature_details" | head -n 1)"
  if [[ "$flags_value" != *"("* || "$flags_value" != *")" ]]; then
    fail "hardened runtime"
  fi

  flag_names="${flags_value#*(}"
  flag_names="${flag_names%)*}"
  runtime_found=0
  IFS=',' read -r -a parsed_flags <<<"$flag_names"
  for flag_name in "${parsed_flags[@]}"; do
    if [[ "$flag_name" == "runtime" ]]; then
      runtime_found=1
    fi
  done
  if [[ "$runtime_found" != "1" ]]; then
    fail "hardened runtime"
  fi

  if [[ "$release_mode" == "1" ]]; then
    release_requirement_log="${temp_dir}/release-requirement-${architecture}.log"
    if ! codesign --verify --deep --strict --arch "$architecture" -R "=${release_requirement}" "$app_path" >"$release_requirement_log" 2>&1; then
      fail "release authority"
    fi

    if ! grep -q '^Authority=Developer ID Application:' "$signature_details"; then
      fail "release authority"
    fi

    if ! grep -q '^Timestamp=' "$signature_details"; then
      fail "secure timestamp"
    fi

    discovered_team="$(sed -n 's/^TeamIdentifier=//p' "$signature_details")"
    if [[ -z "$discovered_team" || "$discovered_team" != "$APPLE_TEAM_ID" ]]; then
      fail "release team"
    fi
  fi
done

final_signature_log="${temp_dir}/final-signature.log"
if ! codesign --verify --deep --strict "$app_path" >"$final_signature_log" 2>&1; then
  fail "signature"
fi

if [[ "$release_mode" == "1" ]]; then
  for architecture in "${architectures[@]}"; do
    final_release_requirement_log="${temp_dir}/final-release-requirement-${architecture}.log"
    if ! codesign --verify --deep --strict --arch "$architecture" -R "=${release_requirement}" \
      "$app_path" >"$final_release_requirement_log" 2>&1; then
      fail "release authority"
    fi
  done
fi

echo "Direct app verification passed."
