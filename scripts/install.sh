#!/usr/bin/env bash
set -euo pipefail

repo="${INKLET_REPO:-wanming/Inklet}"
install_dir="${INKLET_INSTALL_DIR:-/Applications}"
app_name="Inklet.app"
expected_bundle_id="com.tomwan.inklet"
asset_name="${INKLET_ASSET_NAME:-Inklet.dmg}"
api_url="https://api.github.com/repos/${repo}/releases"
auth_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inklet-install.XXXXXX")"
mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/inklet-mount.XXXXXX")"
dmg_path="${tmp_dir}/${asset_name}"
checksum_path="${tmp_dir}/${asset_name}.sha256"
attach_succeeded=0
pending_mount_devices=()

cleanup() {
  if [[ "$attach_succeeded" == "1" ]]; then
    if ((${#pending_mount_devices[@]} > 0)); then
      for ((index = ${#pending_mount_devices[@]} - 1; index >= 0; index -= 1)); do
        hdiutil detach "${pending_mount_devices[index]}" -quiet >/dev/null 2>&1 || true
      done
    else
      hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$tmp_dir" "$mount_dir"
}
trap cleanup EXIT

echo "Downloading Inklet..."

curl_api_args=(-fL --retry 3 --retry-delay 1)
curl_download_args=(-fL --retry 3 --retry-delay 1)
if [[ -n "$auth_token" ]]; then
  curl_api_args+=(
    -H "Authorization: Bearer ${auth_token}"
    -H "Accept: application/vnd.github+json"
  )
  curl_download_args+=(
    -H "Authorization: Bearer ${auth_token}"
    -H "Accept: application/octet-stream"
  )
fi

resolve_asset_url() {
  local requested_asset_name="$1"
  local releases_json
  releases_json="$(curl "${curl_api_args[@]}" "$api_url")"

  if command -v /usr/bin/python3 >/dev/null 2>&1; then
    ASSET_NAME="$requested_asset_name" HAS_AUTH="$([[ -n "$auth_token" ]] && echo 1 || echo 0)" /usr/bin/python3 -c '
import json
import os
import sys

asset_name = os.environ["ASSET_NAME"]
url_key = "url" if os.environ.get("HAS_AUTH") == "1" else "browser_download_url"
for release in json.load(sys.stdin):
    if release.get("draft") or release.get("prerelease"):
        continue
    for asset in release.get("assets", []):
        if asset.get("name") == asset_name:
            print(asset[url_key])
            raise SystemExit(0)
raise SystemExit(1)
' <<<"$releases_json"
    return
  fi

  if command -v /usr/bin/ruby >/dev/null 2>&1; then
    ASSET_NAME="$requested_asset_name" HAS_AUTH="$([[ -n "$auth_token" ]] && echo 1 || echo 0)" /usr/bin/ruby -rjson -e '
asset_name = ENV.fetch("ASSET_NAME")
url_key = ENV["HAS_AUTH"] == "1" ? "url" : "browser_download_url"
JSON.parse(STDIN.read).each do |release|
  next if release["draft"] || release["prerelease"]
  asset = release.fetch("assets", []).find { |candidate| candidate["name"] == asset_name }
  if asset
    puts asset.fetch(url_key)
    exit 0
  end
end
exit 1
' <<<"$releases_json"
    return
  fi

  echo "Could not find python3 or ruby to parse GitHub release metadata." >&2
  return 1
}

dmg_url="$(resolve_asset_url "$asset_name" || true)"
checksum_url="$(resolve_asset_url "${asset_name}.sha256" || true)"

if [[ -z "$dmg_url" ]]; then
  echo "Could not find release asset ${asset_name}." >&2
  exit 1
fi

curl "${curl_download_args[@]}" "$dmg_url" -o "$dmg_path"

if [[ -z "$checksum_url" ]]; then
  echo "Could not find checksum asset ${asset_name}.sha256." >&2
  exit 1
fi

if ! curl "${curl_download_args[@]}" "$checksum_url" -o "$checksum_path" >/dev/null 2>&1; then
  echo "Could not download checksum asset ${asset_name}.sha256." >&2
  exit 1
fi

expected_hash="$(awk 'NR == 1 { print $1 }' "$checksum_path")"
if [[ ! "$expected_hash" =~ ^[[:xdigit:]]{64}$ ]]; then
  echo "Checksum asset ${asset_name}.sha256 is invalid." >&2
  exit 1
fi

actual_hash="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
if [[ "$expected_hash" != "$actual_hash" ]]; then
  echo "Checksum verification failed." >&2
  echo "Expected: $expected_hash" >&2
  echo "Actual:   $actual_hash" >&2
  exit 1
fi
echo "Checksum verified."

echo "Verifying downloaded DMG..."
if ! hdiutil verify "$dmg_path" >"${tmp_dir}/hdiutil-verify.log" 2>&1; then
  echo "DMG structure verification failed." >&2
  exit 1
fi
if ! spctl --assess --type open --context context:primary-signature "$dmg_path" \
  >"${tmp_dir}/dmg-gatekeeper.log" 2>&1; then
  echo "DMG Gatekeeper assessment failed." >&2
  exit 1
fi

echo "Mounting DMG..."
attach_plist="${tmp_dir}/attach.plist"
if ! hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_dir" -plist \
  >"$attach_plist" 2>"${tmp_dir}/attach.log"; then
  echo "Could not mount the downloaded DMG." >&2
  exit 1
fi
attach_succeeded=1

cleanup_devices_path="${tmp_dir}/cleanup-devices.txt"
mount_acceptance_path="${tmp_dir}/mount-acceptance.txt"
mount_metadata_parsed=0
if command -v /usr/bin/python3 >/dev/null 2>&1; then
  if ATTACH_PLIST="$attach_plist" MOUNT_POINT="$mount_dir" \
    CLEANUP_DEVICES="$cleanup_devices_path" MOUNT_ACCEPTANCE="$mount_acceptance_path" \
    /usr/bin/python3 - <<'PY' >"${tmp_dir}/attach-parse-output.log" 2>"${tmp_dir}/attach-parse.log"; then
import os
import plistlib
import re

with open(os.environ["ATTACH_PLIST"], "rb") as attach_file:
    entities = plistlib.load(attach_file).get("system-entities")
mounted_entities = []
if isinstance(entities, list):
    mounted_entities = [
        entity
        for entity in entities
        if isinstance(entity, dict) and "mount-point" in entity
    ]
safe_devices = []
for entity in mounted_entities:
    device = entity.get("dev-entry")
    if (
        isinstance(device, str)
        and re.fullmatch(r"/dev/disk[0-9]+(?:s[0-9]+)*", device) is not None
        and device not in safe_devices
    ):
        safe_devices.append(device)
with open(os.environ["CLEANUP_DEVICES"], "w", encoding="utf-8") as cleanup_file:
    for device in safe_devices:
        cleanup_file.write(device + "\n")
accepted = (
    isinstance(entities, list)
    and len(mounted_entities) == 1
    and mounted_entities[0].get("mount-point") == os.environ["MOUNT_POINT"]
    and len(safe_devices) == 1
    and mounted_entities[0].get("dev-entry") == safe_devices[0]
)
with open(os.environ["MOUNT_ACCEPTANCE"], "w", encoding="utf-8") as acceptance_file:
    acceptance_file.write("accepted\n" if accepted else "rejected\n")
PY
    mount_metadata_parsed=1
  fi
elif command -v /usr/bin/ruby >/dev/null 2>&1; then
  attach_json="${tmp_dir}/attach.json"
  if plutil -convert json -o "$attach_json" "$attach_plist" >"${tmp_dir}/attach-parse.log" 2>&1 &&
    MOUNT_POINT="$mount_dir" CLEANUP_DEVICES="$cleanup_devices_path" \
      MOUNT_ACCEPTANCE="$mount_acceptance_path" /usr/bin/ruby -rjson -e '
data = JSON.parse(STDIN.read)
entities = data["system-entities"]
mounted = entities.is_a?(Array) ? entities.select { |entity| entity.is_a?(Hash) && entity.key?("mount-point") } : []
safe_devices = mounted.map do |entity|
  device = entity["dev-entry"]
  device if device.is_a?(String) && device.match?(%r{\A/dev/disk[0-9]+(?:s[0-9]+)*\z})
end.compact.uniq
File.write(ENV.fetch("CLEANUP_DEVICES"), safe_devices.map { |device| "#{device}\n" }.join)
accepted = entities.is_a?(Array) && mounted.length == 1 &&
  mounted.first["mount-point"] == ENV.fetch("MOUNT_POINT") &&
  safe_devices.length == 1 && mounted.first["dev-entry"] == safe_devices.first
File.write(ENV.fetch("MOUNT_ACCEPTANCE"), accepted ? "accepted\n" : "rejected\n")
' <"$attach_json" >"${tmp_dir}/attach-parse-output.log" 2>>"${tmp_dir}/attach-parse.log"; then
    mount_metadata_parsed=1
  fi
else
  echo "Could not find python3 or ruby to verify mounted device metadata." >&2
  exit 1
fi

pending_mount_devices=()
if [[ -f "$cleanup_devices_path" ]]; then
  while IFS= read -r cleanup_device; do
    if [[ ! "$cleanup_device" =~ ^/dev/disk[0-9]+(s[0-9]+)*$ ]]; then
      mount_metadata_parsed=0
      continue
    fi
    pending_mount_devices+=("$cleanup_device")
  done <"$cleanup_devices_path"
fi
mount_acceptance=""
if [[ -f "$mount_acceptance_path" ]]; then
  mount_acceptance="$(<"$mount_acceptance_path")"
fi
if [[ "$mount_metadata_parsed" != "1" || "$mount_acceptance" != "accepted" ||
  "${#pending_mount_devices[@]}" != "1" ]]; then
  echo "Mounted device verification failed." >&2
  exit 1
fi

source_app="${mount_dir}/${app_name}"
applications_link="${mount_dir}/Applications"
payload_count=0
found_app=0
found_applications=0
while IFS= read -r -d '' payload_entry; do
  payload_count=$((payload_count + 1))
  payload_name="${payload_entry##*/}"
  if [[ "$payload_name" == *$'\n'* || "$payload_name" == *$'\r'* ]]; then
    echo "DMG payload verification failed." >&2
    exit 1
  fi
  case "$payload_name" in
    "$app_name")
      if [[ "$payload_entry" != "$source_app" || ! -d "$payload_entry" || -L "$payload_entry" ]]; then
        echo "DMG payload verification failed." >&2
        exit 1
      fi
      found_app=1
      ;;
    Applications)
      if [[ "$payload_entry" != "$applications_link" || ! -L "$payload_entry" ]]; then
        echo "DMG payload verification failed." >&2
        exit 1
      fi
      found_applications=1
      ;;
    *)
      echo "DMG payload verification failed." >&2
      exit 1
      ;;
  esac
done < <(find "$mount_dir" -mindepth 1 -maxdepth 1 -print0)

applications_target_path="${tmp_dir}/applications-target.txt"
expected_applications_target_path="${tmp_dir}/expected-applications-target.txt"
printf '/Applications\n' >"$expected_applications_target_path"
if [[ "$payload_count" != "2" || "$found_app" != "1" || "$found_applications" != "1" ]] ||
  ! readlink "$applications_link" >"$applications_target_path" 2>"${tmp_dir}/readlink.log" ||
  ! cmp -s "$applications_target_path" "$expected_applications_target_path"; then
  echo "DMG payload verification failed." >&2
  exit 1
fi

if [[ ! -d "$source_app" || -L "$source_app" ||
  ! -f "${source_app}/Contents/Info.plist" ||
  ! -d "${source_app}/Contents/MacOS" ]]; then
  echo "Could not find ${app_name} in the DMG." >&2
  exit 1
fi

verification_fail() {
  echo "Inklet.app verification failed." >&2
  exit 1
}

verify_app_signature() {
  codesign --verify --deep --strict "$source_app" >"${tmp_dir}/app-signature.log" 2>&1
}

echo "Verifying Inklet.app..."
if ! verify_app_signature; then
  verification_fail
fi

info_plist="${source_app}/Contents/Info.plist"
if ! plutil -lint "$info_plist" >"${tmp_dir}/info-plist.log" 2>&1; then
  verification_fail
fi

executable_name_path="${tmp_dir}/bundle-executable.txt"
executable_type_path="${tmp_dir}/bundle-executable-type.txt"
if ! plutil -type CFBundleExecutable "$info_plist" >"$executable_type_path" 2>"${tmp_dir}/plist.log" ||
  [[ "$(<"$executable_type_path")" != "string" ]] ||
  ! plutil -extract CFBundleExecutable raw -o "$executable_name_path" "$info_plist" \
    >"${tmp_dir}/plist.log" 2>&1; then
  verification_fail
fi

executable_name="$(<"$executable_name_path")"
if [[ -z "$executable_name" || "$executable_name" == "." || "$executable_name" == ".." ||
  "$executable_name" == */* || "$executable_name" == *$'\n'* || "$executable_name" == *$'\r'* ]]; then
  verification_fail
fi

main_executable="${source_app}/Contents/MacOS/${executable_name}"
if [[ ! -f "$main_executable" || -L "$main_executable" || ! -x "$main_executable" ]]; then
  verification_fail
fi

bundle_id_path="${tmp_dir}/bundle-id.txt"
if ! plutil -extract CFBundleIdentifier raw -o "$bundle_id_path" "$info_plist" \
  >"${tmp_dir}/plist.log" 2>&1 ||
  [[ "$(<"$bundle_id_path")" != "$expected_bundle_id" ]]; then
  verification_fail
fi

microphone_usage_type_path="${tmp_dir}/microphone-usage-type.txt"
microphone_usage_path="${tmp_dir}/microphone-usage.txt"
if ! plutil -type NSMicrophoneUsageDescription "$info_plist" \
  >"$microphone_usage_type_path" 2>"${tmp_dir}/plist.log" ||
  [[ "$(<"$microphone_usage_type_path")" != "string" ]] ||
  ! plutil -extract NSMicrophoneUsageDescription raw -o "$microphone_usage_path" "$info_plist" \
    >"${tmp_dir}/plist.log" 2>&1 ||
  [[ ! -s "$microphone_usage_path" ]]; then
  verification_fail
fi

if plutil -extract NSAppleEventsUsageDescription raw -o "${tmp_dir}/apple-events-usage.txt" \
  "$info_plist" >"${tmp_dir}/plist.log" 2>&1; then
  verification_fail
fi

if [[ -e "${source_app}/Contents/embedded.provisionprofile" ||
  -L "${source_app}/Contents/embedded.provisionprofile" ||
  -e "${source_app}/Contents/_MASReceipt" ||
  -L "${source_app}/Contents/_MASReceipt" ]]; then
  verification_fail
fi

architectures_path="${tmp_dir}/architectures.txt"
if ! lipo -archs "$main_executable" >"$architectures_path" 2>"${tmp_dir}/architectures.log" ||
  [[ "$(awk 'END { print NR }' "$architectures_path")" != "1" ]] ||
  ! grep -Eq '^[A-Za-z0-9_]+( [A-Za-z0-9_]+)*$' "$architectures_path"; then
  verification_fail
fi
IFS=' ' read -r -a architectures <"$architectures_path"

expected_entitlements="${tmp_dir}/expected-entitlements.plist"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0">' \
  '<dict>' \
  '  <key>com.apple.security.device.audio-input</key>' \
  '  <true/>' \
  '</dict>' \
  '</plist>' >"$expected_entitlements"
expected_entitlements_binary="${tmp_dir}/expected-entitlements.binary.plist"
if ! plutil -convert binary1 -o "$expected_entitlements_binary" "$expected_entitlements" \
  >"${tmp_dir}/plist.log" 2>&1; then
  verification_fail
fi

for architecture in "${architectures[@]}"; do
  entitlements_log="${tmp_dir}/entitlements-${architecture}.log"
  if ! codesign -d --arch "$architecture" --entitlements :- "$source_app" \
    >"$entitlements_log" 2>&1; then
    verification_fail
  fi
  effective_entitlements="${tmp_dir}/effective-entitlements-${architecture}.plist"
  sed -n '/^<?xml /,$p' "$entitlements_log" >"$effective_entitlements"
  effective_entitlements_binary="${tmp_dir}/effective-entitlements-${architecture}.binary.plist"
  if ! plutil -lint "$effective_entitlements" >"${tmp_dir}/plist.log" 2>&1 ||
    ! plutil -convert binary1 -o "$effective_entitlements_binary" "$effective_entitlements" \
      >"${tmp_dir}/plist.log" 2>&1 ||
    ! cmp -s "$effective_entitlements_binary" "$expected_entitlements_binary"; then
    verification_fail
  fi

  signature_details="${tmp_dir}/signature-details-${architecture}.log"
  if ! codesign -d --arch "$architecture" --verbose=4 "$source_app" \
    >"$signature_details" 2>&1; then
    verification_fail
  fi
  flags_value="$(sed -nE 's/^CodeDirectory .* flags=([^ ]+).*/\1/p' "$signature_details" | head -n 1)"
  if [[ "$flags_value" != *"("* || "$flags_value" != *")" ]]; then
    verification_fail
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
    verification_fail
  fi
done

if ! verify_app_signature; then
  verification_fail
fi
if ! spctl --assess --type execute "$source_app" >"${tmp_dir}/app-gatekeeper.log" 2>&1; then
  verification_fail
fi

target_app="${install_dir}/${app_name}"

echo "Installing to ${target_app}..."
osascript -e 'tell application "Inklet" to quit' >/dev/null 2>&1 || true
pkill -x Inklet >/dev/null 2>&1 || true

if [[ -w "$install_dir" ]]; then
  rm -rf "$target_app"
  ditto "$source_app" "$target_app"
else
  if [[ "$target_app" != "/Applications/Inklet.app" ]]; then
    echo "Install directory is not writable." >&2
    exit 1
  fi
  sudo rm -rf "/Applications/Inklet.app"
  sudo ditto "$source_app" "/Applications/Inklet.app"
fi

echo "Inklet installed."
echo "Open it from ${target_app}, then grant Accessibility permission when prompted."
