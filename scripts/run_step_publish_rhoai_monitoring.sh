#!/usr/bin/env bash
# Wrapper for publishing the component Slack routing entry to rhoai-monitoring.
#
# Upserts the component into data/rhoai-component-data.yaml (Merge Request 18
# layout) and raises a GitLab Merge Request.
#
# Exit codes:
#   0  Merge Request raised — prints MR_URL=<url>; writes pipeline_state.json
#   1  Unexpected failure; pipeline_state.json NOT written
#   2  Entry already exists — writes pipeline_state.json (status=done)
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

JIRA_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jira-url) JIRA_URL="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$JIRA_URL" ]] && { echo "ERROR: --jira-url is required" >&2; exit 1; }

JIRA_ID="${JIRA_URL%/}"; JIRA_ID="${JIRA_ID##*/}"
WORKDIR="${WORKDIR:-$(pwd)/${JIRA_ID}}"
PIPELINE_STATE="${PIPELINE_STATE:-${WORKDIR}/pipeline_state.json}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ ! -f "$PIPELINE_STATE" ]] && {
  echo "ERROR: pipeline_state.json not found at $PIPELINE_STATE" >&2; exit 1
}

EXISTING_URL=$(jq -r '.steps.rhoai_monitoring.mr_url // ""' "$PIPELINE_STATE")
if [[ -n "$EXISTING_URL" ]]; then
  echo "Merge Request already recorded in state: $EXISTING_URL"
  echo "MR_URL=$EXISTING_URL"
  exit 0
fi

YAML_FILE="$WORKDIR/component_onboarding_details.yaml"
[[ ! -f "$YAML_FILE" ]] && { echo "ERROR: $YAML_FILE not found" >&2; exit 1; }

COMPONENT_NAME=$(grep -m1 'component_name:' "$YAML_FILE" | awk '{print $2}')
[[ -z "$COMPONENT_NAME" ]] && {
  echo "ERROR: component_name missing from YAML." >&2; exit 1
}

SLACK_TEAM_HANDLE=$(grep -m1 'slack_team_handle:' "$YAML_FILE" | awk '{print $2}' || true)
SLACK_TEAM_CHANNEL=$(grep -m1 'slack_team_channel:' "$YAML_FILE" | awk '{print $2}' || true)
[[ -z "$SLACK_TEAM_HANDLE" ]] && {
  echo "ERROR: slack_team_handle missing from component_onboarding_details.yaml." >&2
  echo "Re-run create-component-onboarding-jira to collect the Slack user-group handle." >&2
  exit 1
}

MONITORING_URL="${RHOAI_MONITORING_REPO_URL:-https://gitlab.cee.redhat.com/wznoinsk/rhoai-monitoring.git}"
MONITORING_SRC_BRANCH="${RHOAI_MONITORING_SRC_BRANCH:-main}"
ROUTING_FILE="data/rhoai-component-data.yaml"

echo "COMPONENT_NAME        : $COMPONENT_NAME"
echo "SLACK_TEAM_HANDLE     : $SLACK_TEAM_HANDLE"
echo "SLACK_TEAM_CHANNEL    : ${SLACK_TEAM_CHANNEL:-"(none)"}"
echo "MONITORING_URL        : $MONITORING_URL"
echo "MONITORING_SRC_BRANCH : $MONITORING_SRC_BRANCH"

cd "$WORKDIR"
PLAYPEN_OUTPUT=$(GITLAB_SSL_VERIFY=false bash "$SCRIPTS_DIR/setup_gitlab_playpen.sh" \
  --src-url  "$MONITORING_URL" \
  --dest-url "$MONITORING_URL" \
  --src-branch "$MONITORING_SRC_BRANCH" \
  --dest-branch "$JIRA_ID" \
  --sparse-files "$ROUTING_FILE") || {
  echo "ERROR: Playpen setup for rhoai-monitoring failed. Check VPN and GITLAB_TOKEN." >&2
  echo "If Merge Request 18 is not merged yet, set RHOAI_MONITORING_SRC_BRANCH to that source branch." >&2
  exit 1
}
CLONE_DIR=$(echo "$PLAYPEN_OUTPUT" | head -1)
DEST_BRANCH=$(echo "$PLAYPEN_OUTPUT" | tail -1)

ROUTING_YAML="$CLONE_DIR/$ROUTING_FILE"
[[ ! -f "$ROUTING_YAML" ]] && {
  echo "ERROR: $ROUTING_FILE not found in $CLONE_DIR." >&2
  echo "If Merge Request 18 is not merged yet, set RHOAI_MONITORING_SRC_BRANCH to that source branch." >&2
  exit 1
}

UPSERT_ARGS=(
  "$ROUTING_YAML"
  --component-name "$COMPONENT_NAME"
  --slack-team-handle "$SLACK_TEAM_HANDLE"
)
[[ -n "${SLACK_TEAM_CHANNEL:-}" ]] && UPSERT_ARGS+=(--slack-team-channel "$SLACK_TEAM_CHANNEL")

set +e
UPSERT_JSON=$(uv run --script "$SCRIPTS_DIR/upsert_rhoai_component_contact.py" "${UPSERT_ARGS[@]}" 2>&1)
UPSERT_RC=$?
set -e

if [[ "$UPSERT_RC" -eq 1 ]]; then
  echo "ERROR: Could not upsert Slack routing for '${COMPONENT_NAME}'." >&2
  echo "$UPSERT_JSON" >&2
  echo "The file must use the Merge Request 18 layout (top-level 'components:' mapping)." >&2
  echo "If Merge Request 18 is not merged yet, set RHOAI_MONITORING_SRC_BRANCH to that source branch." >&2
  exit 1
fi

if [[ "$UPSERT_RC" -eq 2 ]]; then
  echo "Slack routing for '${COMPONENT_NAME}' already present in $ROUTING_FILE."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "rhoai-monitoring-exists" \
    --comment "[step:rhoai_monitoring] Slack routing for '${COMPONENT_NAME}' already exists in rhoai-monitoring. No Merge Request needed.

Handle: @${SLACK_TEAM_HANDLE}" || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step rhoai_monitoring --status done
  exit 2
fi

CHANNEL_LINE=""
[[ -n "${SLACK_TEAM_CHANNEL:-}" ]] && CHANNEL_LINE="
Channel: #${SLACK_TEAM_CHANNEL}"

bash "$SCRIPTS_DIR/git_commit_push.sh" \
  --clone-dir "$CLONE_DIR" \
  --files     "$ROUTING_FILE" \
  --message   "Add ${COMPONENT_NAME} Slack routing

Routes ${COMPONENT_NAME} to @${SLACK_TEAM_HANDLE} in ${ROUTING_FILE}.

Related: ${JIRA_ID}" \
  --branch "$DEST_BRANCH"

MR_URL=""
for attempt in 1 2 3; do
  MR_URL=$(GITLAB_SSL_VERIFY=false uv run --script "$SCRIPTS_DIR/raise_gitlab_mr.py" \
    --src-url     "$MONITORING_URL" \
    --src-branch  "$DEST_BRANCH" \
    --dest-url    "$MONITORING_URL" \
    --dest-branch "$MONITORING_SRC_BRANCH" \
    --title       "Add ${COMPONENT_NAME} Slack routing" \
    --description "Adds Slack routing for \`${COMPONENT_NAME}\` to \`${ROUTING_FILE}\`.

Handle: @${SLACK_TEAM_HANDLE}${CHANNEL_LINE}
Jira: ${JIRA_URL}" 2>/dev/null) && break
  [[ "$attempt" -eq 3 ]] && {
    echo "ERROR: Could not create Merge Request after 3 attempts." >&2; exit 1
  }
  sleep 5
done

uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
  --add-label "rhoai-monitoring-mr-raised" \
  --comment "[step:rhoai_monitoring] GitLab Merge Request raised to add '${COMPONENT_NAME}' Slack routing.

Merge Request URL: ${MR_URL}
Handle: @${SLACK_TEAM_HANDLE}${CHANNEL_LINE}" || true

bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
  --state "$PIPELINE_STATE" --step rhoai_monitoring \
  --status mr_raised --url "$MR_URL" --url-field mr_url

echo "MR_URL=${MR_URL}"
