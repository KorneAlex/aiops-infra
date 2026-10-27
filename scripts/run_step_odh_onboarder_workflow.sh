#!/usr/bin/env bash
# Wrapper for ODH odh-konflux-onboarder workflow steps (CI and optional Release).
#
# Pipeline step keys:
#   onboarder_workflow — CI Tekton PR on repo_branch (always for ODH)
#   onboarder_release  — Release Tekton PR when odh_release_tag is set (or legacy build_type Release)
#
# Usage:
#   .../run_step_odh_onboarder_workflow.sh --jira-url <url> [--pipeline-step onboarder_workflow|onboarder_release]
#
# Exit codes:
#   0  Workflow triggered and Tekton PR URL extracted — prints PR_URL=<url>
#   1  Failure — pipeline_state.json NOT updated for this step
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

JIRA_URL=""
PIPELINE_STEP="onboarder_workflow"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jira-url)       JIRA_URL="$2";       shift 2 ;;
    --pipeline-step)  PIPELINE_STEP="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$JIRA_URL" ]] && { echo "ERROR: --jira-url is required" >&2; exit 1; }
[[ "$PIPELINE_STEP" == "onboarder_workflow" || "$PIPELINE_STEP" == "onboarder_release" ]] || {
  echo "ERROR: --pipeline-step must be onboarder_workflow or onboarder_release" >&2; exit 1
}

JIRA_ID="${JIRA_URL%/}"; JIRA_ID="${JIRA_ID##*/}"
WORKDIR="${WORKDIR:-$(pwd)/${JIRA_ID}}"
PIPELINE_STATE="${PIPELINE_STATE:-${WORKDIR}/pipeline_state.json}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ ! -f "$PIPELINE_STATE" ]] && {
  echo "ERROR: pipeline_state.json not found at $PIPELINE_STATE" >&2; exit 1
}

STEP_STATUS=$(jq -r --arg s "$PIPELINE_STEP" '.steps[$s].status // "pending"' "$PIPELINE_STATE")
if [[ "$STEP_STATUS" == "skipped" ]]; then
  echo "Step ${PIPELINE_STEP} is skipped — nothing to do."
  exit 0
fi

EXISTING_URL=$(jq -r --arg s "$PIPELINE_STEP" '.steps[$s].pr_url // ""' "$PIPELINE_STATE")
if [[ -n "$EXISTING_URL" ]]; then
  echo "PR already recorded in state: $EXISTING_URL"
  echo "PR_URL=$EXISTING_URL"
  exit 0
fi

if [[ "${ONBOARD_DRY_RUN:-false}" == "true" ]]; then
  echo "ONBOARD_DRY_RUN=true — skipping onboarder workflow trigger, marking ${PIPELINE_STEP} as done."
  LABEL="tekton-pr-raised"
  [[ "$PIPELINE_STEP" == "onboarder_release" ]] && LABEL="tekton-release-pr-raised"
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "$LABEL" \
    --comment "[step:${PIPELINE_STEP}] Skipped (ONBOARD_DRY_RUN=true). ODH onboarder workflow not triggered." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step "$PIPELINE_STEP" \
    --status done
  exit 0
fi

YAML_FILE="$WORKDIR/component_onboarding_details.yaml"
[[ ! -f "$YAML_FILE" ]] && { echo "ERROR: $YAML_FILE not found" >&2; exit 1; }

REPO_URL=$(grep -m1       'repo_url:'           "$YAML_FILE" | awk '{print $2}')
REPO_BRANCH=$(grep -m1    'repo_branch:'        "$YAML_FILE" | awk '{print $2}')
YAML_BUILD_TYPE=$(grep -m1 'build_type:'       "$YAML_FILE" | awk '{print $2}' 2>/dev/null || echo "CI")
ODH_RELEASE_TAG=$(grep -m1 'odh_release_tag:'   "$YAML_FILE" | awk '{print $2}' 2>/dev/null || echo "")
ODH_RELEASE_BRANCH=$(grep -m1 'odh_release_branch:' "$YAML_FILE" | awk '{print $2}' 2>/dev/null || echo "")
[[ -z "$ODH_RELEASE_BRANCH" ]] && ODH_RELEASE_BRANCH="stable"

REPO_NAME="${REPO_URL##*/}"; REPO_NAME="${REPO_NAME%.git}"
COMPONENT="$REPO_NAME"

if [[ "$PIPELINE_STEP" == "onboarder_workflow" ]]; then
  BUILD_TYPE="CI"
  TARGET_BRANCH="$REPO_BRANCH"
  VERSION=""
  LABEL_RAISED="tekton-pr-raised"
elif [[ "$PIPELINE_STEP" == "onboarder_release" ]]; then
  if [[ -z "$ODH_RELEASE_TAG" ]]; then
    if [[ "$YAML_BUILD_TYPE" == "Release" ]]; then
      echo "ERROR: onboarder_release requires odh_release_tag in YAML." >&2
      exit 1
    fi
    echo "No odh_release_tag — skipping onboarder_release."
    bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
      --state "$PIPELINE_STATE" --step onboarder_release \
      --status skipped
    exit 0
  fi
  BUILD_TYPE="Release"
  TARGET_BRANCH="$ODH_RELEASE_BRANCH"
  VERSION="$ODH_RELEASE_TAG"
  LABEL_RAISED="tekton-release-pr-raised"
fi

OKC_URL="${ODH_KONFLUX_CENTRAL_REPO_URL:-https://github.com/opendatahub-io/odh-konflux-central.git}"
OKC_PATH=$(echo "$OKC_URL" | sed 's|https://github.com/||;s|\.git$||')
WORKFLOW_FILE=".github/workflows/odh-konflux-onboarder.yml"
OKC_REF="main"

echo "Triggering odh-konflux-onboarder (${PIPELINE_STEP}) for component: $COMPONENT"
echo "OKC_URL     : $OKC_URL"
echo "Build type  : $BUILD_TYPE"
echo "Branch      : $TARGET_BRANCH"
[[ -n "$VERSION" ]] && echo "Release tag : $VERSION"

WORKFLOW_INPUTS=(
  "--input" "component=$COMPONENT"
  "--input" "pr_target_branch=$TARGET_BRANCH"
  "--input" "build_type=$BUILD_TYPE"
)
[[ -n "$VERSION" ]] && WORKFLOW_INPUTS+=("--input" "version=$VERSION")

RUN_ID=""
for attempt in 1 2 3; do
  TRIGGER_ERR=$(uv run --script "$SCRIPTS_DIR/run_github_workflow.py" trigger \
    --repo-url  "$OKC_URL" \
    --workflow  "$WORKFLOW_FILE" \
    --ref       "$OKC_REF" \
    "${WORKFLOW_INPUTS[@]}" 2>/tmp/onboarder_trigger_err.txt) && {
    RUN_ID="$TRIGGER_ERR"
    break
  }
  ERR_CONTENT=$(cat /tmp/onboarder_trigger_err.txt 2>/dev/null || echo "")
  if echo "$ERR_CONTENT" | grep -q "403"; then
    echo "ERROR: HTTP 403 — GITHUB_TOKEN needs 'actions:write' scope." >&2; exit 1
  fi
  if echo "$ERR_CONTENT" | grep -q "404"; then
    echo "ERROR: HTTP 404 — workflow or repo not found." >&2; exit 1
  fi
  if echo "$ERR_CONTENT" | grep -q "422"; then
    echo "ERROR: HTTP 422 — component may not be registered in the workflow yet." >&2
    echo "  Ensure the okc PR is merged and the component appears in the workflow's component list." >&2
    exit 1
  fi
  [[ "$attempt" -eq 3 ]] && {
    echo "ERROR: Could not trigger odh-konflux-onboarder workflow after 3 attempts." >&2
    cat /tmp/onboarder_trigger_err.txt >&2
    exit 1
  }
  sleep 10
done

RUN_URL="https://github.com/${OKC_PATH}/actions/runs/${RUN_ID}"
echo "Workflow triggered. Run ID: $RUN_ID"
echo "Run URL: $RUN_URL"

uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
  --add-label "$LABEL_RAISED" \
  --comment "[step:${PIPELINE_STEP}] odh-konflux-onboarder workflow triggered (Run #${RUN_ID}).

Component: ${COMPONENT}
Repo: ${REPO_URL}
Build type: ${BUILD_TYPE}
Target branch: ${TARGET_BRANCH}

Workflow run: ${RUN_URL}

Monitoring for Tekton PR URL..." || true

MONITOR_OUTPUT=$(uv run --script "$SCRIPTS_DIR/run_github_workflow.py" monitor \
  --repo-url      "$OKC_URL" \
  --run-id        "$RUN_ID" \
  --timeout       30 \
  --poll-interval 60 2>/dev/null || echo "status=failure")
WORKFLOW_STATUS="${MONITOR_OUTPUT#status=}"

if [[ "$WORKFLOW_STATUS" != "success" ]]; then
  echo "ERROR: Onboarder workflow run ${RUN_ID} ended with status '${WORKFLOW_STATUS}'." >&2
  echo "Run URL: $RUN_URL" >&2
  exit 1
fi

TEKTON_PR_URL=$(uv run --script "$SCRIPTS_DIR/monitor_github_pr.py" \
  --repo-url  "$OKC_URL" \
  --run-id    "$RUN_ID" 2>/dev/null || echo "")

[[ -z "$TEKTON_PR_URL" ]] && {
  TEKTON_PR_URL=$(uv run --script "$SCRIPTS_DIR/run_github_workflow.py" get-step-logs \
    --repo-url "$OKC_URL" \
    --run-id   "$RUN_ID" \
    --step     "Create PR" 2>/dev/null \
    | grep -oE 'https://github.com/[^/]+/[^/]+/pull/[0-9]+' | head -1 || echo "")
}

[[ -z "$TEKTON_PR_URL" ]] && {
  echo "WARN: Could not extract Tekton PR URL from workflow logs."
  echo "  Check run manually: $RUN_URL"
  TEKTON_PR_URL="$RUN_URL"
}

uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
  --comment "[step:${PIPELINE_STEP}] odh-konflux-onboarder workflow completed.

Tekton PR: ${TEKTON_PR_URL}
Workflow run: ${RUN_URL}" || true

bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
  --state "$PIPELINE_STATE" --step "$PIPELINE_STEP" \
  --status pr_raised --url "$TEKTON_PR_URL" --url-field pr_url

echo "PR_URL=${TEKTON_PR_URL}"
