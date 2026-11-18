#!/usr/bin/env bash
###############################################################################
# setup_release_token.sh
# Provisions the RELEASE_PLEASE_TOKEN secret used by release.yml and
# self-release.yml, so release PRs trigger pull_request workflows.
#
# GitHub has no API for creating personal access tokens, so the token itself is
# created in the browser. This script opens the creation page with the name,
# description, expiry and permissions pre-filled, reads the token you paste
# (hidden, never in argv or shell history), validates it against every target
# repo, and stores it as a repository secret with `gh secret set`.
#
# Usage:  bash scripts/setup_release_token.sh [OPTIONS] [REPO...]
#
# Options:
#   --owner OWNER       Repository owner for bare REPO names (default: Xerrion)
#   --expires DAYS      Token lifetime to pre-fill, 1-366 (default: 90)
#   --no-open           Print the creation URL instead of opening a browser
#   --check             Only report which repos have the secret; change nothing
#   --dry-run           Validate the token but do not store the secret
#   -h, --help          Show this help
#
# REPO is "name" or "owner/name". Defaults to every repo in DEFAULT_REPOS.
#
# Required token permissions (set on the creation page):
#   Contents: write, Pull requests: write, Issues: write (labels), Metadata: read
# Repository access must include every target repo; that cannot be pre-filled.
#
# Env:    None. Requires `gh` signed in with permission to manage repo secrets.
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SECRET_NAME="RELEASE_PLEASE_TOKEN"
readonly TOKEN_NAME="release-please"
readonly TOKEN_URL_BASE="https://github.com/settings/personal-access-tokens/new"
readonly DEFAULT_REPOS=(
    DragonLoot DragonToast DragonWidgets LibAnimate PhDamage RaidLogAuto wow-workflows
)
OWNER="Xerrion"
EXPIRES_DAYS=90
OPEN_BROWSER=true
CHECK_ONLY=false
DRY_RUN=false
REPOS=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
    awk 'NR <= 2 { next } /^####/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

die() {
    echo "error: $*" >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --owner)   [[ $# -ge 2 ]] || die "--owner needs a value"; OWNER="$2"; shift 2 ;;
            --expires) [[ $# -ge 2 ]] || die "--expires needs a value"; EXPIRES_DAYS="$2"; shift 2 ;;
            --no-open) OPEN_BROWSER=false; shift ;;
            --check)   CHECK_ONLY=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            -h|--help) usage; exit 0 ;;
            -*)        die "unknown option: $1" ;;
            *)         REPOS+=("$1"); shift ;;
        esac
    done
    if ! [[ "$EXPIRES_DAYS" =~ ^[0-9]+$ ]] || ((EXPIRES_DAYS < 1 || EXPIRES_DAYS > 366)); then
        die "--expires must be an integer from 1 to 366"
    fi
    if [[ ${#REPOS[@]} -eq 0 ]]; then
        REPOS=("${DEFAULT_REPOS[@]}")
    fi
    local i
    for i in "${!REPOS[@]}"; do
        [[ "${REPOS[$i]}" == */* ]] || REPOS[i]="$OWNER/${REPOS[$i]}"
    done
}

token_url() {
    printf '%s?name=%s&description=%s&expires_in=%s&contents=write&pull_requests=write&issues=write' \
        "$TOKEN_URL_BASE" "$TOKEN_NAME" \
        "Release%20Please%20PRs%20that%20trigger%20workflows" "$EXPIRES_DAYS"
}

open_url() {
    local url="$1"
    if [[ "$OPEN_BROWSER" == true ]]; then
        if command -v open >/dev/null 2>&1; then
            open "$url" && return 0
        elif command -v xdg-open >/dev/null 2>&1; then
            xdg-open "$url" >/dev/null 2>&1 && return 0
        fi
    fi
    echo "Open this URL:"
    echo "  $url"
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
check_secrets() {
    local repo missing=0
    for repo in "${REPOS[@]}"; do
        if gh secret list -R "$repo" --json name --jq '.[].name' | grep -qx "$SECRET_NAME"; then
            printf '  set      %s\n' "$repo"
        else
            printf '  MISSING  %s\n' "$repo"
            missing=1
        fi
    done
    return "$missing"
}

# Confirms the token authenticates and can push to every target repo. It cannot
# prove Pull requests/Issues write; the first release-please run does that.
validate_token() {
    local token="$1" login repo push
    login=$(GH_TOKEN="$token" gh api user --jq .login 2>/dev/null) \
        || die "token was rejected by GitHub (expired, mistyped, or revoked)"
    echo "Token belongs to: $login"
    for repo in "${REPOS[@]}"; do
        push=$(GH_TOKEN="$token" gh api "repos/$repo" --jq .permissions.push 2>/dev/null) \
            || die "token cannot see $repo; add it under Repository access"
        [[ "$push" == "true" ]] || die "token has no write access to $repo; set Contents to Read and write"
        printf '  ok       %s\n' "$repo"
    done
}

store_secret() {
    local token="$1" repo
    for repo in "${REPOS[@]}"; do
        printf '%s' "$token" | gh secret set "$SECRET_NAME" -R "$repo" >/dev/null \
            || die "could not set the secret on $repo"
        printf '  stored   %s\n' "$repo"
    done
}

main() {
    parse_args "$@"
    command -v gh >/dev/null 2>&1 || die "gh is required"
    gh auth status >/dev/null 2>&1 || die "gh is not signed in; run: gh auth login"

    if [[ "$CHECK_ONLY" == true ]]; then
        check_secrets
        return
    fi

    echo "Targets:"
    printf '  %s\n' "${REPOS[@]}"
    echo
    echo "On the page: set Repository access to 'Only select repositories' and choose"
    echo "every target above. Permissions and expiry (${EXPIRES_DAYS} days) are pre-filled."
    open_url "$(token_url)"
    echo

    local token=""
    read -rsp "Paste the generated token (hidden): " token
    echo
    [[ -n "$token" ]] || die "no token entered"

    echo "Validating:"
    validate_token "$token"

    if [[ "$DRY_RUN" == true ]]; then
        echo "Dry run: secret not stored."
        return
    fi

    echo "Storing ${SECRET_NAME}:"
    store_secret "$token"
    echo
    echo "Done. The token expires in ${EXPIRES_DAYS} days; release PRs stop updating then."
    echo "Re-run this script to rotate it."
}

main "$@"
