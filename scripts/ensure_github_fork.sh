#!/usr/bin/env bash
# ensure_github_fork.sh — Ensure a fork of an upstream GitHub repo exists under
# $GITHUB_USER, creating it if needed, and print the fork's clone URL.
#
# Offboarding GitHub steps always contribute via a fork: changes are pushed to a
# fork owned by $GITHUB_USER and a cross-repo PR is opened against the upstream.
# This helper guarantees the fork exists (and is a real fork of the upstream)
# before the playpen tries to push to it, and best-effort syncs the fork's
# default branch with upstream so the pushed branch fast-forwards cleanly.
#
# Usage:
#   ensure_github_fork.sh --upstream-url <https url>
#
# Environment:
#   GITHUB_TOKEN  — required; classic PAT with 'repo' scope (fine-grained tokens
#                   cannot create forks in this account — see docs/token notes).
#   GITHUB_USER   — required; the account that will own the fork.
#
# Output (stdout):
#   Line 1: fork clone URL (https://github.com/<GITHUB_USER>/<repo>.git)
#
# Exit codes:
#   0  Success (fork exists or was created)
#   1  Error
set -euo pipefail

info()  { echo "[INFO]  $*" >&2; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; }
die()   { error "$*"; exit 1; }

UPSTREAM_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream-url) UPSTREAM_URL="${2:?--upstream-url requires a value}"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $1. Run '$0 --help' for usage." ;;
  esac
done

[[ -z "$UPSTREAM_URL" ]] && die "--upstream-url is required."

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_USER="${GITHUB_USER:-}"
[[ -z "$GITHUB_TOKEN" ]] && die "GITHUB_TOKEN is not set. Export it before running this script."
[[ -z "$GITHUB_USER" ]]  && die "GITHUB_USER is not set. Export it before running this script."

# ── Derive upstream owner/repo ─────────────────────────────────────────────────
UP_PATH="${UPSTREAM_URL#*://}"            # strip scheme
UP_PATH="${UP_PATH#github.com/}"          # strip host
UP_PATH="${UP_PATH%.git}"                 # strip .git
UP_OWNER="${UP_PATH%%/*}"
REPO_NAME="${UP_PATH##*/}"

[[ -z "$UP_OWNER" || -z "$REPO_NAME" || "$UP_OWNER" == "$UP_PATH" ]] && \
  die "Could not parse owner/repo from upstream URL: $UPSTREAM_URL"

FORK_URL="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"

api() {
  # api <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  local args=(-s -w $'\n%{http_code}' -X "$method"
    -H "Authorization: token $GITHUB_TOKEN"
    -H "Accept: application/vnd.github.v3+json")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}" "https://api.github.com${path}" 2>/dev/null || echo $'\n000'
}

info "Ensuring fork of ${UP_OWNER}/${REPO_NAME} under ${GITHUB_USER}..."

# ── Check whether the fork already exists ──────────────────────────────────────
RESP=$(api GET "/repos/${GITHUB_USER}/${REPO_NAME}")
STATUS=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

fork_is_valid() {
  # Confirms the existing repo is a fork whose parent/source is the upstream.
  local is_fork parent source
  is_fork=$(echo "$BODY" | jq -r '.fork // false')
  parent=$(echo "$BODY"  | jq -r '.parent.full_name // ""' | tr '[:upper:]' '[:lower:]')
  source=$(echo "$BODY"  | jq -r '.source.full_name // ""' | tr '[:upper:]' '[:lower:]')
  local want
  want="$(echo "${UP_OWNER}/${REPO_NAME}" | tr '[:upper:]' '[:lower:]')"
  [[ "$is_fork" == "true" && ( "$parent" == "$want" || "$source" == "$want" ) ]]
}

if [[ "$STATUS" == "200" ]]; then
  if fork_is_valid; then
    info "Fork already exists: ${GITHUB_USER}/${REPO_NAME}"
  else
    die "A repo named ${GITHUB_USER}/${REPO_NAME} exists but is NOT a fork of ${UP_OWNER}/${REPO_NAME}. Refusing to use it."
  fi
else
  # ── Create the fork ──────────────────────────────────────────────────────────
  info "Fork not found — creating fork of ${UP_OWNER}/${REPO_NAME}..."
  CREATE=$(api POST "/repos/${UP_OWNER}/${REPO_NAME}/forks")
  CREATE_STATUS=$(echo "$CREATE" | tail -1)
  if [[ "$CREATE_STATUS" != "202" && "$CREATE_STATUS" != "200" ]]; then
    error "Fork creation failed (HTTP $CREATE_STATUS):"
    echo "$CREATE" | sed '$d' | jq -r '.message // .' >&2 2>/dev/null || true
    die "Could not create fork. Ensure GITHUB_TOKEN is a classic PAT with 'repo' scope."
  fi

  # Fork creation is asynchronous — poll until the repo is queryable.
  info "Waiting for fork to become available..."
  for attempt in $(seq 1 30); do
    sleep 2
    POLL=$(api GET "/repos/${GITHUB_USER}/${REPO_NAME}")
    if [[ "$(echo "$POLL" | tail -1)" == "200" ]]; then
      info "Fork is ready: ${GITHUB_USER}/${REPO_NAME}"
      break
    fi
    [[ "$attempt" -eq 30 ]] && die "Timed out waiting for fork ${GITHUB_USER}/${REPO_NAME} to become available."
  done
fi

# ── Best-effort: sync fork's default branch with upstream ──────────────────────
DEFAULT_BRANCH=$(api GET "/repos/${GITHUB_USER}/${REPO_NAME}" | sed '$d' | jq -r '.default_branch // "main"')
SYNC=$(api POST "/repos/${GITHUB_USER}/${REPO_NAME}/merge-upstream" "{\"branch\":\"${DEFAULT_BRANCH}\"}")
SYNC_STATUS=$(echo "$SYNC" | tail -1)
if [[ "$SYNC_STATUS" == "200" ]]; then
  info "Fork default branch '${DEFAULT_BRANCH}' synced with upstream."
else
  warn "Could not sync fork with upstream (HTTP $SYNC_STATUS) — continuing; the pushed branch carries upstream commits."
fi

# ── Output ─────────────────────────────────────────────────────────────────────
echo "$FORK_URL"
