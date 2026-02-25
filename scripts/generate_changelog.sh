#!/usr/bin/env bash
###############################################################################
# generate_changelog.sh
# Generates a clean changelog for the BigWigsMods packager release pipeline.
# Strips release commits and Co-authored-by lines from the git log.
#
# Usage:  bash scripts/generate_changelog.sh [output_file]
# Env:    TAG_NAME           - tag to generate changelog for (optional)
#         GITHUB_REPOSITORY  - owner/repo for links (auto-set in GitHub Actions)
###############################################################################
set -euo pipefail

OUTPUT_FILE="${1:-.release/CHANGELOG.md}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

# Derive project name from repo (e.g., "Xerrion/PhDamage" -> "PhDamage")
PROJECT_NAME="${REPO##*/}"

# ---------------------------------------------------------------------------
# Resolve current tag
# ---------------------------------------------------------------------------
if [[ -n "${TAG_NAME:-}" ]]; then
    current_tag="$TAG_NAME"
else
    current_tag="$(git describe --tags --abbrev=0)"
fi

# ---------------------------------------------------------------------------
# Resolve previous tag (may not exist for the first release)
# ---------------------------------------------------------------------------
previous_tag=""
if git describe --tags --abbrev=0 "${current_tag}^" >/dev/null 2>&1; then
    previous_tag="$(git describe --tags --abbrev=0 "${current_tag}^")"
fi

# ---------------------------------------------------------------------------
# Tag date
# ---------------------------------------------------------------------------
tag_date="$(git log -1 --format=%as "${current_tag}")"

# ---------------------------------------------------------------------------
# Prepare output directory
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$OUTPUT_FILE")"

# ---------------------------------------------------------------------------
# Write header
# ---------------------------------------------------------------------------
{
    echo "# ${PROJECT_NAME}"
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
} > "$OUTPUT_FILE"

# ---------------------------------------------------------------------------
# Determine log range
# ---------------------------------------------------------------------------
if [[ -n "$previous_tag" ]]; then
    range="${previous_tag}..${current_tag}"
else
    range="$current_tag"
fi

# ---------------------------------------------------------------------------
# Write commit list - one commit per NUL-delimited record
# ---------------------------------------------------------------------------
while IFS= read -r -d $'\0' record; do
    # Pick the first non-empty line as the subject; remaining lines are body
    subject=""
    body=""
    while IFS= read -r line; do
        if [[ -z "$subject" ]]; then
            if [[ -n "$line" ]]; then
                subject="$line"
            fi
        else
            body+="$line"$'\n'
        fi
    done <<< "$record"

    # Skip records with no usable subject
    [[ -z "$subject" ]] && continue

    # Skip release commits (e.g. "chore: release 1.2.3" or "chore(master): release 1.2.3")
    if [[ "$subject" == chore:\ release\ * || "$subject" == chore\(*\):\ release\ * ]]; then
        continue
    fi

    # Print subject as a list item
    echo "- ${subject}" >> "$OUTPUT_FILE"

    # Process body lines
    while IFS= read -r line; do
        # Skip Co-authored-by lines (case insensitive)
        if [[ "$line" =~ ^[[:space:]]*[Cc][Oo]-[Aa][Uu][Tt][Hh][Oo][Rr][Ee][Dd]-[Bb][Yy]: ]]; then
            continue
        fi

        # Skip lines that are only dashes (like "-----")
        if [[ "$line" =~ ^-+$ ]]; then
            continue
        fi

        # Skip empty lines
        if [[ -z "$line" ]]; then
            continue
        fi

        # Indent body lines by 4 spaces
        echo "    ${line}" >> "$OUTPUT_FILE"
    done <<< "$body"
done < <(git log --format='%s%n%b%x00' "$range")

echo "Changelog written to ${OUTPUT_FILE}"
