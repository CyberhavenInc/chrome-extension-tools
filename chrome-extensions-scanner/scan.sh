#!/bin/bash
# ------------------------------------------------------------------------
# Scans Chrome-like browsers for specific strings in extensions.
# Generates a JSON report (user/browser/profile/extension + matched files/strings),
# and optionally zips matched extensions (skipping if none found).
#
# Key Features:
#   - Single grep pass per pattern for speed (via xargs).
#   - Saves only extension settings from Preferences (via jq).
#   - Sort-based deduplication (no arrays).
#   - Optional -v|--verbose for detailed logs.
#
# Usage:
#   ./scan.sh [-v|--verbose] <zip_output_path>
# Requirements:
#   - jq installed (brew install jq).
#   - Possibly sudo or Full Disk Access to scan multiple users.
#
# Example:
#   chmod +x scan.sh
#   ./scan.sh -v /path/to/found_extensions.zip
# ------------------------------------------------------------------------

BROWSERS=(
    "Chrome::Library/Application Support/Google/Chrome"
    "Brave::Library/Application Support/BraveSoftware/Brave-Browser"
    "Edge::Library/Application Support/Microsoft Edge"
    "Chromium::Library/Application Support/Chromium"
)

# Strings to search for in extension code/data:
SEARCH_STRINGS=(
    "api.cyberhavenext.pro"
    "api/saveQR"
    "ads/ad_limits"
    "qr/show/code"
    "_ext_manage"
    "_ext_log"

    # base64 representations
    "YXBpLmN5YmVyaGF2ZW5leHQucHJv"
    "YXBpL3NhdmVRUg"
    "YWRzL2FkX2xpbWl0cw"
    "cXIvc2hvdy9jb2Rl"
    "ZXh0X21hbmFnZQ"
    "ZXh0X2xvZw"
)

# Simple logging function (controlled by $VERBOSE).
log() {
    if [ "$VERBOSE" = "true" ]; then
        echo "[VERBOSE]" "$@"
    fi
}

# ----------------- ARGUMENT PARSING -----------------

VERBOSE="false"
ZIP_OUTPUT_PATH=""

# Usage pattern: script.sh [-v|--verbose] <zip_output_path>
while [[ $# -gt 0 ]]; do
    case "$1" in
    -v | --verbose)
        VERBOSE="true"
        shift
        ;;
    -*)
        echo "Unknown option: $1"
        echo "Usage: $0 [-v|--verbose] <zip_output_path>"
        exit 1
        ;;
    *)
        # Assume this is the zip output path
        ZIP_OUTPUT_PATH="$1"
        shift
        ;;
    esac
done

if [ -z "$ZIP_OUTPUT_PATH" ]; then
    echo "Error: missing zip output path."
    echo "Usage: $0 [-v|--verbose] <zip_output_path>"
    exit 1
fi

# Convert ZIP_OUTPUT_PATH to absolute so that a relative path like "./output.zip" works
ZIP_OUTPUT_PATH="$(cd "$(dirname "$ZIP_OUTPUT_PATH")" && pwd)/$(basename "$ZIP_OUTPUT_PATH")"

# ----------------- MAIN SCRIPT -----------------

# Create a temporary working directory
TMP_DIR=$(mktemp -d "/tmp/scan_ext_XXXX")
if [ ! -d "$TMP_DIR" ]; then
    echo "Error: Could not create temporary directory."
    exit 1
fi
log "Temporary directory: $TMP_DIR"

DATE_STR=$(date +'%Y%m%d_%H%M%S')
TOP_DIR_NAME="scan-results-${DATE_STR}"
COLLECT_DIR="$TMP_DIR/$TOP_DIR_NAME"
mkdir -p "$COLLECT_DIR"

ZIP_DIR=$(dirname "$ZIP_OUTPUT_PATH")
mkdir -p "$ZIP_DIR"

# By default, searching under /Users.
# Adjust as needed or override via environment variable: USER_BASE_DIR
USER_BASE_DIR="${USER_BASE_DIR:-/Users}"

log "Configured browsers: ${BROWSERS[*]}"
log "Search strings: ${SEARCH_STRINGS[*]}"
echo "Output will be saved to: $ZIP_OUTPUT_PATH"

FOUND_ANY="no"
ALL_JSON=""

MATCHES_FILE="$TMP_DIR/found_strings.txt"
: >"$MATCHES_FILE"
log "Matches file: $MATCHES_FILE"

# -----------------------------
# Enumerate ALL extensions
# -----------------------------
EXT_DIRS=()

log "Enumerating extensions..."
for USER_DIR in "$USER_BASE_DIR"/*; do
    [ ! -d "$USER_DIR" ] && continue

    for BROWSER_INFO in "${BROWSERS[@]}"; do
        BROWSER_PATH="${BROWSER_INFO##*::}"
        FULL_BROWSER_PATH="$USER_DIR/$BROWSER_PATH"

        if [ ! -d "$FULL_BROWSER_PATH" ]; then
            log "Skipping: $FULL_BROWSER_PATH (doesn't exist)"
            continue
        fi

        for PROFILE_DIR in "$FULL_BROWSER_PATH"/Default "$FULL_BROWSER_PATH"/Profile*; do
            [ ! -d "$PROFILE_DIR" ] && continue

            EXT_DIR="$PROFILE_DIR/Extensions"
            DATA_DIR="$PROFILE_DIR/Local Extension Settings"
            [ ! -d "$EXT_DIR" ] && continue

            for EXT_ID_DIR in "$EXT_DIR"/*; do
                [ ! -d "$EXT_ID_DIR" ] && continue

                # Record code & data dirs for scanning
                EXT_DIRS+=("$EXT_ID_DIR")
                local_ext_subdir="$DATA_DIR/$(basename "$EXT_ID_DIR")"
                if [ -d "$local_ext_subdir" ]; then
                    EXT_DIRS+=("$local_ext_subdir")
                fi
            done
        done
    done
done

numExtensionDirs="${#EXT_DIRS[@]}"
echo "Number of extension directories to scan: $numExtensionDirs"
log "Extension dirs: ${EXT_DIRS[*]}"

if [ "$numExtensionDirs" -eq 0 ]; then
    echo "No extensions found to scan."
    rm -rf "$TMP_DIR"
    exit 0
fi

# ----------------------------------------------------
# 1) For each pattern, grep once per pattern using xargs,
#    store matched files in MATCHES_FILE
# ----------------------------------------------------
PATTERN_COUNT=${#SEARCH_STRINGS[@]}
CURRENT_PATTERN_IDX=0

for s in "${SEARCH_STRINGS[@]}"; do
    CURRENT_PATTERN_IDX=$((CURRENT_PATTERN_IDX + 1))
    echo "[$CURRENT_PATTERN_IDX/$PATTERN_COUNT] Searching for pattern: $s"

    patternMatches=()
    # Use xargs to minimize process spawns
    while IFS= read -r matchedFile; do
        patternMatches+=("$matchedFile")
        echo "$matchedFile:::$s" >>"$MATCHES_FILE"
        [ "$VERBOSE" = "true" ] && echo "[VERBOSE] Matched $s in $matchedFile"
    done < <(
        find "${EXT_DIRS[@]}" -type f -print0 2>/dev/null |
            xargs -0 grep -l -F -a -- "$s" 2>/dev/null
    )

    if [ ${#patternMatches[@]} -gt 0 ]; then
        echo "   => Found ${#patternMatches[@]} file(s) containing '$s'"
        if [ "$VERBOSE" = "true" ]; then
            for mf in "${patternMatches[@]}"; do
                echo "      $mf"
            done
        fi
    else
        echo "   => No matches for '$s'"
    fi
done

# If MATCHES_FILE is empty, skip zipping
if [ ! -s "$MATCHES_FILE" ]; then
    echo "No matching extensions found. Not creating zip."
    rm -rf "$TMP_DIR"
    exit 0
fi

# ----------------------------------------------------
# 2) Final pass: go through each extension directory,
#    but parse MATCHES_FILE to see which patterns matched
#    each file (rather than re-grepping).
# ----------------------------------------------------
log "Final pass: building JSON and copying matched extensions..."

for USER_DIR in "$USER_BASE_DIR"/*; do
    [ ! -d "$USER_DIR" ] && continue
    USERNAME=$(basename "$USER_DIR")

    for BROWSER_INFO in "${BROWSERS[@]}"; do
        BROWSER_NAME="${BROWSER_INFO%%::*}"
        BROWSER_PATH="${BROWSER_INFO##*::}"

        FULL_BROWSER_PATH="$USER_DIR/$BROWSER_PATH"
        [ ! -d "$FULL_BROWSER_PATH" ] && continue

        for PROFILE_DIR in "$FULL_BROWSER_PATH"/Default "$FULL_BROWSER_PATH"/Profile*; do
            [ ! -d "$PROFILE_DIR" ] && continue
            PROFILE_NAME=$(basename "$PROFILE_DIR")

            EXT_DIR="$PROFILE_DIR/Extensions"
            DATA_DIR="$PROFILE_DIR/Local Extension Settings"
            [ ! -d "$EXT_DIR" ] && continue

            PREFS_SRC="$PROFILE_DIR/Preferences"

            for EXT_ID_DIR in "$EXT_DIR"/*; do
                [ ! -d "$EXT_ID_DIR" ] && continue
                EXT_ID=$(basename "$EXT_ID_DIR")

                CODE_PATH="$EXT_ID_DIR"
                DATA_PATH="$DATA_DIR/$EXT_ID"
                combinedMatched=""

                extensionStrings=() # holds all matched strings for dedup

                # -------------------------
                # Check extension code
                # -------------------------
                if [ -d "$CODE_PATH" ]; then
                    while IFS= read -r -d $'\0' f; do
                        # Retrieve patterns matched from MATCHES_FILE using awk
                        matchedPatterns=()
                        while IFS= read -r line; do
                            matchedPatterns+=("$line")
                        done < <(
                            grep -F -e "$f:::" "$MATCHES_FILE" |
                                awk -F ':::' '{print $2}'
                        )

                        if [ "${#matchedPatterns[@]}" -gt 0 ]; then
                            arr="["
                            first="yes"
                            for ms in "${matchedPatterns[@]}"; do
                                if [ "$first" = "yes" ]; then
                                    arr="$arr\"$ms\""
                                    first="no"
                                else
                                    arr="$arr,\"$ms\""
                                fi
                                extensionStrings+=("$ms")
                            done
                            arr="$arr]"
                            combinedMatched+="$f:::$arr"$'\n'
                        fi
                    done < <(find "$CODE_PATH" -type f -print0 2>/dev/null)
                fi

                # -------------------------
                # Check extension data
                # -------------------------
                if [ -d "$DATA_PATH" ]; then
                    while IFS= read -r -d $'\0' f; do
                        # Retrieve patterns matched from MATCHES_FILE
                        matchedPatterns=()
                        while IFS= read -r line; do
                            matchedPatterns+=("$line")
                        done < <(
                            grep -F -e "$f:::" "$MATCHES_FILE" |
                                awk -F ':::' '{print $2}'
                        )

                        if [ "${#matchedPatterns[@]}" -gt 0 ]; then
                            arr="["
                            first="yes"
                            for ms in "${matchedPatterns[@]}"; do
                                if [ "$first" = "yes" ]; then
                                    arr="$arr\"$ms\""
                                    first="no"
                                else
                                    arr="$arr,\"$ms\""
                                fi
                                extensionStrings+=("$ms")
                            done
                            arr="$arr]"
                            combinedMatched+="$f:::$arr"$'\n'
                        fi
                    done < <(find "$DATA_PATH" -type f -print0 2>/dev/null)
                fi

                # Skip if no matches for this extension
                if [ -z "$combinedMatched" ]; then
                    continue
                fi

                FOUND_ANY="yes"

                # ----------------------------
                # Deduplicate extensionStrings
                # using sort -u
                # ----------------------------
                sortedList=$(printf "%s\n" "${extensionStrings[@]}" | sort -u)
                uniqueStrings=()
                while IFS= read -r line; do
                    uniqueStrings+=("$line")
                done <<<"$sortedList"

                # Format them for printing
                matchedStrList="[${uniqueStrings[*]}]"

                echo "=> Matched extension: $EXT_ID (user=$USERNAME, browser=$BROWSER_NAME, profile=$PROFILE_NAME)"
                echo "   Matched strings: $matchedStrList"

                # ----------------------------------------------
                # Copy extension files to the output directory
                # ----------------------------------------------
                DEST_DIR="$COLLECT_DIR/$USERNAME/$BROWSER_NAME/$PROFILE_NAME/$EXT_ID"
                mkdir -p "$DEST_DIR"

                # Copy extension code
                if [ -d "$CODE_PATH" ]; then
                    mkdir -p "$DEST_DIR/extension_code"
                    cp -R "$CODE_PATH/"* "$DEST_DIR/extension_code/" 2>/dev/null
                fi

                # Copy extension data
                if [ -d "$DATA_PATH" ]; then
                    mkdir -p "$DEST_DIR/extension_data"
                    cp -R "$DATA_PATH/"* "$DEST_DIR/extension_data/" 2>/dev/null
                fi

                # --------------------------------------------
                # Extract only extension settings from Preferences
                # --------------------------------------------
                if [ -f "$PREFS_SRC" ]; then
                    jq '.extensions.settings // {}' "$PREFS_SRC" \
                        >"$DEST_DIR/extension_settings.json" 2>/dev/null
                fi

                # ----------------------------
                # Build partial JSON summary
                # ----------------------------
                sortedLines=$(echo "$combinedMatched" | sed '/^$/d' | sort -u)
                matchObjs="["
                firstFile="yes"
                while IFS= read -r line; do
                    filePart="${line%%:::*}"
                    strJson="${line##*:::}"
                    if [ "$firstFile" = "yes" ]; then
                        matchObjs="$matchObjs{\"file\":\"$filePart\",\"strings\":$strJson}"
                        firstFile="no"
                    else
                        matchObjs="$matchObjs,{\"file\":\"$filePart\",\"strings\":$strJson}"
                    fi
                done <<<"$sortedLines"
                matchObjs="$matchObjs]"

                EXT_JSON="{
  \"user\": \"$USERNAME\",
  \"browser\": \"$BROWSER_NAME\",
  \"profile\": \"$PROFILE_NAME\",
  \"extensionId\": \"$EXT_ID\",
  \"matches\": $matchObjs
}"
                if [ -z "$ALL_JSON" ]; then
                    ALL_JSON="$EXT_JSON"
                else
                    ALL_JSON="$ALL_JSON,$EXT_JSON"
                fi
            done
        done
    done
done

if [ "$FOUND_ANY" = "no" ]; then
    echo "No matching extensions found after final check. Not creating zip."
    rm -rf "$TMP_DIR"
    exit 0
fi

# -------------- Add Serial Number + Hostname --------------
SERIAL_NUMBER=$(system_profiler SPHardwareDataType 2>/dev/null | awk '/Serial Number/{print $4}')
HOSTNAME=$(hostname)

# -------------- Final JSON & ZIP --------------
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FINAL_JSON="{
  \"timestamp\": \"$TIMESTAMP\",
  \"serial_number\": \"$SERIAL_NUMBER\",
  \"hostname\": \"$HOSTNAME\",
  \"found\": [
    $ALL_JSON
  ]
}"

JSON_FILE="$COLLECT_DIR/scan_result.json"
echo "$FINAL_JSON" >"$JSON_FILE"
echo "Wrote JSON summary to: $JSON_FILE"

echo "Creating zip at: $ZIP_OUTPUT_PATH"
cd "$TMP_DIR" || exit 1
zip -r -q "$ZIP_OUTPUT_PATH" "$TOP_DIR_NAME"
if [ $? -eq 0 ]; then
    echo "Successfully created zip: $ZIP_OUTPUT_PATH"
else
    echo "Error creating zip."
fi

cd / || exit 1
rm -rf "$TMP_DIR"
echo "Removed temp directory: $TMP_DIR"
echo "Done."
