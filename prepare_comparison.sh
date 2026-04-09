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

    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

    # If version dir already exists, back it up
    if [ -d "$root_dir" ]; then
        local backup_dir="${root_dir}_${timestamp}"
        mv "$root_dir" "$backup_dir"
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
timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

if [ -d "$SOURCE_DIR" ]; then
    mv "$SOURCE_DIR" "${SOURCE_DIR}_${timestamp}"
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
UPGRADE_PATCH="${ARCHIVE_ROOT}/upgrade_${FROM_VERSION}_to_${TO_VERSION}.patch"
CUSTOM_PATCH="${ARCHIVE_ROOT}/customisations_${FROM_VERSION}.patch"
UPGRADED_DIR="${ARCHIVE_ROOT}/upgraded"

echo

# Generate upgrade patch (stock FROM -> stock TO) for reference
echo "Generating upgrade patch (${FROM_VERSION} -> ${TO_VERSION})..."
diff -ruN "$FROM_DIR" "$TO_DIR" \
    | sed "s|${FROM_DIR}|a|g; s|${TO_DIR}|b|g" \
    > "$UPGRADE_PATCH" 2>/dev/null || true
UPGRADE_LINES=$(wc -l < "$UPGRADE_PATCH" | tr -d ' ')
echo "  $UPGRADE_PATCH ($UPGRADE_LINES lines)"

# Generate customisation patch (stock FROM -> source = user's changes)
# Only compare files that exist in stock FROM to avoid cache/uploads/non-app files
# Normalise CRLF -> LF before diffing to ignore line-ending differences
echo "Generating customisation patch (stock ${FROM_VERSION} -> source)..."
NORM_FROM=$(mktemp -d)
NORM_SRC=$(mktemp -d)
> "$CUSTOM_PATCH"
while IFS= read -r rel_path; do
    source_file="${SOURCE_DIR}/${rel_path}"
    if [ -f "$source_file" ]; then
        mkdir -p "$(dirname "$NORM_FROM/$rel_path")" "$(dirname "$NORM_SRC/$rel_path")"
        tr -d '\r' < "$FROM_DIR/$rel_path" > "$NORM_FROM/$rel_path"
        tr -d '\r' < "$source_file" > "$NORM_SRC/$rel_path"
        file_diff=$(diff -u "$NORM_FROM/$rel_path" "$NORM_SRC/$rel_path" 2>/dev/null \
            | sed "s|${NORM_FROM}/|a/|g; s|${NORM_SRC}/|b/|g") || true
        if [ -n "$file_diff" ]; then
            printf '%s\n' "$file_diff" >> "$CUSTOM_PATCH"
        fi
    fi
done < <(cd "$FROM_DIR" && find . -type f | sed 's|^\./||' | sort)
rm -rf "$NORM_FROM" "$NORM_SRC"
CUSTOM_LINES=$(wc -l < "$CUSTOM_PATCH" | tr -d ' ')
echo "  $CUSTOM_PATCH ($CUSTOM_LINES lines)"

if [ "$CUSTOM_LINES" -eq 0 ]; then
    echo
    echo "No customisations detected. Your source matches stock ${FROM_VERSION}."
    echo "Simply use the stock ${TO_VERSION} as your upgrade."
else
    # Start with a copy of stock TO_VERSION (latest release), normalised to LF
    if [ -d "$UPGRADED_DIR" ]; then
        mv "$UPGRADED_DIR" "${UPGRADED_DIR}_${timestamp}"
    fi
    cp -a "$TO_DIR" "$UPGRADED_DIR"
    find "$UPGRADED_DIR" -type f \( -name "*.php" -o -name "*.js" -o -name "*.css" -o -name "*.html" -o -name "*.htm" -o -name "*.tpl" -o -name "*.xml" -o -name "*.json" -o -name "*.sql" -o -name "*.txt" -o -name "*.htaccess" -o -name "*.md" \) \
        -exec sh -c 'tr -d "\r" < "$1" > "$1.tmp" && mv "$1.tmp" "$1"' _ {} \;

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

    if [ "$DRY_RUN_EXIT" -eq 0 ]; then
        # Apply customisations for real
        patch -p1 --forward -d "$UPGRADED_DIR" < "$CUSTOM_PATCH" > /dev/null 2>&1

        echo
        echo "===== CUSTOMISATIONS APPLIED SUCCESSFULLY ====="
        if [ "$PATCHED_COUNT" -gt 0 ]; then
            echo
            echo "Customised files applied ($PATCHED_COUNT):"
            echo "$PATCHED_FILES" | sed "s/^/  ✓ /"
        fi

        # Generate a final diff: stock TO vs upgraded (for review)
        FINAL_PATCH="${ARCHIVE_ROOT}/upgrade_${TO_VERSION}_to_upgraded.patch"
        diff -ruN "$TO_DIR" "$UPGRADED_DIR" \
            | sed "s|${TO_DIR}|a|g; s|${UPGRADED_DIR}|b|g" \
            > "$FINAL_PATCH" 2>/dev/null || true
        FINAL_LINES=$(wc -l < "$FINAL_PATCH" | tr -d ' ')

        echo
        echo "Upgraded copy created at:"
        echo "  $UPGRADED_DIR  (stock ${TO_VERSION} + your customisations)"
        if [ "$FINAL_LINES" -gt 0 ]; then
            echo
            echo "Differences vs stock ${TO_VERSION}:"
            echo "  $FINAL_PATCH ($FINAL_LINES lines)"
        fi
        echo
        echo "Review the upgraded copy, then deploy it to replace your live install."
    else
        # Conflicts detected — apply what we can, skip the rest
        echo "Conflicts detected — applying clean patches, skipping conflicts..."
        APPLY_OUTPUT=$(patch -p1 --forward --reject-file=- -d "$UPGRADED_DIR" < "$CUSTOM_PATCH" 2>&1) || true

        # Parse results into clean and failed lists
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

        # Generate final diff: stock TO vs upgraded
        FINAL_PATCH="${ARCHIVE_ROOT}/upgrade_${TO_VERSION}_to_upgraded.patch"
        diff -ruN "$TO_DIR" "$UPGRADED_DIR" \
            | sed "s|${TO_DIR}|a|g; s|${UPGRADED_DIR}|b|g" \
            > "$FINAL_PATCH" 2>/dev/null || true
        FINAL_LINES=$(wc -l < "$FINAL_PATCH" | tr -d ' ')

        echo
        echo "===== PARTIAL UPGRADE — CONFLICTS ON ${FAIL_COUNT} FILE(S) ====="
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
        echo "  $UPGRADED_DIR  (stock ${TO_VERSION} + clean customisations)"
        if [ "$FINAL_LINES" -gt 0 ]; then
            echo
            echo "Differences vs stock ${TO_VERSION}:"
            echo "  $FINAL_PATCH ($FINAL_LINES lines)"
        fi
        echo
        echo "Patch files for manual review:"
        echo "  $CUSTOM_PATCH  (your customisations)"
        echo "  $UPGRADE_PATCH  (stock upgrade)"
        echo
        echo "Resolve the conflicting file(s) manually, then deploy."
    fi
fi