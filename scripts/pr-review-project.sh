#!/usr/bin/env bash
# devpilot-pr-review-project — idempotent GitHub Projects v2 status transitions for PR reviews.
set -euo pipefail

readonly DEFAULT_FIELD_NAME="Review status"
readonly STATUS_WAITING="Waiting to be picked up"
readonly STATUS_REVIEWING="Being reviewed"
readonly STATUS_REVIEWED="Reviewed"

usage() {
  cat <<'EOF'
Usage:
  pr-review-project.sh setup --project <url|owner/number> [--field <name>]
  pr-review-project.sh set --pr <pull-request-url> --status <status> [--project <url|owner/number>] [--field <name>]
  pr-review-project.sh archive --pr <pull-request-url> [--project <url|owner/number>]
  pr-review-project.sh sweep-closed [--project <url|owner/number>]

Project resolution for `set`, `archive`, and `sweep-closed`, in order:
  --project, DEVPILOT_REVIEW_PROJECT, git config devpilot.reviewProject

Statuses:
  Waiting to be picked up
  Being reviewed
  Reviewed
EOF
}

die() {
  printf 'pr-review-project: %s\n' "$*" >&2
  exit 1
}

scope_hint() {
  local message=$1
  if [[ "$message" == *"missing required scopes"* || "$message" == *"Resource not accessible"* ]]; then
    die "GitHub Projects access is not authorized; run: gh auth refresh -s project"
  fi
  die "$message"
}

run_gh() {
  local output message review_project_error_file
  review_project_error_file=$(mktemp "${TMPDIR:-/tmp}/devpilot-review-project.XXXXXX")
  if output=$(gh "$@" 2>"$review_project_error_file"); then
    rm -f "$review_project_error_file"
    printf '%s' "$output"
    return
  fi
  message=$(<"$review_project_error_file")
  rm -f "$review_project_error_file"
  [[ -n "$message" ]] || message="gh command failed"
  scope_hint "$message"
}

resolve_project_ref() {
  local ref=${1:-}
  if [[ -z "$ref" ]]; then
    ref=${DEVPILOT_REVIEW_PROJECT:-}
  fi
  if [[ -z "$ref" ]] && git rev-parse --git-dir >/dev/null 2>&1; then
    ref=$(git config --get devpilot.reviewProject 2>/dev/null || true)
  fi
  [[ -n "$ref" ]] || die "no review project configured; pass --project, set DEVPILOT_REVIEW_PROJECT, or run: git config devpilot.reviewProject <project-url>"

  if [[ "$ref" =~ ^https?://[^/]+/(users|orgs)/([^/]+)/projects/([0-9]+)/?([?#].*)?$ ]]; then
    PROJECT_OWNER=${BASH_REMATCH[2]}
    PROJECT_NUMBER=${BASH_REMATCH[3]}
  elif [[ "$ref" =~ ^([^/]+)/([0-9]+)$ ]]; then
    PROJECT_OWNER=${BASH_REMATCH[1]}
    PROJECT_NUMBER=${BASH_REMATCH[2]}
  else
    die "invalid project reference '$ref'; expected https://github.com/{users|orgs}/OWNER/projects/NUMBER or OWNER/NUMBER"
  fi
  PROJECT_REF="$PROJECT_OWNER/$PROJECT_NUMBER"
}

validate_status() {
  case "$1" in
    "$STATUS_WAITING"|"$STATUS_REVIEWING"|"$STATUS_REVIEWED") ;;
    *) die "invalid status '$1'; expected '$STATUS_WAITING', '$STATUS_REVIEWING', or '$STATUS_REVIEWED'" ;;
  esac
}

load_project() {
  local project_json
  project_json=$(run_gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json)
  PROJECT_ID=$(jq -er '.id' <<<"$project_json") || die "could not resolve project ID for $PROJECT_REF"
  PROJECT_URL=$(jq -r '.url // empty' <<<"$project_json")
  [[ -n "$PROJECT_URL" ]] || PROJECT_URL="https://github.com/users/$PROJECT_OWNER/projects/$PROJECT_NUMBER"
}

load_field() {
  local fields_json
  fields_json=$(run_gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --limit 100 --format json)
  FIELD_JSON=$(jq -c --arg name "$FIELD_NAME" 'first(.fields[]? | select(.name == $name)) // empty' <<<"$fields_json")
}

verify_field() {
  local status option_id
  [[ -n "$FIELD_JSON" ]] || die "project $PROJECT_REF has no '$FIELD_NAME' field; run setup first"
  FIELD_ID=$(jq -er '.id' <<<"$FIELD_JSON") || die "field '$FIELD_NAME' has no ID"

  for status in "$STATUS_WAITING" "$STATUS_REVIEWING" "$STATUS_REVIEWED"; do
    option_id=$(jq -r --arg status "$status" 'first(.options[]? | select(.name == $status)) | .id // empty' <<<"$FIELD_JSON")
    [[ -n "$option_id" ]] || die "field '$FIELD_NAME' is missing option '$status'; add the three documented options in the project settings"
  done
}

setup_project() {
  load_project
  load_field
  if [[ -z "$FIELD_JSON" ]]; then
    run_gh project field-create "$PROJECT_NUMBER" \
      --owner "$PROJECT_OWNER" \
      --name "$FIELD_NAME" \
      --data-type SINGLE_SELECT \
      --single-select-options "$STATUS_WAITING,$STATUS_REVIEWING,$STATUS_REVIEWED" \
      --format json >/dev/null
    load_field
  fi
  verify_field
  jq -n \
    --arg project "$PROJECT_URL" \
    --arg field "$FIELD_NAME" \
    '{project: $project, field: $field, ready: true}'
}

load_items() {
  ITEMS_JSON=$(run_gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --limit 1000 --format json)
}

find_item() {
  load_items
  ITEM_ID=$(jq -r --arg url "$PR_URL" 'first(.items[]? | select(.content.url == $url)) | .id // empty' <<<"$ITEMS_JSON")
}

find_or_add_item() {
  local item_json
  find_item
  if [[ -z "$ITEM_ID" ]]; then
    item_json=$(run_gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$PR_URL" --format json)
    ITEM_ID=$(jq -r '.id // empty' <<<"$item_json")
    [[ -n "$ITEM_ID" ]] || die "GitHub added $PR_URL to the project but returned no item ID"
  fi
}

archive_item_id() {
  run_gh project item-archive "$PROJECT_NUMBER" \
    --owner "$PROJECT_OWNER" \
    --id "$1" \
    --format json >/dev/null
}

archive_pr() {
  load_project
  find_item

  if [[ -z "$ITEM_ID" ]]; then
    jq -n \
      --arg project "$PROJECT_URL" \
      --arg pr "$PR_URL" \
      '{project: $project, pr: $pr, archived: false, reason: "not-found"}'
    return
  fi

  archive_item_id "$ITEM_ID"
  jq -n \
    --arg project "$PROJECT_URL" \
    --arg pr "$PR_URL" \
    --arg itemId "$ITEM_ID" \
    '{project: $project, pr: $pr, archived: true, itemId: $itemId}'
}

sweep_closed_prs() {
  local archived_count=0 item_id stale_item_ids
  load_project
  load_items
  stale_item_ids=$(jq -r '
    .items[]?
    | select(.content.type == "PullRequest")
    | select((.content.state // "" | ascii_upcase) == "MERGED" or (.content.state // "" | ascii_upcase) == "CLOSED")
    | .id
  ' <<<"$ITEMS_JSON")

  while IFS= read -r item_id; do
    [[ -n "$item_id" ]] || continue
    archive_item_id "$item_id"
    archived_count=$((archived_count + 1))
  done <<<"$stale_item_ids"

  jq -n \
    --arg project "$PROJECT_URL" \
    --argjson archived "$archived_count" \
    '{project: $project, archived: $archived}'
}

status_option_id() {
  jq -r --arg status "$1" 'first(.options[]? | select(.name == $status)) | .id // empty' <<<"$FIELD_JSON"
}

set_status() {
  local option_id
  validate_status "$STATUS"
  load_project
  load_field
  verify_field
  find_or_add_item

  option_id=$(status_option_id "$STATUS")
  run_gh project item-edit \
    --id "$ITEM_ID" \
    --field-id "$FIELD_ID" \
    --project-id "$PROJECT_ID" \
    --single-select-option-id "$option_id" \
    --format json >/dev/null

  jq -n \
    --arg project "$PROJECT_URL" \
    --arg pr "$PR_URL" \
    --arg status "$STATUS" \
    --arg itemId "$ITEM_ID" \
    '{project: $project, pr: $pr, status: $status, itemId: $itemId}'
}

[[ $# -gt 0 ]] || { usage; exit 2; }
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi
COMMAND=$1
shift

PROJECT_ARG=""
PR_URL=""
STATUS=""
FIELD_NAME="$DEFAULT_FIELD_NAME"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) [[ $# -ge 2 ]] || die "--project needs a value"; PROJECT_ARG=$2; shift 2 ;;
    --pr) [[ $# -ge 2 ]] || die "--pr needs a value"; PR_URL=$2; shift 2 ;;
    --status) [[ $# -ge 2 ]] || die "--status needs a value"; STATUS=$2; shift 2 ;;
    --field) [[ $# -ge 2 ]] || die "--field needs a value"; FIELD_NAME=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

command -v gh >/dev/null || die "gh is required"
command -v jq >/dev/null || die "jq is required"

case "$COMMAND" in
  setup)
    [[ -n "$PROJECT_ARG" ]] || die "setup requires --project"
    resolve_project_ref "$PROJECT_ARG"
    setup_project
    ;;
  set)
    [[ "$PR_URL" =~ ^https?://[^/]+/[^/]+/[^/]+/pull/[0-9]+/?$ ]] || die "set requires a GitHub pull-request URL via --pr"
    [[ -n "$STATUS" ]] || die "set requires --status"
    resolve_project_ref "$PROJECT_ARG"
    set_status
    ;;
  archive)
    [[ "$PR_URL" =~ ^https?://[^/]+/[^/]+/[^/]+/pull/[0-9]+/?$ ]] || die "archive requires a GitHub pull-request URL via --pr"
    resolve_project_ref "$PROJECT_ARG"
    archive_pr
    ;;
  sweep-closed)
    [[ -z "$PR_URL" ]] || die "sweep-closed does not accept --pr"
    resolve_project_ref "$PROJECT_ARG"
    sweep_closed_prs
    ;;
  *) usage; die "unknown command '$COMMAND'" ;;
esac
