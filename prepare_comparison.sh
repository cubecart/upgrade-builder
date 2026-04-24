#!/bin/bash

# This script:
# - Reads CubeCart version and admin paths from an existing install
# - Fetches latest version from cubecart.com
# - Extracts both versions
# - Renames admin folder + admin file
# - Auto-downloads missing archives from GitHub (zipball)
# - Organises everything under DOWNLOAD_DIR/PREFIX:
#     PREFIX/FROM_VERSION
#     PREFIX/TO_VERSION
#     PREFIX/source

set -euo pipefail
# Force writable working directory (the folder this script lives in)
cd "$(dirname "$0")"

DOWNLOAD_DIR="$HOME/Downloads"

# Get INSTALL_PATH either from first argument (app) or prompt (terminal)
INSTALL_PATH="${1-}"

if [ -z "$INSTALL_PATH" ]; then
    echo "Enter full path to existing CubeCart installation (e.g. /var/www/html/shop):"
    read -r INSTALL_PATH
fi

# Now it's safe to use INSTALL_PATH
if [ ! -d "$INSTALL_PATH" ]; then
    echo "ERROR: Directory '$INSTALL_PATH' does not exist."
    exit 1
fi

if [ ! -f "$INSTALL_PATH/ini.inc.php" ]; then
    echo "ERROR: '$INSTALL_PATH/ini.inc.php' is missing."
    exit 1
fi

############################################
# Prompt for prefix (domain) for extracted folders
############################################
# Allow optional second CLI arg as prefix (for app/automation use),
# otherwise prompt interactively.
PREFIX="${2-}"

if [ -z "$PREFIX" ]; then
    echo "Enter store domain: (e.g. example.com)"
    read -r PREFIX
fi

# Normalise: spaces -> underscores (safer for folder names)
PREFIX_SANITISED="${PREFIX// /_}"

# Root folder where everything goes:
#   /Users/al/Downloads/example.com
if [ -n "$PREFIX_SANITISED" ]; then
    ARCHIVE_ROOT="${DOWNLOAD_DIR}/${PREFIX_SANITISED}"
else
    ARCHIVE_ROOT="${DOWNLOAD_DIR}"
fi

mkdir -p "$ARCHIVE_ROOT"

############################################
# 1) Get FROM_VERSION
############################################
FROM_VERSION=$(grep -E "define\(['\"]CC_VERSION['\"]" "$INSTALL_PATH/ini.inc.php" \
    | head -n1 \
    | sed -E "s/.*CC_VERSION['\"], *['\"]([^'\"]+)['\"].*/\1/")

if [ -z "$FROM_VERSION" ]; then
    echo "ERROR: Could not find CC_VERSION in ini.inc.php"
    exit 1
fi

############################################
# 2) Detect admin directory
############################################
ADMIN_DIR_PATH=$(find "$INSTALL_PATH" -maxdepth 1 -type d -name "admin_*" | head -n1 || true)
if [ -z "$ADMIN_DIR_PATH" ] && [ -d "$INSTALL_PATH/admin" ]; then
    ADMIN_DIR_PATH="$INSTALL_PATH/admin"
fi
if [ -z "$ADMIN_DIR_PATH" ]; then
    echo "ERROR: No admin directory found."
    exit 1
fi
ADMIN_FOLDER=$(basename "$ADMIN_DIR_PATH")

############################################
# 3) Detect admin file
############################################
ADMIN_FILE_PATH=$(find "$INSTALL_PATH" -maxdepth 1 -type f -name "admin_*.php" | head -n1 || true)
if [ -z "$ADMIN_FILE_PATH" ] && [ -f "$INSTALL_PATH/admin.php" ]; then
    ADMIN_FILE_PATH="$INSTALL_PATH/admin.php"
fi
if [ -z "$ADMIN_FILE_PATH" ]; then
    echo "ERROR: No admin file found."
    exit 1
fi
ADMIN_FILE=$(basename "$ADMIN_FILE_PATH")

############################################
# 4) Fetch latest CubeCart version from GitHub
############################################
TO_VERSION=$(curl -fsS "https://api.github.com/repos/cubecart/v6/releases/latest" \
    | grep '"tag_name"' \
    | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/' \
    | tr -d '\r\n' || true)

if [ -z "$TO_VERSION" ]; then
    echo "ERROR: Could not fetch latest version from GitHub."
    exit 1
fi

############################################
# SHOW DISCOVERED VALUES
############################################
echo
echo "Detected:"
echo "  FROM_VERSION : $FROM_VERSION"
echo "  TO_VERSION   : $TO_VERSION"
echo "  ADMIN_FOLDER : $ADMIN_FOLDER"
echo "  ADMIN_FILE   : $ADMIN_FILE"
echo "  PREFIX       : ${PREFIX_SANITISED:-<none>}"
echo "  ARCHIVE_ROOT : $ARCHIVE_ROOT"
echo

############################################
# Auto-download if archive missing
############################################
download_if_missing() {
    local version="$1"
    local zip_file="${DOWNLOAD_DIR}/CubeCart-${version}.zip"

    if [ -f "$zip_file" ]; then
        return
    fi

    echo "Downloading CubeCart ${version} from GitHub..."
    curl -fsSLo "$zip_file" "https://api.github.com/repos/cubecart/v6/zipball/${version}" || {
        echo "ERROR: Failed to download CubeCart ${version} from GitHub"
        exit 1
    }
}

download_if_missing "$FROM_VERSION"
download_if_missing "$TO_VERSION"

############################################
# Process extraction + admin renaming
# Extract to:
#   ARCHIVE_ROOT/<version>
############################################
process_version() {
    local version="$1"
    local zip_file="${DOWNLOAD_DIR}/CubeCart-${version}.zip"
    local root_dir="${ARCHIVE_ROOT}/${version}"

    # If version dir already exists, remove it
    if [ -d "$root_dir" ]; then
        rm -rf "$root_dir"
    fi

    mkdir -p "$root_dir"

    unzip -q "$zip_file" -d "$root_dir"

    # Remove ZIP after extraction
    rm -f "$zip_file"

    # GitHub zipballs extract into a subfolder (e.g. cubecart-v6-abc1234/)
    # Flatten: move contents up and remove the subfolder
    local subfolder
    subfolder=$(find "$root_dir" -maxdepth 1 -mindepth 1 -type d | head -n1 || true)
    if [ -n "$subfolder" ] && [ "$(ls -A "$root_dir" | wc -l)" -eq 1 ]; then
        mv "$subfolder"/* "$root_dir"/
        rmdir "$subfolder"
    fi

    # Rename admin directory
    if [ -d "$root_dir/admin" ]; then
        if [ "$ADMIN_FOLDER" != "admin" ]; then
            mv "$root_dir/admin" "$root_dir/$ADMIN_FOLDER"
        fi
    fi

    # Rename admin.php
    if [ -f "$root_dir/admin.php" ]; then
        if [ "$ADMIN_FILE" != "admin.php" ]; then
            mv "$root_dir/admin.php" "$root_dir/$ADMIN_FILE"
        fi
    fi
}

process_version "$FROM_VERSION"
process_version "$TO_VERSION"

############################################
# Copy source to ARCHIVE_ROOT/source
############################################
SOURCE_DIR="${ARCHIVE_ROOT}/source"
if [ -d "$SOURCE_DIR" ]; then
    rm -rf "$SOURCE_DIR"
fi

mkdir -p "$SOURCE_DIR"
# Copy live install into source (trailing slashes important)
rsync -a "$INSTALL_PATH"/ "$SOURCE_DIR"/

echo
echo "Compare from (live):"
echo "  $INSTALL_PATH"
echo
echo "Prepared versions under:"
echo "  $ARCHIVE_ROOT"
echo "    source      -> copy of live install"
echo "    $FROM_VERSION -> FROM_VERSION extracted"
echo "    $TO_VERSION   -> TO_VERSION extracted"

############################################
# Auto-apply customisations to latest version
############################################
FROM_DIR="${ARCHIVE_ROOT}/${FROM_VERSION}"
TO_DIR="${ARCHIVE_ROOT}/${TO_VERSION}"
CUSTOM_PATCH="${ARCHIVE_ROOT}/customisations_${FROM_VERSION}.patch"
UPGRADED_DIR="${ARCHIVE_ROOT}/upgraded"

echo

# Generate customisation patch (stock FROM -> source = user's changes)
# Only compare files that exist in stock FROM to avoid cache/uploads/non-app files
# Normalise CRLF -> LF before diffing to ignore line-ending differences
echo "Generating customisation patch (stock ${FROM_VERSION} -> source)..."
NORM_FROM=$(mktemp -d)
NORM_SRC=$(mktemp -d)
# Build file list of stock files that also exist in source
COMMON_FILES=$(mktemp)
(cd "$FROM_DIR" && find . -type f | sed 's|^\./||') | while IFS= read -r f; do
    if [ -f "${SOURCE_DIR}/$f" ]; then echo "$f"; fi
done > "$COMMON_FILES"
# Copy matching files into normalised trees
rsync -a --files-from="$COMMON_FILES" "$FROM_DIR/" "$NORM_FROM/"
rsync -a --files-from="$COMMON_FILES" "$SOURCE_DIR/" "$NORM_SRC/"
rm -f "$COMMON_FILES"
# Bulk-normalise CRLF in text files only — `grep -qI .` skips binaries so images/fonts aren't stripped of 0x0D bytes
find "$NORM_FROM" "$NORM_SRC" -type f -print0 | xargs -0 -P4 -I{} sh -c 'if grep -qI . "$1" 2>/dev/null; then LC_ALL=C tr -d "\r" < "$1" > "$1.tmp" && mv "$1.tmp" "$1"; fi' _ {}
# Bulk diff the normalised trees
diff -ruN "$NORM_FROM" "$NORM_SRC" \
    | sed "s|${NORM_FROM}/|a/|g; s|${NORM_SRC}/|b/|g" \
    > "$CUSTOM_PATCH" 2>/dev/null || true
rm -rf "$NORM_FROM" "$NORM_SRC"
CUSTOM_LINES=$(wc -l < "$CUSTOM_PATCH" | tr -d ' ')

if [ "$CUSTOM_LINES" -eq 0 ]; then
    rm -f "$CUSTOM_PATCH"
    echo "  No customisations detected."
    echo
    echo "Your source matches stock ${FROM_VERSION}."
    echo "Simply deploy the ${TO_VERSION} folder as your upgrade."

    REPORT="${ARCHIVE_ROOT}/REPORT.txt"
    {
        echo "CubeCart Upgrade Report"
        echo "======================"
        echo "From: ${FROM_VERSION}"
        echo "To:   ${TO_VERSION}"
        echo "Date: $(date +%Y-%m-%d\ %H:%M:%S)"
        echo
        echo "No customisations detected. Your source matches stock ${FROM_VERSION}."
        echo "Simply deploy the ${TO_VERSION} folder as your upgrade."
    } > "$REPORT"
    echo
    echo "Report: $REPORT"
else
    echo "  $CUSTOM_PATCH ($CUSTOM_LINES lines)"
    # Start with a copy of stock TO_VERSION (latest release), normalised to LF
    if [ -d "$UPGRADED_DIR" ]; then
        rm -rf "$UPGRADED_DIR"
    fi
    cp -a "$TO_DIR" "$UPGRADED_DIR"
    find "$UPGRADED_DIR" -type f -print0 | xargs -0 -P4 -I{} sh -c 'if grep -qI . "$1" 2>/dev/null; then LC_ALL=C tr -d "\r" < "$1" > "$1.tmp" && mv "$1.tmp" "$1"; fi' _ {};

    # Dry-run the customisation patch against latest stock
    echo
    echo "Applying your customisations to stock ${TO_VERSION} (dry run)..."
    DRY_RUN_EXIT=0
    DRY_RUN_OUTPUT=$(patch -p1 --dry-run --forward -d "$UPGRADED_DIR" < "$CUSTOM_PATCH" 2>&1) || DRY_RUN_EXIT=$?

    # Parse results
    PATCHED_FILES=$(echo "$DRY_RUN_OUTPUT" | grep -E "^patching file " | sed 's/^patching file //' || true)

    PATCHED_COUNT=0
    if [ -n "$PATCHED_FILES" ]; then
        PATCHED_COUNT=$(echo "$PATCHED_FILES" | grep -c . 2>/dev/null || echo 0)
    fi

    # Parse dry-run results into clean and failed lists
    eval "$(echo "$DRY_RUN_OUTPUT" | awk '
        /^patching file / {
            if (current_file != "" && !has_fail) clean[clean_count++] = current_file
            if (current_file != "" && has_fail) fail[fail_count++] = current_file
            current_file = $0; sub(/^patching file /, "", current_file)
            gsub(/'\''/, "", current_file)
            has_fail = 0
        }
        /failed|FAILED|No file found/ { has_fail = 1 }
        END {
            if (current_file != "" && !has_fail) clean[clean_count++] = current_file
            if (current_file != "" && has_fail) fail[fail_count++] = current_file
            print "CLEAN_COUNT=" clean_count
            print "FAIL_COUNT=" fail_count
            printf "CLEAN_LIST='"'"'"
            for (i = 0; i < clean_count; i++) print "  ✓ " clean[i]
            printf "'"'"'\n"
            printf "FAIL_LIST='"'"'"
            for (i = 0; i < fail_count; i++) print "  ✗ " fail[i]
            printf "'"'"'\n"
        }
    ')"

    # Apply customisations (skip rejects gracefully)
    patch -p1 --forward --no-backup-if-mismatch --reject-file=- -d "$UPGRADED_DIR" < "$CUSTOM_PATCH" > /dev/null 2>&1 || true
    find "$UPGRADED_DIR" -type f \( -name "*.orig" -o -name "*.rej" \) -delete 2>/dev/null

    # Generate final diff: stock TO (normalised) vs upgraded
    FINAL_PATCH="${ARCHIVE_ROOT}/upgrade_${TO_VERSION}_to_upgraded.patch"
    NORM_TO=$(mktemp -d)
    cp -a "$TO_DIR" "$NORM_TO/to"
    find "$NORM_TO/to" -type f -print0 | xargs -0 -P4 -I{} sh -c 'if grep -qI . "$1" 2>/dev/null; then LC_ALL=C tr -d "\r" < "$1" > "$1.tmp" && mv "$1.tmp" "$1"; fi' _ {}
    diff -ruN "$NORM_TO/to" "$UPGRADED_DIR" \
        | sed "s|${NORM_TO}/to|a|g; s|${UPGRADED_DIR}|b|g" \
        > "$FINAL_PATCH" 2>/dev/null || true
    rm -rf "$NORM_TO"
    FINAL_LINES=$(wc -l < "$FINAL_PATCH" | tr -d ' ')

    # Write report file
    REPORT="${ARCHIVE_ROOT}/REPORT.txt"
    {
        echo "CubeCart Upgrade Report"
        echo "======================"
        echo "From: ${FROM_VERSION}"
        echo "To:   ${TO_VERSION}"
        echo "Date: $(date +%Y-%m-%d\ %H:%M:%S)"
        echo
        if [ "${CLEAN_COUNT:-0}" -gt 0 ]; then
            echo "Customisations applied cleanly (${CLEAN_COUNT}):"
            printf '%s\n' "$CLEAN_LIST"
            echo
        fi
        if [ "${FAIL_COUNT:-0}" -gt 0 ]; then
            echo "*** CONFLICTS - NEED MANUAL MERGING (${FAIL_COUNT}) ***"
            printf '%s\n' "$FAIL_LIST"
            echo
            echo "These customisations could not be applied automatically because"
            echo "the surrounding code changed between ${FROM_VERSION} and ${TO_VERSION}."
            echo "Review customisations_${FROM_VERSION}.patch and apply them by hand."
        else
            echo "All customisations applied successfully."
        fi
    } > "$REPORT"

    echo
    if [ "${FAIL_COUNT:-0}" -gt 0 ]; then
        echo "===== PARTIAL UPGRADE — CONFLICTS ON ${FAIL_COUNT} FILE(S) ====="
    else
        echo "===== CUSTOMISATIONS APPLIED SUCCESSFULLY ====="
    fi
    if [ "${CLEAN_COUNT:-0}" -gt 0 ]; then
        echo
        echo "Customisations applied cleanly (${CLEAN_COUNT}):"
        printf '%s\n' "$CLEAN_LIST"
    fi
    if [ "${FAIL_COUNT:-0}" -gt 0 ]; then
        echo
        echo "Customisations that NEED MANUAL MERGING (${FAIL_COUNT}):"
        printf '%s\n' "$FAIL_LIST"
    fi
    echo
    echo "Upgraded copy created at:"
    echo "  $UPGRADED_DIR  (stock ${TO_VERSION} + applied customisations)"
    if [ "$FINAL_LINES" -gt 0 ]; then
        echo
        echo "Differences vs stock ${TO_VERSION}:"
        echo "  $FINAL_PATCH ($FINAL_LINES lines)"
    fi
    echo
    echo "Report: $REPORT"
fi

# Play completion sound
afplay /System/Library/Sounds/Glass.aiff &