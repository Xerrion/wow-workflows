#!/usr/bin/env bash
###############################################################################
# update_toc_versions.sh
# Fetches latest WoW interface versions from Blizzard's CDN and updates
# ## Interface directives in .toc files.
#
# Usage:  bash scripts/update_toc_versions.sh [--flavor FLAVOR]...
# Env:    None required (all config via CLI args)
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly CDN_BASE="https://us.version.battle.net/v2/products"
readonly MAX_RETRIES=5
readonly RETRY_DELAY=2
readonly VALID_FLAVORS=("retail" "classic" "vanilla" "tbc")
readonly DEFAULT_EXCLUDE_DIRS=("Libs")
DRY_RUN=false

# Platform-aware in-place sed (BSD sed requires an explicit backup suffix)
if sed --version 2>/dev/null | grep -q 'GNU'; then
    sedi() { sed -i "$@"; }
else
    sedi() { sed -i '' "$@"; }
fi

# ---------------------------------------------------------------------------
# version_to_flavor - Map an interface version number to its flavor name
#
# Args: $1 = interface version string (e.g. "120001", "50502", "11503")
# Returns: flavor name via stdout ("retail", "classic", "vanilla", "tbc",
#          "cata", "wrath", or "unknown")
# ---------------------------------------------------------------------------
version_to_flavor() {
    [[ "$1" =~ ^[0-9]+$ ]] || { echo "unknown"; return 0; }
    local ver=$(( 10#$1 ))

    if (( ver >= 100000 )); then echo "retail"
    elif (( ver >= 50000 )); then echo "classic"
    elif (( ver >= 40000 )); then echo "cata"
    elif (( ver >= 30000 )); then echo "wrath"
    elif (( ver >= 20000 )); then echo "tbc"
    elif (( ver >= 10000 )); then echo "vanilla"
    else echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# Version cache - avoid fetching the same CDN product twice
# ---------------------------------------------------------------------------
declare -A VERSION_CACHE

# ---------------------------------------------------------------------------
# usage - Print help text and exit
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: bash scripts/update_toc_versions.sh [OPTIONS]

Fetches latest WoW interface versions from Blizzard's CDN and updates
## Interface directives in .toc files.

Options:
  --flavor FLAVOR       Flavor to update (can be specified multiple times)
                        Valid: retail, classic, vanilla, tbc
                        Default: all flavors
  --path DIR            Directory to search for .toc files (default: current directory)
  --exclude-dir DIR     Directory to exclude from TOC search (can be specified
                        multiple times). Default: Libs
  --dry-run             Show what would change without modifying files
  --help                Show this help message

Examples:
  bash scripts/update_toc_versions.sh
  bash scripts/update_toc_versions.sh --flavor retail --flavor classic
  bash scripts/update_toc_versions.sh --path /path/to/addons
  bash scripts/update_toc_versions.sh --exclude-dir Libs --exclude-dir vendor
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# fetch_version - Fetch interface version for a CDN product
#
# Args: $1 = CDN product name (e.g. "wow", "wow_classic")
# Returns: interface version number via stdout (e.g. "120005")
# ---------------------------------------------------------------------------
fetch_version() {
    local product="$1"

    # Return cached result if available
    if [[ -n "${VERSION_CACHE[$product]:-}" ]]; then
        echo "${VERSION_CACHE[$product]}"
        return 0
    fi

    local url="${CDN_BASE}/${product}/versions"
    local attempt=0
    local response=""

    while (( attempt < MAX_RETRIES )); do
        attempt=$((attempt + 1))
        response=$(curl -sf --connect-timeout 10 --max-time 30 "$url" 2>/dev/null) && break

        if (( attempt < MAX_RETRIES )); then
            echo "  Attempt ${attempt}/${MAX_RETRIES} failed, retrying in ${RETRY_DELAY}s..." >&2
            sleep "$RETRY_DELAY"
        fi
    done

    if [[ -z "$response" ]]; then
        echo "ERROR: Failed to fetch version for ${product} after ${MAX_RETRIES} attempts" >&2
        return 1
    fi

    # Parse header row to find VersionsName column index dynamically.
    # Header fields have type suffixes (e.g. "VersionsName!STRING:0") which we strip.
    local col_index=""
    col_index=$(echo "$response" | head -1 | awk -F'|' '{
        for (i = 1; i <= NF; i++) {
            name = $i
            sub(/!.*/, "", name)
            if (name == "VersionsName") { print i; exit }
        }
    }')

    if [[ -z "$col_index" ]]; then
        echo "ERROR: VersionsName column not found in CDN response header for ${product}" >&2
        return 1
    fi

    local versions_name=""
    versions_name=$(echo "$response" | awk -F'|' -v col="$col_index" '$1 == "us" { print $col }')

    if [[ -z "$versions_name" ]]; then
        echo "ERROR: Could not parse US region version for ${product}" >&2
        return 1
    fi

    # Strip build number: "12.0.1.66337" -> "12.0.1"
    local game_version=""
    game_version=$(echo "$versions_name" | awk -F. '{print $1"."$2"."$3}')

    # Convert to interface version: "12.0.1" -> "120001"
    local interface_version=""
    interface_version=$(echo "$game_version" | awk -F. '{printf "%d%02d%02d\n", $1, $2, $3}')

    # Validate interface version is a 5-6 digit number
    if [[ ! "$interface_version" =~ ^[0-9]{5,6}$ ]]; then
        echo "ERROR: Invalid interface version '${interface_version}' for ${product} (expected 5-6 digits)" >&2
        return 1
    fi

    # Cache the result
    VERSION_CACHE[$product]="$interface_version"

    echo "$interface_version"
}

# ---------------------------------------------------------------------------
# find_toc_files - Discover .toc files, excluding specified directories
#
# Args: $1 = directory to search
#        $2.. = directories to exclude
# Returns: list of toc file paths via stdout
# ---------------------------------------------------------------------------
find_toc_files() {
    local search_dir="$1"
    shift
    local exclude_dirs=("$@")
    local find_args=()

    find_args+=("$search_dir" "-name" "*.toc")

    for dir in "${exclude_dirs[@]}"; do
        find_args+=("-not" "-path" "*/${dir}/*")
    done

    find "${find_args[@]}"
}

# ---------------------------------------------------------------------------
# update_toc_directive - Update a single directive in a TOC file if it exists,
#                        preserving comma-separated multi-value lists.
#
# Args: $1 = toc file path
#        $2 = directive suffix (empty string for "## Interface:", or e.g. "-Mists")
#        $3 = new version value
#        $4 = target flavor (e.g. "retail", "classic") - used to identify which
#             value to replace in bare "## Interface:" multi-value lists
# Returns: 0 if updated, 1 if directive not found or unchanged
# ---------------------------------------------------------------------------
update_toc_directive() {
    local toc_file="$1"
    local suffix="$2"
    local version="$3"
    local target_flavor="$4"

    local directive="## Interface${suffix}:"

    # Guard: directive must exist in the file
    if ! grep -q "^## Interface${suffix}: " "$toc_file"; then
        return 1
    fi

    # Read the current full value string for parsing
    local current_value=""
    current_value=$(grep -m 1 "^## Interface${suffix}: " "$toc_file" | sed "s/^## Interface${suffix}: //")

    # Parse comma-separated values into an array, trimming whitespace and \r
    local values=()
    local IFS=','
    for val in $current_value; do
        val=$(echo "$val" | tr -d ' \r')
        [[ -n "$val" ]] && values+=("$val")
    done
    unset IFS

    # Guard: if the new version already appears anywhere, nothing to do
    for val in "${values[@]}"; do
        if [[ "$val" == "$version" ]]; then
            echo "  ${directive} ${current_value} (unchanged)"
            return 1
        fi
    done

    # Build the replacement value list
    local new_values=()
    local replaced=false

    if [[ -n "$suffix" ]]; then
        # Flavor-specific directive: all values share the same flavor.
        # Replace only the FIRST value, keep the rest as-is.
        new_values=("$version" "${values[@]:1}")
        replaced=true
    else
        # Bare "## Interface:" - values can belong to different flavors.
        # Replace only the FIRST value whose flavor matches target_flavor.
        for (( i = 0; i < ${#values[@]}; i++ )); do
            local val_flavor
            val_flavor=$(version_to_flavor "${values[$i]}")
            if [[ "$replaced" != "true" ]] && [[ "$val_flavor" == "$target_flavor" ]]; then
                new_values+=("$version")
                replaced=true
            else
                new_values+=("${values[$i]}")
            fi
        done
    fi

    # Guard: if no value was replaced, don't modify the file
    if [[ "$replaced" != "true" ]]; then
        return 1
    fi

    # Reconstruct the replacement line with consistent ", " spacing
    local joined=""
    for (( i = 0; i < ${#new_values[@]}; i++ )); do
        if (( i > 0 )); then
            joined+=", "
        fi
        joined+="${new_values[$i]}"
    done
    local replacement="## Interface${suffix}: ${joined}"
    local pattern="^## Interface${suffix}: .*$"

    # Perform the replacement
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  ${directive} ${current_value} -> ${joined} (dry-run)"
    else
        # Safe: suffix is from a hardcoded set, version is validated as digits-only
        sedi "s|${pattern}|${replacement}|" "$toc_file"
        echo "  ${directive} ${current_value} -> ${joined}"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# update_toc_file - Update all relevant directives in a single TOC file
#
# Args: $1 = toc file path
#        Remaining args = flavor names to process
# Globals: RETAIL_VERSION, CLASSIC_VERSION, VANILLA_VERSION, TBC_VERSION
#          HAS_CLASSIC_FLAVOR, HAS_VANILLA_FLAVOR
# Returns: 0 if any directive was updated, 1 if no changes
# ---------------------------------------------------------------------------
update_toc_file() {
    local toc_file="$1"
    shift
    local flavors=("$@")

    local file_changed=false

    for flavor in "${flavors[@]}"; do
        case "$flavor" in
            retail)
                if update_toc_directive "$toc_file" "" "$RETAIL_VERSION" "retail"; then
                    file_changed=true
                fi
                ;;
            classic)
                if update_toc_directive "$toc_file" "-Mists" "$CLASSIC_VERSION" "classic"; then
                    file_changed=true
                fi
                # classic flavor owns ## Interface-Classic: (MoP takes priority)
                if update_toc_directive "$toc_file" "-Classic" "$CLASSIC_VERSION" "classic"; then
                    file_changed=true
                fi
                ;;
            vanilla)
                # Only update ## Interface-Vanilla: unconditionally
                if update_toc_directive "$toc_file" "-Vanilla" "$VANILLA_VERSION" "vanilla"; then
                    file_changed=true
                fi
                # Only update ## Interface-Classic: if the classic flavor is NOT active
                if [[ "$HAS_CLASSIC_FLAVOR" != "true" ]]; then
                    if update_toc_directive "$toc_file" "-Classic" "$VANILLA_VERSION" "vanilla"; then
                        file_changed=true
                    fi
                fi
                ;;
            tbc)
                if update_toc_directive "$toc_file" "-BCC" "$TBC_VERSION" "tbc"; then
                    file_changed=true
                fi
                if update_toc_directive "$toc_file" "-TBC" "$TBC_VERSION" "tbc"; then
                    file_changed=true
                fi
                ;;
        esac
    done

    [[ "$file_changed" == "true" ]]
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    local flavors=()
    local exclude_dirs=()
    local exclude_dirs_specified=false
    local search_dir="."

    # -- Parse CLI arguments --------------------------------------------------
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                usage
                ;;
            --flavor)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --flavor requires a value" >&2
                    exit 1
                fi
                local valid=false
                for v in "${VALID_FLAVORS[@]}"; do
                    if [[ "$2" == "$v" ]]; then
                        valid=true
                        break
                    fi
                done
                if [[ "$valid" != "true" ]]; then
                    echo "ERROR: Invalid flavor '${2}'. Valid: ${VALID_FLAVORS[*]}" >&2
                    exit 1
                fi
                flavors+=("$2")
                shift 2
                ;;
            --exclude-dir)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --exclude-dir requires a value" >&2
                    exit 1
                fi
                exclude_dirs+=("$2")
                exclude_dirs_specified=true
                shift 2
                ;;
            --path)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --path requires a value" >&2
                    exit 1
                fi
                if [[ ! -d "$2" ]]; then
                    echo "ERROR: '${2}' is not a directory" >&2
                    exit 1
                fi
                search_dir="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                echo "ERROR: Unknown argument '${1}'" >&2
                echo "Run with --help for usage" >&2
                exit 1
                ;;
        esac
    done

    # Default to all flavors if none specified
    if [[ ${#flavors[@]} -eq 0 ]]; then
        flavors=("${VALID_FLAVORS[@]}")
    fi

    # Default to Libs if no exclude dirs specified
    if [[ "$exclude_dirs_specified" != "true" ]]; then
        exclude_dirs=("${DEFAULT_EXCLUDE_DIRS[@]}")
    fi

    # -- Track whether classic/vanilla flavors are active (for priority logic) -
    HAS_CLASSIC_FLAVOR="false"
    HAS_VANILLA_FLAVOR="false"
    for f in "${flavors[@]}"; do
        if [[ "$f" == "classic" ]]; then HAS_CLASSIC_FLAVOR="true"; fi
        if [[ "$f" == "vanilla" ]]; then HAS_VANILLA_FLAVOR="true"; fi
    done

    # -- Fetch versions -------------------------------------------------------
    # Map: flavor -> CDN product
    declare -A FLAVOR_PRODUCT
    FLAVOR_PRODUCT[retail]="wow"
    FLAVOR_PRODUCT[classic]="wow_classic"
    FLAVOR_PRODUCT[vanilla]="wow_classic_era"
    FLAVOR_PRODUCT[tbc]="wow_anniversary"

    declare -A FLAVOR_VERSION

    for flavor in "${flavors[@]}"; do
        local product="${FLAVOR_PRODUCT[$flavor]}"
        echo "Fetching ${flavor} (${product}) version from Blizzard CDN..."
        local version=""
        version=$(fetch_version "$product")
        FLAVOR_VERSION[$flavor]="$version"
        echo "  -> ${version}"
    done

    # Export versions to globals for update_toc_file
    RETAIL_VERSION="${FLAVOR_VERSION[retail]:-}"
    CLASSIC_VERSION="${FLAVOR_VERSION[classic]:-}"
    VANILLA_VERSION="${FLAVOR_VERSION[vanilla]:-}"
    TBC_VERSION="${FLAVOR_VERSION[tbc]:-}"

    # -- Find and update TOC files --------------------------------------------
    local updated_count=0
    local toc_files=()

    while IFS= read -r f; do
        toc_files+=("$f")
    done < <(find_toc_files "$search_dir" "${exclude_dirs[@]}")

    if [[ ${#toc_files[@]} -eq 0 ]]; then
        echo "No .toc files found"
        exit 0
    fi

    for toc_file in "${toc_files[@]}"; do
        # Check if this file has any relevant directives before printing header
        local has_directives=false
        for flavor in "${flavors[@]}"; do
            case "$flavor" in
                retail)
                    grep -q "^## Interface: " "$toc_file" 2>/dev/null && has_directives=true || true ;;
                classic)
                    grep -q "^## Interface-Mists: " "$toc_file" 2>/dev/null && has_directives=true || true
                    grep -q "^## Interface-Classic: " "$toc_file" 2>/dev/null && has_directives=true || true
                    ;;
                vanilla)
                    grep -q "^## Interface-Vanilla: " "$toc_file" 2>/dev/null && has_directives=true || true
                    if [[ "$HAS_CLASSIC_FLAVOR" != "true" ]]; then
                        grep -q "^## Interface-Classic: " "$toc_file" 2>/dev/null && has_directives=true || true
                    fi
                    ;;
                tbc)
                    grep -q "^## Interface-BCC: " "$toc_file" 2>/dev/null && has_directives=true || true
                    grep -q "^## Interface-TBC: " "$toc_file" 2>/dev/null && has_directives=true || true
                    ;;
            esac
        done

        if [[ "$has_directives" != "true" ]]; then
            continue
        fi

        echo "Updating ${toc_file}:"
        if update_toc_file "$toc_file" "${flavors[@]}"; then
            updated_count=$((updated_count + 1))
        fi
    done

    # -- Summary --------------------------------------------------------------
    if (( updated_count > 0 )); then
        echo "Updated ${updated_count} file(s)"
    else
        echo "No changes needed - all versions are current"
    fi

    exit 0
}

main "$@"
