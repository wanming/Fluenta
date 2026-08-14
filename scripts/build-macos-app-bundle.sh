#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
support_dir="${repo_root}/StoreSupport"
app_name="${INKLET_APP_NAME:-Inklet}"
bundle_id="${INKLET_BUNDLE_ID:-com.tomwan.inklet}"
version="${INKLET_VERSION:-0.1.0}"
build_number="${INKLET_BUILD_NUMBER:-$(git -C "$repo_root" rev-list --count HEAD 2>/dev/null || echo 1)}"
sign_identity="${INKLET_SIGN_IDENTITY:--}"
require_timestamp="${INKLET_REQUIRE_TIMESTAMP:-0}"
if [[ ${INKLET_ENTITLEMENTS_PATH+x} ]]; then
  entitlements_path="$INKLET_ENTITLEMENTS_PATH"
else
  entitlements_path="${support_dir}/Inklet.entitlements"
fi
output_dir="${INKLET_OUTPUT_DIR:-${repo_root}/dist/direct}"
app_path="${output_dir}/${app_name}.app"
contents_dir="${app_path}/Contents"
resources_dir="${contents_dir}/Resources"
macos_dir="${contents_dir}/MacOS"

echo "Building ${app_name} release binary..."
swift build --package-path "$repo_root" -c release --product Inklet

bin_dir="$(swift build --package-path "$repo_root" -c release --show-bin-path)"
executable_path="${bin_dir}/Inklet"
resource_bundle_path="${bin_dir}/Inklet_InkletCore.bundle"

if [[ ! -x "$executable_path" ]]; then
  echo "Missing built executable: ${executable_path}" >&2
  exit 1
fi

if [[ ! -d "$resource_bundle_path" ]]; then
  echo "Missing SwiftPM resource bundle: ${resource_bundle_path}" >&2
  exit 1
fi

rm -rf "$app_path"
mkdir -p "$macos_dir" "$resources_dir"

cp "$executable_path" "${macos_dir}/${app_name}"
cp "${support_dir}/Info.plist" "${contents_dir}/Info.plist"
cp "${repo_root}/Assets/AppIcon.icns" "${resources_dir}/AppIcon.icns"
ditto "$resource_bundle_path" "${resources_dir}/Inklet_InkletCore.bundle"
ditto "${support_dir}/InfoPlistStrings" "$resources_dir"

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${app_name}" "${contents_dir}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${bundle_id}" "${contents_dir}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version}" "${contents_dir}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${build_number}" "${contents_dir}/Info.plist"
plutil -lint "${contents_dir}/Info.plist" >/dev/null

echo "Signing ${app_path}..."
codesign_arguments=(--force --sign "$sign_identity" --options runtime)
if [[ "$require_timestamp" == "1" ]]; then
  codesign_arguments+=(--timestamp)
fi
if [[ -n "$entitlements_path" ]]; then
  codesign_arguments+=(--entitlements "$entitlements_path")
fi
if ! signing_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inklet-app-signing.XXXXXX" 2>/dev/null)"; then
  echo "Signing failed." >&2
  exit 1
fi
trap 'rm -rf "$signing_temp_dir" >/dev/null 2>&1' EXIT
if ! codesign "${codesign_arguments[@]}" "$app_path" >"${signing_temp_dir}/codesign.log" 2>&1; then
  echo "Signing failed." >&2
  exit 1
fi

verification_arguments=("$app_path" "$bundle_id")
if [[ "$require_timestamp" == "1" ]]; then
  verification_arguments+=(--release)
fi
"${repo_root}/scripts/verify-direct-app.sh" "${verification_arguments[@]}"

echo "Built ${app_path}"
