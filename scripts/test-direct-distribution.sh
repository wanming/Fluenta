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

retired_scripts=(
  "build-app-store-release.sh"
  "build-app-store-spike.sh"
  "rebuild-sandbox-app.sh"
)
for retired_script in "${retired_scripts[@]}"; do
  if [[ -e "${script_dir}/${retired_script}" ]]; then
    fail "${retired_script} must be retired."
  fi
done

active_contract_files=(
  "${script_dir}/README.md"
  "${repo_root}/.env.local.example"
  "${repo_root}/.gitignore"
)
for active_script in "${script_dir}"/*.sh; do
  case "$(basename "$active_script")" in
    test-*.sh)
      continue
      ;;
  esac
  active_contract_files+=("$active_script")
done

retired_names=(
  "app-store-spike"
  "build-app-store"
  "rebuild-sandbox"
  "INKLET_APP_STORE_"
  "ASC_EMAIL"
  "ASC_PASSWORD"
)
for retired_name in "${retired_names[@]}"; do
  if grep -Fiq -- "$retired_name" "${active_contract_files[@]}"; then
    fail "Active tooling and documentation must not reference ${retired_name}."
  fi
done

public_documentation_files=(
  "${repo_root}/README.md"
  "${repo_root}/README.zh-CN.md"
  "${repo_root}/CONTRIBUTING.md"
  "${repo_root}/docs/privacy-policy.md"
  "${repo_root}/docs/manual-test-checklist.md"
  "${repo_root}/SECURITY.md"
)
active_guidance_files=(
  "${public_documentation_files[@]}"
  "${script_dir}/README.md"
  "${repo_root}/.github/workflows/build-dmg.yml"
)
active_guidance_files+=("${active_contract_files[@]}")

documentation_contract_failures=()

record_documentation_failure() {
  documentation_contract_failures+=("$1")
}

reject_active_guidance_text() {
  local stale_text="$1"
  local description="$2"

  if grep -Fiq -- "$stale_text" "${active_guidance_files[@]}"; then
    record_documentation_failure "Active guidance must not contain ${description}."
  fi
}

reject_active_guidance_pattern() {
  local stale_pattern="$1"
  local description="$2"

  if grep -Eiq -- "$stale_pattern" "${active_guidance_files[@]}"; then
    record_documentation_failure "Active guidance must not contain ${description}."
  fi
}

reject_active_guidance_text "Mac App Store" "Mac App Store release guidance"
reject_active_guidance_text "window.getSelection" "browser window-selection instructions"
reject_active_guidance_text "Allow JavaScript from Apple Events" "Chrome JavaScript setup"
reject_active_guidance_text "browser JavaScript" "browser JavaScript selection claims"
reject_active_guidance_text "per-browser permission" "per-browser permission setup"
reject_active_guidance_text "Automation setup" "Automation setup instructions"
reject_active_guidance_text "Voice Write Assistant" "the retired standalone Voice Write Assistant"
reject_active_guidance_text "Voice Recording Mode" "retired voice recording modes"
reject_active_guidance_text "tap-to-toggle" "tap-to-toggle dictation"
reject_active_guidance_text "double-tap recording" "double-tap dictation"
reject_active_guidance_text "compact voice window" "the retired voice status window"
reject_active_guidance_text "Auto Process" "retired automatic voice processing"
reject_active_guidance_text "语音写作助手" "已移除的独立语音写作助手"
reject_active_guidance_text "单击开始/停止" "已移除的单击切换录音"
reject_active_guidance_text "双击开始/停止" "已移除的双击切换录音"
reject_active_guidance_text \
  "Selected text is kept in memory while the floating action is active" \
  "the obsolete selection-memory lifetime claim"
reject_active_guidance_pattern \
  '(grant|enable|turn on|allow|configure)[^.!]*(browser|Chrome|Safari|Edge)[^.!]*Automation' \
  "browser Automation setup instructions"
reject_active_guidance_text "swift run Inklet" "swift run Inklet as a QA workflow"
for retired_script in "${retired_scripts[@]}"; do
  reject_active_guidance_text "$retired_script" "obsolete script ${retired_script}"
done

markdown_prose_path() {
  local document_path="$1"
  local path_key

  path_key="$(printf '%s' "$document_path" | tr '/ ' '__')"
  printf '%s/documentation-prose-%s\n' "$temp_dir" "$path_key"
}

extract_markdown_prose() {
  local document_path="$1"
  local prose_path

  prose_path="$(markdown_prose_path "$document_path")"
  /usr/bin/ruby - "$document_path" >"$prose_path" <<'RUBY'
path = ARGV.fetch(0)
fence_character = nil
fence_length = 0
in_comment = false
in_indented_code = false
can_start_indented_code = true

def leading_indentation_columns(line)
  columns = 0
  line.each_char do |character|
    case character
    when " "
      columns += 1
    when "\t"
      columns += 4 - (columns % 4)
    else
      break
    end
  end
  columns
end

File.foreach(path, chomp: true) do |line|
  if fence_character
    closing_fence = Regexp.new(
      "\\A {0,3}#{Regexp.escape(fence_character)}{#{fence_length},}[ \\t]*\\z"
    )
    if line.match?(closing_fence)
      fence_character = nil
      fence_length = 0
    end
    next
  end

  unless in_comment
    if in_indented_code
      if line.strip.empty? || leading_indentation_columns(line) >= 4
        next
      end
      in_indented_code = false
    end

    if line.strip.empty?
      can_start_indented_code = true
      next
    end

    # The public-guidance contract handles top-level indented code. A four-column
    # indent cannot interrupt a paragraph, so only document start or a blank line
    # permits this block state.
    if can_start_indented_code && leading_indentation_columns(line) >= 4
      in_indented_code = true
      can_start_indented_code = false
      next
    end
    can_start_indented_code = false

    if (opening_fence = line.match(/\A {0,3}(`{3,}|~{3,})(.*)\z/))
      marker = opening_fence[1]
      info_string = opening_fence[2]
      unless marker[0] == "`" && info_string.include?("`")
        fence_character = marker[0]
        fence_length = marker.length
        next
      end
    end
  end

  text = line.dup
  loop do
    if in_comment
      comment_end = text.index("-->")
      unless comment_end
        text = ""
        break
      end
      text = text[(comment_end + 3), text.length] || ""
      in_comment = false
      next
    end

    comment_start = text.index("<!--")
    break unless comment_start

    prefix = text[0, comment_start] || ""
    remainder = text[(comment_start + 4), text.length] || ""
    comment_end = remainder.index("-->")
    if comment_end
      text = prefix + (remainder[(comment_end + 3), remainder.length] || "")
    else
      text = prefix
      in_comment = true
      break
    end
  end

  puts text unless text.strip.empty?
end
RUBY
}

fence_fixture="${temp_dir}/documentation-fence-fixture.md"
cat >"$fence_fixture" <<'EOF'
visible before tilde fence
~~~text
GitHub Releases is Inklet's only supported distribution channel
~~~
visible after tilde fence

````markdown
hidden before shorter backtick marker
~~~
hidden after mixed fence marker
```
hidden after shorter backtick marker
`````
visible after longer backtick close
EOF
extract_markdown_prose "$fence_fixture"
fence_fixture_prose="$(markdown_prose_path "$fence_fixture")"
for hidden_fence_text in \
  "GitHub Releases is Inklet's only supported distribution channel" \
  "hidden before shorter backtick marker" \
  "hidden after mixed fence marker" \
  "hidden after shorter backtick marker"; do
  if grep -Fq -- "$hidden_fence_text" "$fence_fixture_prose"; then
    record_documentation_failure \
      "Markdown prose extraction must exclude CommonMark fenced code contents."
    break
  fi
done
for visible_fence_text in \
  "visible before tilde fence" \
  "visible after tilde fence" \
  "visible after longer backtick close"; do
  if ! grep -Fq -- "$visible_fence_text" "$fence_fixture_prose"; then
    record_documentation_failure \
      "Markdown prose extraction must resume after a valid closing fence."
    break
  fi
done

marker_info_fence_fixture="${temp_dir}/documentation-marker-info-fence-fixture.md"
cat >"$marker_info_fence_fixture" <<'EOF'
```~~~text
hidden in backtick fence with tilde-prefixed info
```
visible after backtick fence with tilde-prefixed info
~~~```text
hidden in tilde fence with backtick-prefixed info
~~~
visible after tilde fence with backtick-prefixed info
EOF
extract_markdown_prose "$marker_info_fence_fixture"
marker_info_fence_prose="$(markdown_prose_path "$marker_info_fence_fixture")"
for hidden_marker_info_text in \
  "hidden in backtick fence with tilde-prefixed info" \
  "hidden in tilde fence with backtick-prefixed info"; do
  if grep -Fq -- "$hidden_marker_info_text" "$marker_info_fence_prose"; then
    record_documentation_failure \
      "Markdown prose extraction must accept marker-prefixed CommonMark fence info strings."
    break
  fi
done
for visible_marker_info_text in \
  "visible after backtick fence with tilde-prefixed info" \
  "visible after tilde fence with backtick-prefixed info"; do
  if ! grep -Fq -- "$visible_marker_info_text" "$marker_info_fence_prose"; then
    record_documentation_failure \
      "Markdown prose extraction must close marker-prefixed info fences correctly."
    break
  fi
done

invalid_backtick_info_fixture="${temp_dir}/documentation-invalid-backtick-info-fixture.md"
cat >"$invalid_backtick_info_fixture" <<'EOF'
```lang`bad
visible after invalid backtick fence info
EOF
extract_markdown_prose "$invalid_backtick_info_fixture"
invalid_backtick_info_prose="$(markdown_prose_path "$invalid_backtick_info_fixture")"
for invalid_backtick_info_text in \
  '```lang`bad' \
  "visible after invalid backtick fence info"; do
  if ! grep -Fq -- "$invalid_backtick_info_text" "$invalid_backtick_info_prose"; then
    record_documentation_failure \
      "Markdown prose extraction must preserve a backtick fence line whose info contains a backtick."
    break
  fi
done

indented_code_fixture="${temp_dir}/documentation-indented-code-fixture.md"
printf '%s\n' \
  "    GitHub Releases is Inklet's only supported distribution channel" \
  "    hidden second space-indented code line" \
  "" \
  "    hidden space-indented code after internal blank" \
  "visible after space-indented code" \
  "" \
  $'\tGitHub Releases is Inklet\047s only supported distribution channel' \
  $'\thidden second tab-indented code line' \
  "" \
  $'\thidden tab-indented code after internal blank' \
  "visible after tab-indented code" \
  "paragraph continues directly" \
  "    visible indented paragraph continuation" \
  >"$indented_code_fixture"
extract_markdown_prose "$indented_code_fixture"
indented_code_prose="$(markdown_prose_path "$indented_code_fixture")"
for hidden_indented_code_text in \
  "GitHub Releases is Inklet's only supported distribution channel" \
  "hidden second space-indented code line" \
  "hidden space-indented code after internal blank" \
  "hidden second tab-indented code line" \
  "hidden tab-indented code after internal blank"; do
  if grep -Fq -- "$hidden_indented_code_text" "$indented_code_prose"; then
    record_documentation_failure \
      "Markdown prose extraction must exclude top-level CommonMark indented code blocks."
    break
  fi
done
for visible_after_indented_code_text in \
  "visible after space-indented code" \
  "visible after tab-indented code" \
  "paragraph continues directly" \
  "visible indented paragraph continuation"; do
  if ! grep -Fq -- "$visible_after_indented_code_text" "$indented_code_prose"; then
    record_documentation_failure \
      "Markdown prose extraction must preserve prose around top-level indented code blocks."
    break
  fi
done

require_documentation_prose() {
  local document_path="$1"
  local required_text="$2"
  local description="$3"
  local prose_path

  prose_path="$(markdown_prose_path "$document_path")"
  if ! grep -Fiq -- "$required_text" "$prose_path"; then
    record_documentation_failure "$(basename "$document_path") must document ${description}."
  fi
}

for documentation_file in "${public_documentation_files[@]}"; do
  extract_markdown_prose "$documentation_file"
done

english_readme="${repo_root}/README.md"
require_documentation_prose "$english_readme" \
  "GitHub Releases is Inklet's only supported distribution channel" \
  "GitHub Releases as the sole distribution channel"
require_documentation_prose "$english_readme" \
  "signed and notarized DMG" \
  "the signed and notarized DMG"
require_documentation_prose "$english_readme" \
  "install script" \
  "the verified installer workflow"
require_documentation_prose "$english_readme" \
  "Accessibility-first" \
  "the generic Accessibility-first selection path"
require_documentation_prose "$english_readme" \
  "configured temporary clipboard fallback" \
  "the configured temporary clipboard fallback"
require_documentation_prose "$english_readme" \
  "captured source process" \
  "source-process validation and cancellation"
require_documentation_prose "$english_readme" \
  "newer clipboard contents win" \
  "conditional clipboard restoration"
require_documentation_prose "$english_readme" \
  "double-copy trigger is passive" \
  "the passive double-copy trigger"
require_documentation_prose "$english_readme" \
  "Right-click remains native" \
  "native right-click behavior"
require_documentation_prose "$english_readme" \
  "does not request browser Automation" \
  "the absence of browser Automation"
require_documentation_prose "$english_readme" \
  "~/Library/Application Support/com.tomwan.inklet/" \
  "the production bundle-qualified Application Support root"
require_documentation_prose "$english_readme" \
  "~/Library/Application Support/com.tomwan.inklet.local/" \
  "the local bundle-qualified Application Support root"
require_documentation_prose "$english_readme" \
  "automatically copies recognized legacy preferences" \
  "automatic recognized-data migration"
require_documentation_prose "$english_readme" \
  "does not delete or modify the legacy source" \
  "copy-not-delete legacy migration"
require_documentation_prose "$english_readme" \
  "Import Old Data" \
  "the Settings assisted-import fallback"
for dictation_text in \
  "Open Writing Assistant" \
  "Confirm a Prompt Mode" \
  "Hold the configured Dictation shortcut" \
  "Release to finalize" \
  "Press Return only when ready" \
  "A short press does nothing." \
  "does not run the Prompt Mode or insert text into another app"; do
  require_documentation_prose "$english_readme" "$dictation_text" "$dictation_text"
done
for dictation_step in \
  '1. **Open Writing Assistant**' \
  '2. **Confirm a Prompt Mode**' \
  '3. **Put the caret in the source draft, or select text to replace.**' \
  '4. **Hold the configured Dictation shortcut**' \
  '5. **Release to finalize**' \
  '6. Review and edit the dictated draft.' \
  '7. **Press Return only when ready**' \
  'Dictation inserts at the caret or replaces the selection.'; do
  require_documentation_prose "$english_readme" "$dictation_step" "$dictation_step"
done

chinese_readme="${repo_root}/README.zh-CN.md"
require_documentation_prose "$chinese_readme" \
  "GitHub Releases 是 Inklet 唯一支持的发布渠道" \
  "GitHub Releases 作为唯一发布渠道"
require_documentation_prose "$chinese_readme" \
  "已签名并完成 Apple 公证的 DMG" \
  "已签名和公证的 DMG"
require_documentation_prose "$chinese_readme" \
  "安装脚本" \
  "已验证的安装脚本流程"
require_documentation_prose "$chinese_readme" \
  "Accessibility 优先" \
  "通用的 Accessibility 优先选区流程"
require_documentation_prose "$chinese_readme" \
  "按设置启用的临时剪贴板备用读取" \
  "按设置启用的临时剪贴板备用流程"
require_documentation_prose "$chinese_readme" \
  "捕获的来源进程" \
  "来源进程验证和取消"
require_documentation_prose "$chinese_readme" \
  "较新的剪贴板内容优先" \
  "有条件的剪贴板恢复"
require_documentation_prose "$chinese_readme" \
  "双击复制触发是被动流程" \
  "被动的双击复制触发"
require_documentation_prose "$chinese_readme" \
  "右键点击保留原生行为" \
  "原生右键行为"
require_documentation_prose "$chinese_readme" \
  "不会请求浏览器 Automation" \
  "不需要浏览器 Automation"
require_documentation_prose "$chinese_readme" \
  "~/Library/Application Support/com.tomwan.inklet/" \
  "正式版按 bundle 隔离的 Application Support 根目录"
require_documentation_prose "$chinese_readme" \
  "~/Library/Application Support/com.tomwan.inklet.local/" \
  "本地版按 bundle 隔离的 Application Support 根目录"
require_documentation_prose "$chinese_readme" \
  "自动复制已识别的旧版偏好设置" \
  "自动迁移已识别的数据"
require_documentation_prose "$chinese_readme" \
  "不会删除或修改旧版来源" \
  "复制而不删除的旧版迁移"
require_documentation_prose "$chinese_readme" \
  "导入旧数据" \
  "Settings 中的辅助导入备用流程"
for dictation_text in \
  "打开写作助手" \
  "确认一个 Prompt 模式" \
  "长按已配置的听写快捷键" \
  "松开以完成转写" \
  "准备好后再按 Return" \
  "短按不会执行任何操作" \
  "不会运行 Prompt 模式，也不会把文本插入其他 App"; do
  require_documentation_prose "$chinese_readme" "$dictation_text" "$dictation_text"
done
for dictation_step in \
  '1. 用 `Option+Space` **打开写作助手**' \
  '2. **确认一个 Prompt 模式**' \
  '3. **把光标放入原文草稿，或选中要替换的文本。**' \
  '4. **长按已配置的听写快捷键**' \
  '5. **松开以完成转写**' \
  '6. 检查并编辑听写草稿。' \
  '7. **准备好后再按 Return**' \
  '听写会在光标处插入，或替换选区。'; do
  require_documentation_prose "$chinese_readme" "$dictation_step" "$dictation_step"
done

contributing="${repo_root}/CONTRIBUTING.md"
require_documentation_prose "$contributing" \
  "scripts/run-local-app.sh" \
  "the stable routine local-app workflow"
require_documentation_prose "$contributing" \
  "/Applications/Inklet Local.app" \
  "the stable installed local app"
require_documentation_prose "$contributing" \
  "Do not use an ad-hoc-signed or worktree-local app for routine QA" \
  "the routine-QA signing and path restriction"
require_documentation_prose "$contributing" \
  ".github/workflows/build-dmg.yml" \
  "the direct release workflow"
require_documentation_prose "$contributing" \
  "scripts/README.md" \
  "the distribution-script reference"

privacy_policy="${repo_root}/docs/privacy-policy.md"
privacy_update_lines="$(grep -E '^Last updated:' "$privacy_policy" || true)"
if [[ "$privacy_update_lines" != "Last updated: August 30, 2026" ]]; then
  record_documentation_failure \
    "privacy-policy.md must contain exactly one current policy date: Last updated: August 30, 2026."
fi
for privacy_text in \
  "~/Library/Application Support/com.tomwan.inklet/" \
  "~/Library/Application Support/com.tomwan.inklet.local/" \
  "~/Library/Preferences/com.tomwan.inklet.plist" \
  "~/Library/Preferences/com.tomwan.inklet.local.plist" \
  'InkletSelectionActions.<bundle-identifier>.log' \
  "Inklet.ProviderAPIKey" \
  "Inklet.Local.ProviderAPIKey" \
  "history.jsonl" \
  "selection-translation-cache.json" \
  "does not delete or modify the legacy source" \
  "does not save a persistent bookmark" \
  "newer clipboard contents win" \
  "does not request Automation permission" \
  "Mere selection or copying does not persist text to disk." \
  "A selection result may remain in process memory as Inklet's current selection state until it is replaced or cleared, or until Inklet exits." \
  "Only successful Selection actions are saved in local History; successful translations may also be stored in the 7-day local translation cache." \
  "Accessibility" \
  "Microphone" \
  "Active microphone audio is streamed to OpenAI's Realtime transcription service as it is captured." \
  'one temporary local `.m4a` recovery recording' \
  "only to the one file-transcription recovery attempt" \
  "does not log audio or transcript content, Authorization headers, microphone identifiers, or temporary file paths" \
  "Audio is never placed on the clipboard or stored in History." \
  "An unprocessed dictated draft creates no History entry." \
  "Existing legacy Voice entries remain locally readable." \
  "Microphone permission is distinct from Accessibility permission" \
  "finishing dictation does not insert text into another app" \
  "models.dev"; do
  require_documentation_prose "$privacy_policy" "$privacy_text" "${privacy_text}"
done

security_policy="${repo_root}/SECURITY.md"
for security_text in \
  "Keychain" \
  "bundle-qualified storage" \
  "legacy migration" \
  "captured source process" \
  "clipboard transaction serialization" \
  "conditional clipboard restoration" \
  "Realtime transport authentication" \
  "bounded in-memory PCM" \
  "terminal-session arbitration" \
  "temporary recovery-file deletion" \
  "audio payloads, transcript contents, Authorization headers, microphone identifiers, or temporary file paths" \
  "signed and notarized direct releases" \
  "release verifier"; do
  require_documentation_prose "$security_policy" "$security_text" "${security_text}"
done

manual_checklist="${repo_root}/docs/manual-test-checklist.md"
for checklist_text in \
  "This checklist defines required manual verification; it does not claim that any item has been run." \
  "scripts/run-local-app.sh" \
  "/Applications/Inklet Local.app" \
  "fresh install" \
  "signed in-place upgrade" \
  "automatic migration" \
  "assisted import" \
  "legacy source remains unchanged" \
  "idempotent" \
  "production and local builds concurrently" \
  "settings, History, translation cache, diagnostics, defaults, and Keychain" \
  "Accessibility trust" \
  "Keychain access" \
  "Deny Accessibility" \
  "Deny Microphone" \
  "macOS 14.x" \
  "macOS 15.x" \
  "macOS 26.x" \
  "Chrome, Safari, Edge, and a native AppKit text view" \
  "drag selection" \
  "double-click" \
  "triple-click" \
  "Shift-modified keyboard selection" \
  "double-copy" \
  "right-click" \
  "protected" \
  "focus change" \
  "clipboard race" \
  "No browser Automation prompt" \
  "hdiutil verify" \
  "stapler validate" \
  "Gatekeeper" \
  "effective entitlements" \
  "first valid dictation hold" \
  "mode picker and result editor" \
  "modifier already held" \
  "combining marks" \
  "one-step undo" \
  "marked-text Escape" \
  "connection failure while held" \
  "late-event races" \
  "permission is not requested" \
  "rapid reopen" \
  "no draft-only History" \
  "legacy Voice History" \
  "phase-only announcements" \
  "rebuild and reinstall the local app twice"; do
  require_documentation_prose "$manual_checklist" "$checklist_text" "${checklist_text}"
done

if ((${#documentation_contract_failures[@]} > 0)); then
  printf 'Documentation contract failures:\n' >&2
  printf '  - %s\n' "${documentation_contract_failures[@]}" >&2
  fail "Active public documentation does not satisfy the direct-distribution contract."
fi

expected_local_signing_setting='INKLET_LOCAL_SIGN_IDENTITY="<code-signing-identity-hash>"'
configured_example_lines="$(grep -Ev '^[[:space:]]*(#|$)' "${repo_root}/.env.local.example" || true)"
if [[ "$configured_example_lines" != "$expected_local_signing_setting" ]]; then
  fail ".env.local.example must contain only the local signing identity setting and comments."
fi

for stale_ignore in docs/app-store-submission.md docs/mac-app-store-spike.md; do
  if grep -Fxq "$stale_ignore" "${repo_root}/.gitignore"; then
    fail ".gitignore must not retain ${stale_ignore}."
  fi
done

ignored_private_paths=(
  ".private/example"
  ".env.local"
  "example.p8"
  "example.p12"
  "example.mobileprovision"
  "example.provisionprofile"
)
for ignored_private_path in "${ignored_private_paths[@]}"; do
  if ! git -C "$repo_root" check-ignore -q --no-index "$ignored_private_path"; then
    fail ".gitignore must keep ${ignored_private_path} ignored."
  fi
done

documented_scripts=(
  "build-macos-app-bundle.sh"
  "install.sh"
  "reset-local-state.sh"
  "run-local-app.sh"
  "verify-direct-app.sh"
)
for documented_script in "${documented_scripts[@]}"; do
  if ! grep -Fq -- "$documented_script" "${script_dir}/README.md"; then
    fail "scripts/README.md must document ${documented_script}."
  fi
done
if ! grep -Fq -- '--scope local|production|all' "${script_dir}/README.md"; then
  fail "scripts/README.md must document the destructive reset scopes."
fi

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

workflow="${repo_root}/.github/workflows/build-dmg.yml"
check_workflow_semantics() {
  local workflow_path="$1"

  /usr/bin/ruby -ryaml - "$workflow_path" <<'RUBY'
path = ARGV.fetch(0)
workflow = YAML.safe_load(File.read(path), [], [], true, path)
steps = workflow.fetch("jobs").fetch("build-dmg").fetch("steps")

def require_contract(condition, message)
  raise message unless condition
end

def named_step(steps, name)
  matches = steps.each_with_index.select { |step, _index| step["name"] == name }
  require_contract(matches.length == 1, "missing or duplicate step: #{name}")
  matches.first
end

def active_run(run)
  run.lines.reject { |line| line.strip.empty? || line.lstrip.start_with?("#") }.join
end

identity_step, identity_index = named_step(steps, "Import Developer ID certificate")
build_step, build_index = named_step(steps, "Build and verify release app")
final_step, final_index = named_step(steps, "Create and verify final DMG")

expected_identity_env = {
  "APPLE_DEVELOPER_ID_CERTIFICATE_BASE64" => "${{ secrets.APPLE_DEVELOPER_ID_CERTIFICATE_BASE64 }}",
  "APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD" => "${{ secrets.APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD }}",
  "APPLE_TEAM_ID" => "${{ secrets.APPLE_TEAM_ID }}"
}
expected_build_env = {
  "INKLET_APP_NAME" => "Inklet",
  "INKLET_BUNDLE_ID" => "com.tomwan.inklet",
  "INKLET_VERSION" => "${{ steps.release.outputs.app_version }}",
  "INKLET_BUILD_NUMBER" => "${{ steps.release.outputs.build_number }}",
  "INKLET_OUTPUT_DIR" => "dist/release",
  "INKLET_REQUIRE_TIMESTAMP" => "1",
  "APPLE_TEAM_ID" => "${{ secrets.APPLE_TEAM_ID }}"
}
expected_final_env = {
  "APP_STORE_CONNECT_API_KEY_ID" => "${{ secrets.APP_STORE_CONNECT_API_KEY_ID }}",
  "APP_STORE_CONNECT_API_ISSUER_ID" => "${{ secrets.APP_STORE_CONNECT_API_ISSUER_ID }}",
  "APP_STORE_CONNECT_API_PRIVATE_KEY" => "${{ secrets.APP_STORE_CONNECT_API_PRIVATE_KEY }}",
  "APPLE_TEAM_ID" => "${{ secrets.APPLE_TEAM_ID }}"
}

require_contract(identity_step.fetch("env", {}) == expected_identity_env, "identity environment")
require_contract(build_step.fetch("env", {}) == expected_build_env, "build environment")
require_contract(final_step.fetch("env", {}) == expected_final_env, "final environment")
require_contract(identity_index < build_index && build_index < final_index, "release step order")

identity_run = active_run(identity_step.fetch("run"))
mask_invocation = 'SIGNING_IDENTITY="$signing_identity" /usr/bin/python3'
mask_write = 'print(f"::add-mask::{os.environ['"'"'SIGNING_IDENTITY'"'"']}")'
export_invocation = 'SIGNING_IDENTITY="$signing_identity" GITHUB_ENV_PATH="$GITHUB_ENV" /usr/bin/python3'
export_open = 'with open(os.environ["GITHUB_ENV_PATH"], "a", encoding="utf-8") as output:'
export_write = 'output.write(f"APPLE_SIGNING_IDENTITY={os.environ['"'"'SIGNING_IDENTITY'"'"']}\n")'
identity_markers = [mask_invocation, mask_write, export_invocation, export_open, export_write]
identity_positions = identity_markers.map { |marker| identity_run.index(marker) }
require_contract(identity_positions.none?(&:nil?), "identity mask/export markers")
require_contract(identity_positions.each_cons(2).all? { |left, right| left < right }, "identity mask/export order")
require_contract(identity_run.scan('SIGNING_IDENTITY="$signing_identity"').length == 2, "identity capture reuse")

build_run = active_run(build_step.fetch("run"))
builder_command = 'INKLET_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY" scripts/build-macos-app-bundle.sh'
app_verify_command = 'scripts/verify-direct-app.sh "dist/release/Inklet.app" "com.tomwan.inklet" --release'
builder_position = build_run.index(builder_command)
app_verify_position = build_run.index(app_verify_command)
require_contract(!builder_position.nil? && !app_verify_position.nil?, "build commands")
require_contract(builder_position < app_verify_position, "build verification order")

final_run = active_run(final_step.fetch("run"))
ordered_final_markers = [
  "hdiutil create",
  'hdiutil verify "$dmg_path"',
  '--sign "$APPLE_SIGNING_IDENTITY"',
  'codesign --verify "$dmg_path"',
  'xcrun notarytool submit "$dmg_path"',
  "--wait",
  'xcrun stapler staple "$dmg_path"',
  'xcrun stapler validate "$dmg_path"',
  'spctl --assess --type open --context context:primary-signature "$dmg_path"',
  'hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_dir" -plist',
  'attach_succeeded=1',
  'entities = plistlib.load(attach_file).get("system-entities")',
  'pending_mount_devices+=("$cleanup_device")',
  'mount_acceptance="$(<"$mount_acceptance_path")"',
  'find "$mount_dir" -mindepth 1 -maxdepth 1 -print0',
  'readlink "$applications_link"',
  'scripts/verify-direct-app.sh "$mount_dir/Inklet.app" "com.tomwan.inklet" --release',
  'spctl --assess --type execute "$mount_dir/Inklet.app"'
]
final_positions = ordered_final_markers.map { |marker| final_run.index(marker) }
require_contract(final_positions.none?(&:nil?), "final verification commands")
require_contract(final_positions.each_cons(2).all? { |left, right| left < right }, "final verification order")
cleanup_array_position = final_run.index('pending_mount_devices=()')
cleanup_loop_position = final_run.index('hdiutil detach "${pending_mount_devices[index]}"')
attach_succeeded_position = final_run.index('attach_succeeded=1')
safe_device_extraction_position = final_run.index('safe_devices = []')
cleanup_device_load_position = final_run.index('pending_mount_devices+=("$cleanup_device")')
acceptance_position = final_run.index('mount_acceptance="$(<"$mount_acceptance_path")"')
require_contract([cleanup_array_position, cleanup_loop_position, attach_succeeded_position,
  safe_device_extraction_position, cleanup_device_load_position, acceptance_position].none?(&:nil?),
  "mount cleanup device retention")
require_contract(cleanup_array_position < cleanup_loop_position &&
  attach_succeeded_position < safe_device_extraction_position &&
  safe_device_extraction_position < cleanup_device_load_position &&
  cleanup_device_load_position < acceptance_position,
  "mount cleanup devices retained before acceptance")
detach_position = final_run.rindex('hdiutil detach "$accepted_mount_device"')
copy_position = final_run.index('cp "$dmg_path" "dist/Inklet.dmg"')
checksum_position = final_run.index('shasum -a 256 "$dmg_path"')
require_contract(!detach_position.nil? && !copy_position.nil? && !checksum_position.nil?, "detach/copy/checksum commands")
require_contract(final_positions.last < detach_position && detach_position < copy_position && copy_position < checksum_position,
  "detach/copy/checksum order")
require_contract(final_run.scan("shasum -a 256").length == 2, "final checksum count")
require_contract(final_run.include?("trap cleanup EXIT"), "final cleanup trap")
RUBY
}

write_workflow_mutation() {
  local mutation="$1"
  local destination="$2"

  /usr/bin/ruby -ryaml - "$mutation" "$workflow" "$destination" <<'RUBY'
mutation, source, destination = ARGV
data = YAML.safe_load(File.read(source), [], [], true, source)
steps = data.fetch("jobs").fetch("build-dmg").fetch("steps")
identity_step = steps.find { |step| step["name"] == "Import Developer ID certificate" }
build_step = steps.find { |step| step["name"] == "Build and verify release app" }

case mutation
when "late-mask"
  mask_block = <<~'BLOCK'.chomp
    SIGNING_IDENTITY="$signing_identity" /usr/bin/python3 - <<'PY'
    import os

    print(f"::add-mask::{os.environ['SIGNING_IDENTITY']}")
    PY
  BLOCK
  export_block = <<~'BLOCK'.chomp
    SIGNING_IDENTITY="$signing_identity" GITHUB_ENV_PATH="$GITHUB_ENV" /usr/bin/python3 - <<'PY'
    import os

    with open(os.environ["GITHUB_ENV_PATH"], "a", encoding="utf-8") as output:
        output.write(f"APPLE_SIGNING_IDENTITY={os.environ['SIGNING_IDENTITY']}\n")
    PY
  BLOCK
  run = identity_step.fetch("run")
  raise "mask mutation source" unless run.include?(mask_block) && run.include?(export_block)
  identity_step["run"] = run.sub(mask_block, "__MASK_BLOCK__").sub(export_block, mask_block).sub("__MASK_BLOCK__", export_block)
when "builder-in-wrong-step"
  command = 'INKLET_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY" scripts/build-macos-app-bundle.sh'
  build_step["run"] = build_step.fetch("run").sub(command, 'echo "Builder command moved."')
  wrong_step = steps.find { |step| step["name"] == "Run tests" }
  wrong_step["run"] = "#{wrong_step.fetch("run")}\n#{command}\n"
else
  raise "unknown workflow mutation"
end

File.write(destination, YAML.dump(data))
RUBY
}

workflow_semantic_log="${temp_dir}/workflow-semantic.log"
if ! check_workflow_semantics "$workflow" >"$workflow_semantic_log" 2>&1; then
  fail "DMG CI workflow does not satisfy the structured release contract."
fi
if ! grep -Fq 'scripts/build-macos-app-bundle.sh' "$workflow"; then
  fail "DMG CI must use the shared app-bundle builder."
fi
required_workflow_environment=(
  'INKLET_APP_NAME: Inklet'
  'INKLET_BUNDLE_ID: com.tomwan.inklet'
  'INKLET_VERSION: ${{ steps.release.outputs.app_version }}'
  'INKLET_BUILD_NUMBER: ${{ steps.release.outputs.build_number }}'
  'INKLET_OUTPUT_DIR: dist/release'
  'INKLET_REQUIRE_TIMESTAMP: "1"'
  'APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}'
)
for environment_setting in "${required_workflow_environment[@]}"; do
  if ! grep -Fq -- "$environment_setting" "$workflow"; then
    fail "DMG CI must pass the production release environment to the shared builder."
  fi
done
if ! grep -Fq 'INKLET_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY" scripts/build-macos-app-bundle.sh' "$workflow"; then
  fail "DMG CI must pass the discovered identity to the shared builder without printing it."
fi

required_workflow_commands=(
  'scripts/verify-direct-app.sh "dist/release/Inklet.app" "com.tomwan.inklet" --release'
  'hdiutil verify "$dmg_path"'
  'codesign --verify "$dmg_path"'
  'xcrun notarytool submit "$dmg_path"'
  'xcrun stapler staple "$dmg_path"'
  'xcrun stapler validate "$dmg_path"'
  'spctl --assess --type open --context context:primary-signature "$dmg_path"'
  'hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_dir" -plist'
  'entities = plistlib.load(attach_file).get("system-entities")'
  'find "$mount_dir" -mindepth 1 -maxdepth 1 -print0'
  'readlink "$applications_link"'
  'scripts/verify-direct-app.sh "$mount_dir/Inklet.app" "com.tomwan.inklet" --release'
  'spctl --assess --type execute "$mount_dir/Inklet.app"'
  'hdiutil detach "$accepted_mount_device"'
)
for workflow_command in "${required_workflow_commands[@]}"; do
  if ! grep -Fq -- "$workflow_command" "$workflow"; then
    fail "DMG CI is missing a required final-artifact verification command."
  fi
done

if ! grep -Fq -- '--wait' "$workflow"; then
  fail "DMG CI notarization must wait for a final result."
fi
if ! grep -Fq 'trap cleanup EXIT' "$workflow"; then
  fail "DMG CI must detach a mounted image from an EXIT trap."
fi
if grep -Eq 'security find-identity[[:space:]]+-v|security find-identity.*(>&2|/dev/stderr)' "$workflow"; then
  fail "DMG CI must not dump signing identities."
fi
if ! grep -Fq 'partition-list.log' "$workflow"; then
  fail "DMG CI must capture key partition diagnostics."
fi
if ! grep -Fq '::add-mask::' "$workflow"; then
  fail "DMG CI must mask the selected signing identity before exporting it."
fi
if grep -Eq '(echo|printf).*(signing_identity|APPLE_SIGNING_IDENTITY)|set -x' "$workflow"; then
  fail "DMG CI must not print the selected signing identity."
fi

workflow_line() {
  local needle="$1"
  local line

  line="$(grep -nF -- "$needle" "$workflow" | head -n 1 | cut -d: -f1)"
  if [[ -z "$line" ]]; then
    fail "Could not locate required DMG CI step: ${needle}."
  fi
  printf '%s\n' "$line"
}

workflow_last_line() {
  local needle="$1"
  local line

  line="$(grep -nF -- "$needle" "$workflow" | tail -n 1 | cut -d: -f1)"
  if [[ -z "$line" ]]; then
    fail "Could not locate required DMG CI step: ${needle}."
  fi
  printf '%s\n' "$line"
}

app_verify_line="$(workflow_line 'scripts/verify-direct-app.sh "dist/release/Inklet.app" "com.tomwan.inklet" --release')"
create_line="$(workflow_line 'hdiutil create')"
verify_dmg_line="$(workflow_line 'hdiutil verify "$dmg_path"')"
sign_dmg_line="$(workflow_line '--sign "$APPLE_SIGNING_IDENTITY"')"
verify_signature_line="$(workflow_line 'codesign --verify "$dmg_path"')"
notarize_line="$(workflow_line 'xcrun notarytool submit "$dmg_path"')"
staple_line="$(workflow_line 'xcrun stapler staple "$dmg_path"')"
validate_staple_line="$(workflow_line 'xcrun stapler validate "$dmg_path"')"
assess_dmg_line="$(workflow_line 'spctl --assess --type open --context context:primary-signature "$dmg_path"')"
mount_line="$(workflow_line 'hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_dir" -plist')"
mount_parse_line="$(workflow_line 'entities = plistlib.load(attach_file).get("system-entities")')"
payload_find_line="$(workflow_line 'find "$mount_dir" -mindepth 1 -maxdepth 1 -print0')"
payload_link_line="$(workflow_line 'readlink "$applications_link"')"
mounted_verify_line="$(workflow_line 'scripts/verify-direct-app.sh "$mount_dir/Inklet.app" "com.tomwan.inklet" --release')"
assess_app_line="$(workflow_line 'spctl --assess --type execute "$mount_dir/Inklet.app"')"
detach_line="$(workflow_last_line 'hdiutil detach "$accepted_mount_device"')"
checksum_line="$(workflow_line 'shasum -a 256 "$dmg_path"')"

workflow_order=(
  "$app_verify_line"
  "$create_line"
  "$verify_dmg_line"
  "$sign_dmg_line"
  "$verify_signature_line"
  "$notarize_line"
  "$staple_line"
  "$validate_staple_line"
  "$assess_dmg_line"
  "$mount_line"
  "$mount_parse_line"
  "$payload_find_line"
  "$payload_link_line"
  "$mounted_verify_line"
  "$assess_app_line"
  "$detach_line"
  "$checksum_line"
)
for ((index = 1; index < ${#workflow_order[@]}; index += 1)); do
  if ((workflow_order[index - 1] >= workflow_order[index])); then
    fail "DMG CI must mutate, verify, detach, and checksum the final artifact in the required order."
  fi
done

if [[ "$(grep -Fc 'shasum -a 256' "$workflow")" != "2" ]]; then
  fail "DMG CI must generate only the two final release checksums."
fi

late_mask_workflow="${temp_dir}/workflow-late-mask.yml"
write_workflow_mutation late-mask "$late_mask_workflow"
if check_workflow_semantics "$late_mask_workflow" >"${temp_dir}/late-mask-semantic.log" 2>&1; then
  fail "The structured workflow checker must reject identity export before masking."
fi

wrong_step_workflow="${temp_dir}/workflow-builder-wrong-step.yml"
write_workflow_mutation builder-in-wrong-step "$wrong_step_workflow"
if check_workflow_semantics "$wrong_step_workflow" >"${temp_dir}/wrong-step-semantic.log" 2>&1; then
  fail "The structured workflow checker must reject the builder command in an unrelated step."
fi

echo "Direct distribution checks passed."
