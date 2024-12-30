#!/usr/bin/env bats

# ----------------------------------------------------------------------------
# Comprehensive Bats test suite for 'scan.sh'
# with fixes for:
#  - Read-only directory permissions (chmod 500)
#  - Correct relative/absolute path usage
#  - JSON Summaries from multiple runs (removing first extension)
# ----------------------------------------------------------------------------

setup() {
  # Create a temp directory for the test environment
  TEST_TMP_DIR="$(mktemp -d "/tmp/bats_test_scan_XXXX")"

  # Point the script to our mock /Users
  export USER_BASE_DIR="$TEST_TMP_DIR/Users"

  # We'll mock out 'hostname' and 'system_profiler'
  MOCK_BIN_DIR="$TEST_TMP_DIR/mock_bin"
  mkdir -p "$MOCK_BIN_DIR"

  cat <<'EOF' > "$MOCK_BIN_DIR/hostname"
#!/usr/bin/env bash
echo "mock-host"
EOF
  chmod +x "$MOCK_BIN_DIR/hostname"

  cat <<'EOF' > "$MOCK_BIN_DIR/system_profiler"
#!/usr/bin/env bash
echo "Serial Number (system): MOCK-SERIAL-9999"
EOF
  chmod +x "$MOCK_BIN_DIR/system_profiler"

  # Prepend our mocks to PATH
  export PATH="$MOCK_BIN_DIR:$PATH"

  # For convenience, get the absolute path to the script we're testing
  SCRIPT_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/scan.sh"
}

teardown() {
  # Restore permissions in case we locked them, so rm -rf works
  chmod -R u+rwX "$TEST_TMP_DIR" 2>/dev/null || true
  rm -rf "$TEST_TMP_DIR"
}

# Helper: unzip the script's output and find scan_result.json
unpack_and_find_json() {
  local zipPath="$1"
  local inspectDir="$2"

  [ -f "$zipPath" ] || return 1

  mkdir -p "$inspectDir"
  unzip -q "$zipPath" -d "$inspectDir"

  find "$inspectDir" -name "scan_result.json" | head -n1
}

# ----------------------------------------------------------------------------
# 1) Fails with no arguments (displays usage)
# ----------------------------------------------------------------------------
@test "Fails with no arguments (displays usage)" {
  run bash "$SCRIPT_PATH"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Usage:" ]]
}

# ----------------------------------------------------------------------------
# 2) Fails if missing zip output path
# ----------------------------------------------------------------------------
@test "Fails if missing zip output path" {
  run bash "$SCRIPT_PATH" --verbose
  [ "$status" -ne 0 ]
  [[ "$output" =~ "missing zip output path" ]]
}

# ----------------------------------------------------------------------------
# 3) Single user & profile with known match
# ----------------------------------------------------------------------------
@test "Single user & profile with known match" {
  mkdir -p "$USER_BASE_DIR/testuser/Library/Application Support/Google/Chrome/Default/Extensions/fakeextensionid"
  echo "Contains api.cyberhavenext.pro" \
    > "$USER_BASE_DIR/testuser/Library/Application Support/Google/Chrome/Default/Extensions/fakeextensionid/extension.js"

  echo '{"extensions":{"settings":{"fakeextensionid":{"manifest":{"name":"Fake Extension"}}}}}' \
    > "$USER_BASE_DIR/testuser/Library/Application Support/Google/Chrome/Default/Preferences"

  ZIP_OUTPUT="$TEST_TMP_DIR/single_profile.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  [ "$status" -eq 0 ]
  [ -f "$ZIP_OUTPUT" ]

  INSPECT_DIR="$TEST_TMP_DIR/inspect_single_profile"
  JSON_FILE="$(unpack_and_find_json "$ZIP_OUTPUT" "$INSPECT_DIR")"
  [ -f "$JSON_FILE" ]

  run jq -r '.found[].extensionId' "$JSON_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "fakeextensionid" ]]
}

# ----------------------------------------------------------------------------
# 4) Multiple profiles for a single user
# ----------------------------------------------------------------------------
@test "Multiple profiles for a single user" {
  mkdir -p "$USER_BASE_DIR/testuser/Library/Application Support/Google/Chrome/Default/Extensions/extA"
  mkdir -p "$USER_BASE_DIR/testuser/Library/Application Support/Google/Chrome/Profile 2/Extensions/extB"

  echo "ads/ad_limits" \
    > "$USER_BASE_DIR/testuser/Library/Application Support/Google/Chrome/Default/Extensions/extA/a.js"
  echo '{"extensions":{"settings":{"extA":{}}}}' \
    > "$USER_BASE_DIR/testuser/Library/Application Support/Google/Chrome/Default/Preferences"

  echo "No known pattern here" \
    > "$USER_BASE_DIR/testuser/Library/Application Support/Google/Chrome/Profile 2/Extensions/extB/clean.js"
  echo '{"extensions":{"settings":{"extB":{}}}}' \
    > "$USER_BASE_DIR/testuser/Library/Application Support/Google/Chrome/Profile 2/Preferences"

  ZIP_OUTPUT="$TEST_TMP_DIR/multi_profiles.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  [ "$status" -eq 0 ]

  INSPECT_DIR="$TEST_TMP_DIR/inspect_multi_profiles"
  JSON_FILE="$(unpack_and_find_json "$ZIP_OUTPUT" "$INSPECT_DIR")"
  [ -f "$JSON_FILE" ]

  run jq -r '.found[].extensionId' "$JSON_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "extA" ]]
  [[ ! "$output" =~ "extB" ]]
}

# ----------------------------------------------------------------------------
# 5) Multiple users scenario
# ----------------------------------------------------------------------------
@test "Multiple users scenario" {
  mkdir -p "$USER_BASE_DIR/userA/Library/Application Support/Google/Chrome/Default/Extensions/extA"
  echo "api/saveQR" \
    > "$USER_BASE_DIR/userA/Library/Application Support/Google/Chrome/Default/Extensions/extA/a.js"

  echo '{"extensions":{"settings":{"extA":{}}}}' \
    > "$USER_BASE_DIR/userA/Library/Application Support/Google/Chrome/Default/Preferences"

  mkdir -p "$USER_BASE_DIR/userB/Library/Application Support/Google/Chrome/Default/Extensions/extB"
  echo "qr/show/code" \
    > "$USER_BASE_DIR/userB/Library/Application Support/Google/Chrome/Default/Extensions/extB/b.js"

  echo '{"extensions":{"settings":{"extB":{}}}}' \
    > "$USER_BASE_DIR/userB/Library/Application Support/Google/Chrome/Default/Preferences"

  ZIP_OUTPUT="$TEST_TMP_DIR/multi_users.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  [ "$status" -eq 0 ]
  [ -f "$ZIP_OUTPUT" ]

  INSPECT_DIR="$TEST_TMP_DIR/inspect_multi_users"
  JSON_FILE="$(unpack_and_find_json "$ZIP_OUTPUT" "$INSPECT_DIR")"
  [ -f "$JSON_FILE" ]

  run jq -r '.found[].extensionId' "$JSON_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "extA" ]]
  [[ "$output" =~ "extB" ]]
}

# ----------------------------------------------------------------------------
# 6) No matches found scenario
# ----------------------------------------------------------------------------
@test "No matches found scenario" {
  mkdir -p "$USER_BASE_DIR/nomatchuser/Library/Application Support/Google/Chrome/Default/Extensions/nothing"
  echo "Totally random text" \
    > "$USER_BASE_DIR/nomatchuser/Library/Application Support/Google/Chrome/Default/Extensions/nothing/boring.js"

  echo '{"extensions":{"settings":{"nothing":{}}}}' \
    > "$USER_BASE_DIR/nomatchuser/Library/Application Support/Google/Chrome/Default/Preferences"

  ZIP_OUTPUT="$TEST_TMP_DIR/no_matches.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  [ "$status" -eq 0 ]

  # Should NOT create a zip if no matches
  [ ! -f "$ZIP_OUTPUT" ]
}

# ----------------------------------------------------------------------------
# 7) Multiple matches in the same file
# ----------------------------------------------------------------------------
@test "Multiple matches in the same file" {
  mkdir -p "$USER_BASE_DIR/multiUser/Library/Application Support/Google/Chrome/Default/Extensions/multiExt"
  cat <<EOF \
    > "$USER_BASE_DIR/multiUser/Library/Application Support/Google/Chrome/Default/Extensions/multiExt/match.js"
api.cyberhavenext.pro
ads/ad_limits
qr/show/code
EOF

  echo '{"extensions":{"settings":{"multiExt":{}}}}' \
    > "$USER_BASE_DIR/multiUser/Library/Application Support/Google/Chrome/Default/Preferences"

  ZIP_OUTPUT="$TEST_TMP_DIR/multiple_matches_in_one_file.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  [ "$status" -eq 0 ]
  [ -f "$ZIP_OUTPUT" ]

  INSPECT_DIR="$TEST_TMP_DIR/inspect_multi_match"
  JSON_FILE="$(unpack_and_find_json "$ZIP_OUTPUT" "$INSPECT_DIR")"
  [ -f "$JSON_FILE" ]

  run jq -r '.found[].extensionId' "$JSON_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "multiExt" ]]
}

# ----------------------------------------------------------------------------
# 8) All supported browsers scenario
# ----------------------------------------------------------------------------
@test "All supported browsers scenario" {
  base="$USER_BASE_DIR/allBrowsersUser"

  # Chrome
  mkdir -p "$base/Library/Application Support/Google/Chrome/Default/Extensions/chromeExt"
  echo "api.cyberhavenext.pro" \
    > "$base/Library/Application Support/Google/Chrome/Default/Extensions/chromeExt/chrome.js"
  echo '{"extensions":{"settings":{"chromeExt":{}}}}' \
    > "$base/Library/Application Support/Google/Chrome/Default/Preferences"

  # Brave
  mkdir -p "$base/Library/Application Support/BraveSoftware/Brave-Browser/Default/Extensions/braveExt"
  echo "ads/ad_limits" \
    > "$base/Library/Application Support/BraveSoftware/Brave-Browser/Default/Extensions/braveExt/brave.js"
  echo '{"extensions":{"settings":{"braveExt":{}}}}' \
    > "$base/Library/Application Support/BraveSoftware/Brave-Browser/Default/Preferences"

  # Edge
  mkdir -p "$base/Library/Application Support/Microsoft Edge/Default/Extensions/edgeExt"
  echo "qr/show/code" \
    > "$base/Library/Application Support/Microsoft Edge/Default/Extensions/edgeExt/edge.js"
  echo '{"extensions":{"settings":{"edgeExt":{}}}}' \
    > "$base/Library/Application Support/Microsoft Edge/Default/Preferences"

  # Chromium
  mkdir -p "$base/Library/Application Support/Chromium/Default/Extensions/chromiumExt"
  echo "_ext_manage" \
    > "$base/Library/Application Support/Chromium/Default/Extensions/chromiumExt/cr.js"
  echo '{"extensions":{"settings":{"chromiumExt":{}}}}' \
    > "$base/Library/Application Support/Chromium/Default/Preferences"

  ZIP_OUTPUT="$TEST_TMP_DIR/all_browsers.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  [ "$status" -eq 0 ]
  [ -f "$ZIP_OUTPUT" ]

  INSPECT_DIR="$TEST_TMP_DIR/inspect_all_browsers"
  JSON_FILE="$(unpack_and_find_json "$ZIP_OUTPUT" "$INSPECT_DIR")"
  [ -f "$JSON_FILE" ]

  run jq -r '.found|length' "$JSON_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]

  run jq -r '.found[].extensionId' "$JSON_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "chromeExt" ]]
  [[ "$output" =~ "braveExt" ]]
  [[ "$output" =~ "edgeExt" ]]
  [[ "$output" =~ "chromiumExt" ]]
}

# ----------------------------------------------------------------------------
# 9) Permission-Restricted Environment
# ----------------------------------------------------------------------------
@test "Permission-Restricted Environment" {
  # We'll set chmod 000 or 500 so we can't read or write
  mkdir -p "$USER_BASE_DIR/userRestrict/Library/Application Support/Google/Chrome/Default"
  chmod 000 "$USER_BASE_DIR/userRestrict/Library/Application Support/Google/Chrome/Default" || true

  ZIP_OUTPUT="$TEST_TMP_DIR/perm_restrict.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"

  # If your script just skips it and returns success:
  if [ "$status" -eq 0 ]; then
    # Possibly no matches => no zip
    [ ! -f "$ZIP_OUTPUT" ]
  else
    # Or it fails because it can't scan. Either is acceptable.
    [ "$status" -ne 0 ]
  fi
}

# ----------------------------------------------------------------------------
# 10) Missing `jq`
# ----------------------------------------------------------------------------
@test "Missing jq scenario" {
  if ! command -v jq >/dev/null; then
    skip "jq not installed on this system anyway."
  fi

  JQ_PATH="$(command -v jq)"
  # Try renaming it so script can't find jq
  mv "$JQ_PATH" "${JQ_PATH}.bak" 2>/dev/null || skip "Cannot rename jq"

  ZIP_OUTPUT="$TEST_TMP_DIR/missing_jq.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  # Expect the script to fail
  [ "$status" -ne 0 ]

  # Restore jq
  mv "${JQ_PATH}.bak" "$JQ_PATH" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# 11) Read-Only Zip Output Destination
# ----------------------------------------------------------------------------
@test "Read-Only Zip Output Destination" {
  mkdir -p "$TEST_TMP_DIR/readonly_dir"
  chmod u-w "$TEST_TMP_DIR/readonly_dir"

  # Arrange a known match
  # ...

  ZIP_OUTPUT="$TEST_TMP_DIR/readonly_dir/ro.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  
  # If your script doesn't consider this an error, then do:
  [ "$status" -eq 0 ]
  # And confirm no ZIP was created
  [ ! -f "$ZIP_OUTPUT" ]
}

# ----------------------------------------------------------------------------
# 12) Relative vs. Absolute Zip Path
# ----------------------------------------------------------------------------
@test "Relative vs. Absolute Zip Path" {
  mkdir -p "$USER_BASE_DIR/relAbsUser/Library/Application Support/Google/Chrome/Default/Extensions/relAbs"
  echo "api.cyberhavenext.pro" \
    > "$USER_BASE_DIR/relAbsUser/Library/Application Support/Google/Chrome/Default/Extensions/relAbs/code.js"

  # 12.1) Absolute path
  ABS_ZIP="$TEST_TMP_DIR/abs_path.zip"
  run bash "$SCRIPT_PATH" "$ABS_ZIP"
  [ "$status" -eq 0 ]
  [ -f "$ABS_ZIP" ]

  # 12.2) Relative path
  echo "ads/ad_limits" \
    > "$USER_BASE_DIR/relAbsUser/Library/Application Support/Google/Chrome/Default/Extensions/relAbs/code2.js"

  pushd "$TEST_TMP_DIR" || exit
    REL_ZIP="rel_path.zip"
    run bash "$SCRIPT_PATH" "$REL_ZIP"
    [ "$status" -eq 0 ]
    [ -f "$REL_ZIP" ]
  popd || exit
}

# ----------------------------------------------------------------------------
# 13) Non-Default Profile only
# ----------------------------------------------------------------------------
@test "Non-Default Profile only" {
  mkdir -p "$USER_BASE_DIR/userP1/Library/Application Support/Google/Chrome/Profile 1/Extensions/p1Ext"
  echo "qr/show/code" \
    > "$USER_BASE_DIR/userP1/Library/Application Support/Google/Chrome/Profile 1/Extensions/p1Ext/foo.js"

  ZIP_OUTPUT="$TEST_TMP_DIR/non_default_profile.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  [ "$status" -eq 0 ]
  [ -f "$ZIP_OUTPUT" ]

  INSPECT_DIR="$TEST_TMP_DIR/inspect_non_default"
  JSON_FILE="$(unpack_and_find_json "$ZIP_OUTPUT" "$INSPECT_DIR")"
  [ -f "$JSON_FILE" ]

  run jq -r '.found[].extensionId' "$JSON_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "p1Ext" ]]
}

# ----------------------------------------------------------------------------
# 14) Weird Filenames and Special Characters
# ----------------------------------------------------------------------------
@test "Weird Filenames and Special Characters" {
  mkdir -p "$USER_BASE_DIR/weirdUser/Library/Application Support/Google/Chrome/Default/Extensions/wë!rd"
  echo "ads/ad_limits" \
    > "$USER_BASE_DIR/weirdUser/Library/Application Support/Google/Chrome/Default/Extensions/wë!rd/weird (file).js"

  ZIP_OUTPUT="$TEST_TMP_DIR/weird_files.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  [ "$status" -eq 0 ]
  [ -f "$ZIP_OUTPUT" ]

  INSPECT_DIR="$TEST_TMP_DIR/inspect_weird"
  JSON_FILE="$(unpack_and_find_json "$ZIP_OUTPUT" "$INSPECT_DIR")"
  [ -f "$JSON_FILE" ]

  # Confirm the weird file is in the zip
  find "$INSPECT_DIR" -name "weird (file).js" | grep ".js" >/dev/null
}

# ----------------------------------------------------------------------------
# 15) Partial vs. Exact Matches
# ----------------------------------------------------------------------------
@test "Partial vs. Exact Matches" {
  mkdir -p "$USER_BASE_DIR/partialUser/Library/Application Support/Google/Chrome/Default/Extensions/partialExt"
  echo "ads/ad_limits" \
    > "$USER_BASE_DIR/partialUser/Library/Application Support/Google/Chrome/Default/Extensions/partialExt/exact.js"
  echo "ads/ad_limitssomething" \
    > "$USER_BASE_DIR/partialUser/Library/Application Support/Google/Chrome/Default/Extensions/partialExt/partial.js"

  ZIP_OUTPUT="$TEST_TMP_DIR/partial_vs_exact.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  [ "$status" -eq 0 ]

  [ -f "$ZIP_OUTPUT" ]
  INSPECT_DIR="$TEST_TMP_DIR/inspect_partial"
  JSON_FILE="$(unpack_and_find_json "$ZIP_OUTPUT" "$INSPECT_DIR")"
  [ -f "$JSON_FILE" ]

  # Check if partial.js matched (depends on grep usage)
  run jq -r '.found[].matches[]?.file' "$JSON_FILE"
  [ "$status" -eq 0 ]

  # Should definitely see exact.js
  [[ "$output" =~ "exact.js" ]]
}

# ----------------------------------------------------------------------------
# 16) Large Extension Directory
# ----------------------------------------------------------------------------
@test "Large Extension Directory" {
  mkdir -p "$USER_BASE_DIR/largeUser/Library/Application Support/Google/Chrome/Default/Extensions/largeExt"
  for i in {1..5}; do
    echo "ads/ad_limits in file$i" \
      > "$USER_BASE_DIR/largeUser/Library/Application Support/Google/Chrome/Default/Extensions/largeExt/file_${i}.js"
  done

  ZIP_OUTPUT="$TEST_TMP_DIR/large.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  [ "$status" -eq 0 ]
  [ -f "$ZIP_OUTPUT" ]

  INSPECT_DIR="$TEST_TMP_DIR/inspect_large"
  JSON_FILE="$(unpack_and_find_json "$ZIP_OUTPUT" "$INSPECT_DIR")"
  [ -f "$JSON_FILE" ]

  run jq -r '.found[].extensionId' "$JSON_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "largeExt" ]]
}

# ----------------------------------------------------------------------------
# 17) Missing 'extensions.settings' key in Preferences
# ----------------------------------------------------------------------------
@test "Missing 'extensions.settings' key in Preferences" {
  mkdir -p "$USER_BASE_DIR/missingKeyUser/Library/Application Support/Google/Chrome/Default/Extensions/noSettings"
  echo "api.cyberhavenext.pro" \
    > "$USER_BASE_DIR/missingKeyUser/Library/Application Support/Google/Chrome/Default/Extensions/noSettings/foo.js"

  # Preferences missing the 'extensions.settings' object
  echo '{"someOtherKey":{"foo":"bar"}}' \
    > "$USER_BASE_DIR/missingKeyUser/Library/Application Support/Google/Chrome/Default/Preferences"

  ZIP_OUTPUT="$TEST_TMP_DIR/missing_settings_key.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  [ "$status" -eq 0 ]
  [ -f "$ZIP_OUTPUT" ]

  INSPECT_DIR="$TEST_TMP_DIR/inspect_missing_settings"
  JSON_FILE="$(unpack_and_find_json "$ZIP_OUTPUT" "$INSPECT_DIR")"
  [ -f "$JSON_FILE" ]

  run jq -r '.found|length' "$JSON_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ----------------------------------------------------------------------------
# 18) Environment Override (USER_BASE_DIR override)
# ----------------------------------------------------------------------------
@test "Environment override scenario" {
  ALT_BASE_DIR="$TEST_TMP_DIR/AltUsers"
  mkdir -p "$ALT_BASE_DIR/altUser/Library/Application Support/Google/Chrome/Default/Extensions/altExt"
  echo "ads/ad_limits" \
    > "$ALT_BASE_DIR/altUser/Library/Application Support/Google/Chrome/Default/Extensions/altExt/alt.js"

  oldBase="$USER_BASE_DIR"
  export USER_BASE_DIR="$ALT_BASE_DIR"

  ZIP_OUTPUT="$TEST_TMP_DIR/alt_base.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  [ "$status" -eq 0 ]
  [ -f "$ZIP_OUTPUT" ]

  # Restore
  export USER_BASE_DIR="$oldBase"

  INSPECT_DIR="$TEST_TMP_DIR/inspect_alt"
  JSON_FILE="$(unpack_and_find_json "$ZIP_OUTPUT" "$INSPECT_DIR")"
  [ -f "$JSON_FILE" ]

  run jq -r '.found[].extensionId' "$JSON_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "altExt" ]]
}

# ----------------------------------------------------------------------------
# 19) Overlapping Base64 Patterns
# ----------------------------------------------------------------------------
@test "Overlapping Base64 patterns" {
  mkdir -p "$USER_BASE_DIR/overlapUser/Library/Application Support/Google/Chrome/Default/Extensions/overlapExt"
  cat <<EOF \
    > "$USER_BASE_DIR/overlapUser/Library/Application Support/Google/Chrome/Default/Extensions/overlapExt/overlap.js"
YXBpL3NhdmVRUgYXBpLmN5YmVyaGF2ZW5leHQucHJv
EOF

  ZIP_OUTPUT="$TEST_TMP_DIR/overlap_base64.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT"
  [ "$status" -eq 0 ]

  INSPECT_DIR="$TEST_TMP_DIR/inspect_overlap"
  JSON_FILE="$(unpack_and_find_json "$ZIP_OUTPUT" "$INSPECT_DIR")"
  [ -f "$JSON_FILE" ]

  run jq -r '.found[].extensionId' "$JSON_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "overlapExt" ]]

  # Confirm both patterns match
  run jq -r '.found[].matches[]?.strings[]?' "$JSON_FILE"
  [[ "$output" =~ "YXBpL3NhdmVRUg" ]]
  [[ "$output" =~ "YXBpLmN5YmVyaGF2ZW5leHQucHJv" ]]
}

# ----------------------------------------------------------------------------
# 20) JSON Summaries from Multiple Runs
# ----------------------------------------------------------------------------
@test "JSON Summaries from Multiple Runs" {
  mkdir -p "$USER_BASE_DIR/multiRunUser/Library/Application Support/Google/Chrome/Default/Extensions/run1"
  echo "api.cyberhavenext.pro" \
    > "$USER_BASE_DIR/multiRunUser/Library/Application Support/Google/Chrome/Default/Extensions/run1/r1.js"

  ZIP_OUTPUT1="$TEST_TMP_DIR/run1.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT1"
  [ "$status" -eq 0 ]
  [ -f "$ZIP_OUTPUT1" ]

  # Remove run1 so the second scan does not find it again
  rm -rf "$USER_BASE_DIR/multiRunUser/Library/Application Support/Google/Chrome/Default/Extensions/run1"

  mkdir -p "$USER_BASE_DIR/multiRunUser/Library/Application Support/Google/Chrome/Default/Extensions/run2"
  echo "ads/ad_limits" \
    > "$USER_BASE_DIR/multiRunUser/Library/Application Support/Google/Chrome/Default/Extensions/run2/r2.js"

  ZIP_OUTPUT2="$TEST_TMP_DIR/run2.zip"
  run bash "$SCRIPT_PATH" "$ZIP_OUTPUT2"
  [ "$status" -eq 0 ]
  [ -f "$ZIP_OUTPUT2" ]

  # Inspect both
  INSPECT1="$TEST_TMP_DIR/inspect_run1"
  JSON1="$(unpack_and_find_json "$ZIP_OUTPUT1" "$INSPECT1")"
  [ -f "$JSON1" ]
  INSPECT2="$TEST_TMP_DIR/inspect_run2"
  JSON2="$(unpack_and_find_json "$ZIP_OUTPUT2" "$INSPECT2")"
  [ -f "$JSON2" ]

  # First JSON: only run1
  run jq -r '.found[].extensionId' "$JSON1"
  [[ "$output" =~ "run1" ]]
  [[ ! "$output" =~ "run2" ]]

  # Second JSON: only run2
  run jq -r '.found[].extensionId' "$JSON2"
  [[ "$output" =~ "run2" ]]
  [[ ! "$output" =~ "run1" ]]
}
