#!/usr/bin/env bash
#
# scan_wrapper.sh
#
# 1) Download scan.sh from GitHub (so we have it locally).
# 2) Run scan.sh (suppress its output).
# 3) If no new ZIP => print green message => exit.
# 4) Else => parse scan_result.json => print details.
#

# Where to place the resulting ZIP file:
ZIP_OUTPUT="/tmp/found_extensions.zip"

rm -f "$ZIP_OUTPUT"

# 1) Download the original scan script
curl -sL https://raw.githubusercontent.com/CyberhavenInc/chrome-extension-tools/main/chrome-extensions-scanner/scan.sh -o scan.sh
chmod +x scan.sh

# 2) Run your original scan script **quietly**
./scan.sh "$ZIP_OUTPUT" >/dev/null 2>&1

# 3) Check if the ZIP was created
if [ ! -f "$ZIP_OUTPUT" ]; then
    # Nothing found => print green message
    printf "\033[32mNo extension was found.\033[0m\n"
    exit 0
fi

# 4) If the ZIP exists, parse it:
TMP_DIR=$(mktemp -d)
unzip -q "$ZIP_OUTPUT" -d "$TMP_DIR"

# Find scan_result.json
SCAN_JSON=$(find "$TMP_DIR" -type f -name "scan_result.json" | head -n 1)

# If scan_result.json is missing, treat as no results
if [ -z "$SCAN_JSON" ]; then
    printf "\033[32mNo extension was found.\033[0m\n"
    rm -rf "$TMP_DIR"
    exit 0
fi

# Count how many matched extensions
COUNT=$(jq '.found | length' "$SCAN_JSON" 2>/dev/null)

# If zero => print green => done
if [ "$COUNT" -eq 0 ]; then
    printf "\033[32mNo extension was found.\033[0m\n"
    rm -rf "$TMP_DIR"
    exit 0
fi

# Otherwise, show the count in red
printf "\033[31mNumber of extensions containing the specified strings: %d\033[0m\n" "$COUNT"
printf "Extensions found:\n"

# Loop over each extension object
while IFS=$'\t' read -r USERNAME BROWSER PROFILE EXT_ID EXT_NAME; do

    # Gather matched strings from scan_result.json
    MATCHED_STRINGS=$(
        jq -r \
            --arg extId "$EXT_ID" \
            '.found[]
         | select(.extensionId == $extId)
         | .matches[]
         | .strings[]
        ' "$SCAN_JSON" 2>/dev/null |
            sort -u
    )

    printf "\n\033[31mUser:\033[0m %s\n" "$USERNAME"
    printf "\033[31mBrowser:\033[0m %s\n" "$BROWSER"
    printf "\033[31mProfile:\033[0m %s\n" "$PROFILE"
    printf "\033[31mExtension ID:\033[0m %s\n" "$EXT_ID"
    printf "\033[31mExtension Name:\033[0m %s\n" "$EXT_NAME"

    printf "\033[31mMatched Strings:\033[0m\n"
    if [ -z "$MATCHED_STRINGS" ]; then
        printf "   (None listed?)\n"
    else
        while IFS= read -r line; do
            printf "   %s\n" "$line"
        done <<<"$MATCHED_STRINGS"
    fi

done < <(
    # Extract user, browser, profile, extensionId, extensionName from .found
    # (If extensionName key is missing, fallback to "(no name)")
    jq -r '
    .found[] |
    [
      .user,
      .browser,
      .profile,
      .extensionId,
      (.extensionName // "(no name)")
    ] | @tsv
  ' "$SCAN_JSON" 2>/dev/null
)

# Cleanup
rm -rf "$TMP_DIR"
exit 0
