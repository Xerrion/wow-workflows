#!/usr/bin/env bash
###############################################################################
# generate_changelog.sh
# Generates a clean changelog for the BigWigsMods packager release pipeline.
# Strips release commits, attribution lines (Co-authored-by, Ultraworked with),
# and dash-only lines from the git log. Optionally strips squash-merge
# sub-commits and linkifies PR refs.
#
# Usage:  bash scripts/generate_changelog.sh [OPTIONS]
# Env:    TAG_NAME           - tag to generate changelog for (optional)
#         GITHUB_REPOSITORY  - owner/repo for links (auto-set in GitHub Actions)
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OUTPUT_FILE=".release/CHANGELOG.md"
REPO="${GITHUB_REPOSITORY:-}"
TAG=""
NO_SUB_COMMITS=false
LINKIFY_PRS=false
DRY_RUN=false

# ---------------------------------------------------------------------------
# usage - Print help text and exit
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: bash scripts/generate_changelog.sh [OPTIONS]

Generates a clean changelog from git log between two tags.

Options:
  --output FILE         Output file path (default: .release/CHANGELOG.md)
  --repo OWNER/REPO     GitHub repository (default: \$GITHUB_REPOSITORY)
  --tag TAG             Tag to generate changelog for (default: latest)
  --no-sub-commits      Strip squash-merge sub-commit lines from body
  --linkify-prs         Convert (#123) references to GitHub PR links
  --dry-run             Print to stdout instead of writing file
  --help                Show this help
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# die - Print error and exit
# ---------------------------------------------------------------------------
die() {
    echo "ERROR: $1" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# require_value - Guard: ensure a CLI flag has a non-empty argument
#
# Args: $1 = flag name (for error messages)
#       $2 = value to validate (empty string if not provided)
# Returns: validated value via stdout
# Throws: exits with error if value is empty or missing
# ---------------------------------------------------------------------------
require_value() {
    local flag="$1"
    local value="${2:-}"
    
    # Input validation: reject empty values
    [[ -n "$value" ]] || die "${flag} requires a non-empty value"
    
    # Trim whitespace and return validated value
    echo "$value" | xargs
}

# ---------------------------------------------------------------------------
# linkify_pr_refs - Convert (#123) patterns into markdown PR links
#
# Args: $1 = line of text
# Globals: REPO (must be validated before calling this function)
# Returns: transformed line via stdout
# Throws: N/A - expects valid inputs at boundary
# ---------------------------------------------------------------------------
linkify_pr_refs() {
    local line="$1"
    
    # Safety: REPO is validated against ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ in main()
    echo "$line" | sed -E "s|\(#([0-9]+)\)|[#\1](https://github.com/${REPO}/pull/\1)|g"
}

# ---------------------------------------------------------------------------
# PATTERNS - Regex patterns for validation (constants)
# ---------------------------------------------------------------------------
REPO_PATTERN='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
RELEASE_COMMIT_PATTERN='^chore(?:\(.*\))?: release '
ATTRIBUTION_PATTERN='^[[:space:]]*(co-authored-by:|ultraworked[[:space:]]+with)'
DASH_ONLY_PATTERN='^-+$'

# ---------------------------------------------------------------------------
# is_release_commit - Check if a subject line is a release commit
#
# Matches: "chore: release ..." and "chore(*): release ..."
# Args: $1 = subject line to check
# Returns: 0 (true) if release commit, 1 (false) otherwise
# ---------------------------------------------------------------------------
is_release_commit() {
    local subject="$1"
    
    # Early exit: reject empty subject
    [[ -z "$subject" ]] && return 1
    
    [[ "$subject" =~ $RELEASE_COMMIT_PATTERN ]]
}

# ---------------------------------------------------------------------------
# build_changelog - Generate full changelog content to stdout
#
# Reads git log between two tags and formats it as markdown.
# Globals: REPO, current_tag, previous_tag, project_name,
#          NO_SUB_COMMITS, LINKIFY_PRS
# Throws: on git command failures or invalid inputs
# ---------------------------------------------------------------------------
build_changelog() {
    # Early exit: validate required globals at boundary
    [[ -z "$REPO" ]] && die "build_changelog: REPO must be set"
    [[ -z "$current_tag" ]] && die "build_changelog: current_tag must be set"
    
    local tag_date
    tag_date="$(git log -1 --format=%as -- "$current_tag")" || \
        die "Failed to get date for tag '$current_tag'"

    # -- Header ---------------------------------------------------------------
    echo "# ${project_name}"
    echo ""
    echo "## [${current_tag}](https://github.com/${REPO}/tree/${current_tag}) (${tag_date})"

    if [[ -n "$previous_tag" ]]; then
        printf "[Full Changelog](https://github.com/%s/compare/%s...%s)" \
            "$REPO" "$previous_tag" "$current_tag"
    else
        printf "[Full Changelog](https://github.com/%s/commits/%s)" \
            "$REPO" "$current_tag"
    fi

    printf " [Previous Releases](https://github.com/%s/releases)\n" "$REPO"
    echo ""

    # -- Determine log range --------------------------------------------------
    local range
    if [[ -n "$previous_tag" ]]; then
        range="${previous_tag}..${current_tag}"
    else
        range="$current_tag"
    fi

    # -- Commit list (NUL-delimited records) ----------------------------------
    local subject body
    while IFS= read -r -d $'\0' record; do
        # Extract subject (first non-empty line) and body (remainder)
        subject=""
        body=""

        while IFS= read -r line; do
            if [[ -z "$subject" ]]; then
                [[ -n "$line" ]] && subject="$line"
            else
                body+="$line"$'\n'
            fi
        done <<< "$record"

        # Early exit: skip records with no usable subject
        [[ -z "$subject" ]] && continue

        # Skip release commits
        is_release_commit "$subject" && continue

        # Optionally linkify PR references in subject
        if [[ "$LINKIFY_PRS" == true ]]; then
            subject="$(linkify_pr_refs "$subject")" || true
        fi

        # Print subject as list item
        echo "- ${subject}"

        # Skip body entirely when --no-sub-commits is active
        if [[ "$NO_SUB_COMMITS" != true ]]; then
            # Process body lines (filter and indent)
            while IFS= read -r line; do
                # Early exit: skip empty lines
                [[ -z "$line" ]] && continue
                
                # Skip attribution lines
                [[ "$line" =~ $ATTRIBUTION_PATTERN ]] && continue
                
                # Skip dash-only lines
                [[ "$line" =~ $DASH_ONLY_PATTERN ]] && continue
                
                # Optionally linkify PR references in body
                if [[ "$LINKIFY_PRS" == true ]]; then
                    line="$(linkify_pr_refs "$line")" || true
                fi

                # Indent body lines by 4 spaces
                echo "    ${line}"
            done <<< "$body"
        fi
    done < <(git log --format='%s%n%b%x00' "$range") || \
        die "git log failed for range '$range'"

    # Trailing newline
    echo ""
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    # -- Parse CLI arguments --------------------------------------------------
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                usage
                ;;
            --output)
                OUTPUT_FILE="$(require_value --output "${2:-}")"
                shift 2
                ;;
            --repo)
                REPO="$(require_value --repo "${2:-}")"
                shift 2
                ;;
            --tag)
                TAG="$(require_value --tag "${2:-}")"
                shift 2
                ;;
            --no-sub-commits)
                NO_SUB_COMMITS=true
                shift
                ;;
            --linkify-prs)
                LINKIFY_PRS=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                die "Unknown argument '${1}'. Run with --help for usage"
                ;;
        esac
    done

    # -- Resolve repo (CLI > env > fail) --------------------------------------
    [[ -n "$REPO" ]] || die "GITHUB_REPOSITORY must be set or --repo provided"

    # Validate owner/repo format using constant pattern
    if [[ ! "$REPO" =~ $REPO_PATTERN ]]; then
        die "Invalid repo format '${REPO}'. Expected OWNER/REPO"
    fi

    # Derive project name (e.g. "Xerrion/PhDamage" -> "PhDamage")
    local project_name="${REPO#*/}"

    # -- Resolve current tag (CLI > env > git describe) -----------------------
    local current_tag
    if [[ -n "$TAG" ]]; then
        current_tag="$TAG"
    elif [[ -n "${TAG_NAME:-}" ]]; then
        current_tag="$TAG_NAME"
    else
        current_tag="$(git describe --tags --abbrev=0)"
    fi

    # -- Resolve previous tag (may not exist for first release) ---------------
    local previous_tag=""
    if git describe --tags --abbrev=0 "${current_tag}^" >/dev/null 2>&1; then
        previous_tag="$(git describe --tags --abbrev=0 "${current_tag}^")"
    fi

    # -- Route output ---------------------------------------------------------
    if [[ "$DRY_RUN" == true ]]; then
        build_changelog
    else
        mkdir -p "$(dirname "$OUTPUT_FILE")"
        build_changelog > "$OUTPUT_FILE"
        echo "Changelog written to ${OUTPUT_FILE}"
    fi
}

main "$@"
