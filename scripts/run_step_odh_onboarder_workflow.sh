#!/usr/bin/env bash
# Wrapper for the ODH odh-konflux-onboarder step (single pipeline step).
#
# Always runs CI (build_type=CI, repo_branch). When odh_release_tag is set, also runs
# Release (build_type=Release, odh_release_branch + version) in the same invocation —
# two workflow dispatches, one orchestrator step (see RHOAIENG-85723 / PR review).
#
# Exit codes:
#   0  Workflow(s) triggered; Tekton PR URL(s) recorded — prints PR_URL=<ci url>
#   1  Failure — pipeline_state.json NOT updated
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

JIRA_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jira-url) JIRA_URL="$2"; shift 2 ;;
    --pipeline-step)
      # Ignored — kept for backward compatibility with older skill text
      shift 2
      ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$JIRA_URL" ]] && { echo "ERROR: --jira-url is required" >&2; exit 1; }

STEP="onboarder_workflow"
JIRA_ID="${JIRA_URL%/}"; JIRA_ID="${JIRA_ID##*/}"
WORKDIR="${WORKDIR:-$(pwd)/${JIRA_ID}}"
PIPELINE_STATE="${PIPELINE_STATE:-${WORKDIR}/pipeline_state.json}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ ! -f "$PIPELINE_STATE" ]] && {
  echo "ERROR: pipeline_state.json not found at $PIPELINE_STATE" >&2; exit 1
}

STEP_STATUS=$(jq -r --arg s "$STEP" '.steps[$s].status // "pending"' "$PIPELINE_STATE")
if [[ "$STEP_STATUS" == "skipped" ]]; then
  echo "Step ${STEP} is skipped — nothing to do."
  exit 0
fi

YAML_FILE="$WORKDIR/component_onboarding_details.yaml"
[[ ! -f "$YAML_FILE" ]] && { echo "ERROR: $YAML_FILE not found" >&2; exit 1; }

REPO_URL=$(grep -m1       'repo_url:'            "$YAML_FILE" | awk '{print $2}')
REPO_BRANCH=$(grep -m1    'repo_branch:'         "$YAML_FILE" | awk '{print $2}')
YAML_BUILD_TYPE=$(grep -m1 'build_type:'         "$YAML_FILE" | awk '{print $2}' 2>/dev/null || echo "CI")
ODH_RELEASE_TAG=$(grep -m1 'odh_release_tag:'    "$YAML_FILE" | awk '{print $2}' 2>/dev/null || echo "")
ODH_RELEASE_BRANCH=$(grep -m1 'odh_release_branch:' "$YAML_FILE" | awk '{print $2}' 2>/dev/null || echo "")
[[ -z "$ODH_RELEASE_BRANCH" ]] && ODH_RELEASE_BRANCH="stable"

NEEDS_RELEASE=false
[[ -n "$ODH_RELEASE_TAG" ]] && NEEDS_RELEASE=true
if [[ "$YAML_BUILD_TYPE" == "Release" && -z "$ODH_RELEASE_TAG" ]]; then
  echo "ERROR: legacy build_type=Release requires odh_release_tag in YAML." >&2
  exit 1
fi

CI_PR_URL=$(jq -r '.steps.onboarder_workflow.pr_url // ""' "$PIPELINE_STATE")
RELEASE_PR_URL=$(jq -r '.steps.onboarder_workflow.release_pr_url // ""' "$PIPELINE_STATE")

if [[ -n "$CI_PR_URL" ]] && { [[ "$NEEDS_RELEASE" == "false" ]] || [[ -n "$RELEASE_PR_URL" ]]; }; then
  echo "Onboarder step already recorded in state (CI: $CI_PR_URL${RELEASE_PR_URL:+, Release: $RELEASE_PR_URL})"
  echo "PR_URL=$CI_PR_URL"
  exit 0
fi

if [[ "${ONBOARD_DRY_RUN:-false}" == "true" ]]; then
  echo "ONBOARD_DRY_RUN=true — skipping onboarder workflow trigger, marking ${STEP} as done."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "tekton-pr-raised" \
    --comment "[step:onboarder_workflow] Skipped (ONBOARD_DRY_RUN=true). ODH onboarder workflow not triggered." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step "$STEP" --status done
  exit 0
fi

REPO_NAME="${REPO_URL##*/}"; REPO_NAME="${REPO_NAME%.git}"
COMPONENT="$REPO_NAME"
OKC_URL="${ODH_KONFLUX_CENTRAL_REPO_URL:-https://github.com/opendatahub-io/odh-konflux-central.git}"
OKC_PATH=$(echo "$OKC_URL" | sed 's|https://github.com/||;s|\.git$||')
WORKFLOW_FILE=".github/workflows/odh-konflux-onboarder.yml"
OKC_REF="main"

run_onboarder_dispatch() {
  local build_type="$1"
  local target_branch="$2"
  local version="${3:-}"
  local phase_label="$4"
  local add_raised_label="${5:-false}"

  echo "Triggering odh-konflux-onboarder (${phase_label}) for component: $COMPONENT"
  echo "Build type  : $build_type"
  echo "Branch      : $target_branch"
  [[ -n "$version" ]] && echo "Release tag : $version"

  local -a inputs=(
    "--input" "component=$COMPONENT"
    "--input" "pr_target_branch=$target_branch"
    "--input" "build_type=$build_type"
  )
  [[ -n "$version" ]] && inputs+=("--input" "version=$version")

  local run_id=""
  local attempt
  for attempt in 1 2 3; do
    local trigger_err
    trigger_err=$(uv run --script "$SCRIPTS_DIR/run_github_workflow.py" trigger \
      --repo-url  "$OKC_URL" \
      --workflow  "$WORKFLOW_FILE" \
      --ref       "$OKC_REF" \
      "${inputs[@]}" 2>/tmp/onboarder_trigger_err.txt) && {
      run_id="$trigger_err"
      break
    }
    local err_content
    err_content=$(cat /tmp/onboarder_trigger_err.txt 2>/dev/null || echo "")
    if echo "$err_content" | grep -q "403"; then
      echo "ERROR: HTTP 403 — GITHUB_TOKEN needs 'actions:write' scope." >&2; exit 1
    fi
    if echo "$err_content" | grep -q "404"; then
      echo "ERROR: HTTP 404 — workflow or repo not found." >&2; exit 1
    fi
    if echo "$err_content" | grep -q "422"; then
      echo "ERROR: HTTP 422 — component may not be registered in the workflow yet." >&2
      echo "  Ensure the okc PR is merged and the component appears in the workflow's component list." >&2
      exit 1
    fi
    [[ "$attempt" -eq 3 ]] && {
      echo "ERROR: Could not trigger odh-konflux-onboarder (${phase_label}) after 3 attempts." >&2
      cat /tmp/onboarder_trigger_err.txt >&2
      exit 1
    }
    sleep 10
  done

  local run_url="https://github.com/${OKC_PATH}/actions/runs/${run_id}"
  echo "Workflow triggered. Run ID: $run_id"
  echo "Run URL: $run_url"

  local jira_args=(--comment "[step:onboarder_workflow] ${phase_label} odh-konflux-onboarder triggered (Run #${run_id}).

Component: ${COMPONENT}
Build type: ${build_type}
Target branch: ${target_branch}
Workflow run: ${run_url}

Monitoring for Tekton PR URL...")
  if [[ "$add_raised_label" == "true" ]]; then
    jira_args=(--add-label "tekton-pr-raised" "${jira_args[@]}")
  fi
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" "${jira_args[@]}" || true

  local monitor_output
  monitor_output=$(uv run --script "$SCRIPTS_DIR/run_github_workflow.py" monitor \
    --repo-url      "$OKC_URL" \
    --run-id        "$run_id" \
    --timeout       30 \
    --poll-interval 60 2>/dev/null || echo "status=failure")
  local workflow_status="${monitor_output#status=}"

  if [[ "$workflow_status" != "success" ]]; then
    echo "ERROR: Onboarder workflow run ${run_id} (${phase_label}) ended with status '${workflow_status}'." >&2
    echo "Run URL: $run_url" >&2
    exit 1
  fi

  local tekton_pr_url
  tekton_pr_url=$(uv run --script "$SCRIPTS_DIR/monitor_github_pr.py" \
    --repo-url  "$OKC_URL" \
    --run-id    "$run_id" 2>/dev/null || echo "")

  if [[ -z "$tekton_pr_url" ]]; then
    tekton_pr_url=$(uv run --script "$SCRIPTS_DIR/run_github_workflow.py" get-step-logs \
      --repo-url "$OKC_URL" \
      --run-id   "$run_id" \
      --step     "Create PR" 2>/dev/null \
      | grep -oE 'https://github.com/[^/]+/[^/]+/pull/[0-9]+' | head -1 || echo "")
  fi

  if [[ -z "$tekton_pr_url" ]]; then
    echo "WARN: Could not extract Tekton PR URL from workflow logs (${phase_label})."
    echo "  Check run manually: $run_url"
    tekton_pr_url="$run_url"
  fi

  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --comment "[step:onboarder_workflow] ${phase_label} odh-konflux-onboarder completed.

Tekton PR: ${tekton_pr_url}
Workflow run: ${run_url}" || true

  echo "$tekton_pr_url"
}

if [[ -z "$CI_PR_URL" ]]; then
  CI_PR_URL=$(run_onboarder_dispatch "CI" "$REPO_BRANCH" "" "CI" "true")
fi

if [[ "$NEEDS_RELEASE" == "true" && -z "$RELEASE_PR_URL" ]]; then
  RELEASE_PR_URL=$(run_onboarder_dispatch "Release" "$ODH_RELEASE_BRANCH" "$ODH_RELEASE_TAG" "Release" "false")
fi

TMP=$(mktemp)
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq \
  --arg ci "$CI_PR_URL" \
  --arg rel "$RELEASE_PR_URL" \
  --arg ts "$NOW" \
  '.steps.onboarder_workflow.pr_url = $ci
   | .steps.onboarder_workflow.release_pr_url = $rel
   | .steps.onboarder_workflow.status = "pr_raised"
   | .last_status_change_at = $ts' \
  "$PIPELINE_STATE" > "$TMP" && mv "$TMP" "$PIPELINE_STATE"

echo "PR_URL=${CI_PR_URL}"
[[ -n "$RELEASE_PR_URL" ]] && echo "RELEASE_PR_URL=${RELEASE_PR_URL}"
