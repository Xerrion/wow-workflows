#!/usr/bin/env bash
###############################################################################
# setup_release_token.sh
# Provisions the RELEASE_PLEASE_TOKEN secret used by release.yml and
# self-release.yml, so release PRs trigger pull_request workflows.
#
# GitHub has no API for creating personal access tokens, so the token itself is
# created in the browser. This script opens the creation page with the name,
# description, expiry and permissions pre-filled, reads the token you paste
# (hidden, never in argv or shell history), proves it works on every target
# repo by using it (creates, then removes, a branch, draft PR and label), and
# stores it as a repository secret with `gh secret set`.
#
# Usage:  bash scripts/setup_release_token.sh [OPTIONS] [REPO...]
#
# Options:
#   --owner OWNER       Repository owner for bare REPO names (default: Xerrion)
#   --expires DAYS      Token lifetime to pre-fill, 1-366 (default: 90)
#   --no-open           Print the creation URL instead of opening a browser
#   --check             Only report which repos have the secret; change nothing
#   --dry-run           Run the probes but do not store the secret
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
    DragonLoot DragonShout DragonToast DragonWidgets LibAnimate PhDamage RaidLogAuto wow-workflows
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

# Exercises the token itself, because repo metadata (e.g. .permissions.push)
# reflects the user's role and public repos are readable without any grant.
# Per repo, in a subshell so GH_TOKEN and the cleanup trap stay local, it:
#   - creates a commit and branch ref        -> Contents: write, repo selected
#   - opens a draft PR from that branch      -> Pull requests: write
#   - creates a label                        -> Issues: write
# then closes the PR and deletes the branch and label, even on failure.
probe_repo() {
    local repo="$1" token="$2"
    (
        export GH_TOKEN="$token"
        local ref="release-token-probe-$$" label_name="release-token-probe"
        local branch base tree commit pr="" label=false
        cleanup() {
            if [[ -n "$pr" ]]; then
                gh api -X PATCH "repos/$repo/pulls/$pr" -f state=closed >/dev/null 2>&1 || true
            fi
            gh api -X DELETE "repos/$repo/git/refs/heads/$ref" >/dev/null 2>&1 || true
            if [[ "$label" == true ]]; then
                gh api -X DELETE "repos/$repo/labels/$label_name" >/dev/null 2>&1 || true
            fi
        }
        fail() {
            printf '  FAILED   %s: %s\n' "$repo" "$1" >&2
            exit 1
        }
        trap cleanup EXIT

        branch=$(gh api "repos/$repo" --jq .default_branch 2>/dev/null) \
            || fail "repository not visible to the token"
        base=$(gh api "repos/$repo/git/ref/heads/$branch" --jq .object.sha 2>/dev/null) \
            || fail "cannot read branch $branch"
        tree=$(gh api "repos/$repo/git/commits/$base" --jq .tree.sha 2>/dev/null) \
            || fail "cannot read commit $base"
        commit=$(gh api -X POST "repos/$repo/git/commits" -f message="release-token probe" \
            -f tree="$tree" -f "parents[]=$base" --jq .sha 2>/dev/null) \
            || fail "cannot create a commit: add the repo under Repository access and set Contents to Read and write"
        gh api -X POST "repos/$repo/git/refs" -f ref="refs/heads/$ref" -f sha="$commit" >/dev/null 2>&1 \
            || fail "cannot create a branch: set Contents to Read and write"
        pr=$(gh api -X POST "repos/$repo/pulls" -f title="release-token probe (auto-closed)" \
            -f head="$ref" -f base="$branch" -F draft=true --jq .number 2>/dev/null) \
            || fail "cannot open a pull request: set Pull requests to Read and write"
        gh api -X POST "repos/$repo/labels" -f name="$label_name" -f color=ededed >/dev/null 2>&1 \
            || fail "cannot create a label: set Issues to Read and write"
        label=true
        printf '  ok       %s\n' "$repo"
    )
}

validate_token() {
    local token="$1" login repo
    login=$(GH_TOKEN="$token" gh api user --jq .login 2>/dev/null) \
        || die "token was rejected by GitHub (expired, mistyped, or revoked)"
    echo "Token belongs to: $login"
    for repo in "${REPOS[@]}"; do
        probe_repo "$repo" "$token" || die "token failed validation on $repo"
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
