#!/usr/bin/env bash
# Fetch data for the weekly recap: work items closed + PRs completed Mon-Sun this week.
set -euo pipefail

: "${ADO_PAT:?ADO_PAT not set}"

ADO_ORG="${ADO_ORG:-https://dev.azure.com/infogrammer}"
ADO_AUTH=$(printf ':%s' "$ADO_PAT" | base64 -w0)
OWNER_NAME="${OWNER_NAME:-there}"

TODAY_BKK=$(TZ='Asia/Bangkok' date +%Y-%m-%d)

# Recap covers Mon → Sun. Anchor at most recent past Sunday (or today if today=Sun).
# Override via WEEK_END env var (YYYY-MM-DD) for testing arbitrary weeks.
WEEKDAY_BKK=$(TZ='Asia/Bangkok' date +%u)  # 1=Mon..7=Sun
if [ -n "${WEEK_END:-}" ]; then
  WEEK_END_BKK="$WEEK_END"
elif [ "$WEEKDAY_BKK" = "7" ]; then
  WEEK_END_BKK="$TODAY_BKK"
else
  WEEK_END_BKK=$(TZ='Asia/Bangkok' date -d "$TODAY_BKK -${WEEKDAY_BKK} days" +%Y-%m-%d)
fi
WEEK_START_BKK=$(TZ='Asia/Bangkok' date -d "$WEEK_END_BKK -6 days" +%Y-%m-%d)
WEEK_END_PLUS1=$(TZ='Asia/Bangkok' date -d "$WEEK_END_BKK +1 day" +%Y-%m-%d)

###############################################################################
# Closed/Done work items this week
###############################################################################
WIQL_QUERY=$(jq -n --arg start "$WEEK_START_BKK" --arg endplus1 "$WEEK_END_PLUS1" '{
  query: ("SELECT [System.Id] FROM WorkItems WHERE ([System.AssignedTo] = @Me OR [System.ChangedBy] = @Me OR [System.CreatedBy] = @Me) AND [System.ChangedDate] >= '\''" + $start + "'\'' AND [System.ChangedDate] < '\''" + $endplus1 + "'\'' ORDER BY [System.ChangedDate] DESC")
}')

WIQL_RESPONSE=$(curl -sS -X POST \
  -H "Authorization: Basic ${ADO_AUTH}" \
  -H "Content-Type: application/json" \
  -d "$WIQL_QUERY" \
  "${ADO_ORG}/_apis/wit/wiql?api-version=7.1")

WORK_ITEM_IDS=$(echo "$WIQL_RESPONSE" | jq -r '(.workItems // [])[].id' | tr -d '\r' | head -100 | paste -sd, -)

CLOSED_ITEMS_JSON='[]'
if [ -n "$WORK_ITEM_IDS" ]; then
  WI_FIELDS="System.Id,System.Title,System.WorkItemType,System.State,System.TeamProject,System.ChangedDate,System.AssignedTo,System.ChangedBy"
  CLOSED_ITEMS_JSON=$(curl -sS \
    -H "Authorization: Basic ${ADO_AUTH}" \
    "${ADO_ORG}/_apis/wit/workitems?ids=${WORK_ITEM_IDS}&fields=${WI_FIELDS}&api-version=7.1" \
    | jq '[(.value // [])[] |
        select(.fields["System.State"] | test("(Closed|Done|Resolved|Coding Complete|Ready for Test|Testing|Ready for QA|Ready for UAT|Verified|Completed)"; "i")) | {
          id: .id,
          title: .fields["System.Title"],
          type: .fields["System.WorkItemType"],
          state: .fields["System.State"],
          project: .fields["System.TeamProject"],
          closed_at: .fields["System.ChangedDate"],
          url: ("https://dev.azure.com/infogrammer/_workitems/edit/" + (.id|tostring))
      }]')
fi

###############################################################################
# PRs completed/merged this week
###############################################################################
ME_ID=$(curl -sS \
  -H "Authorization: Basic ${ADO_AUTH}" \
  "${ADO_ORG}/_apis/connectionData?api-version=1.0" \
  | jq -r '.authenticatedUser.id')

COMPLETED_PRS_JSON='[]'
if [ -n "$ME_ID" ] && [ "$ME_ID" != "null" ]; then
  COMPLETED_PRS_JSON=$(curl -sS \
    -H "Authorization: Basic ${ADO_AUTH}" \
    "${ADO_ORG}/_apis/git/pullrequests?searchCriteria.creatorId=${ME_ID}&searchCriteria.status=completed&\$top=50&api-version=7.1" \
    | jq --arg start "$WEEK_START_BKK" --arg end "$WEEK_END_BKK" '[(.value // [])[] |
        select(((.closedDate // .creationDate)[0:10] >= $start) and ((.closedDate // .creationDate)[0:10] <= $end)) | {
          id: .pullRequestId,
          title: .title,
          repo: .repository.name,
          project: .repository.project.name,
          closed_at: .closedDate,
          url: ("https://dev.azure.com/infogrammer/" + (.repository.project.name|@uri) + "/_git/" + (.repository.name|@uri) + "/pullrequest/" + (.pullRequestId|tostring))
        }]')
fi

###############################################################################
# Output
###############################################################################
jq -n \
  --arg today "$TODAY_BKK" \
  --arg week_start "$WEEK_START_BKK" \
  --arg week_end "$WEEK_END_BKK" \
  --arg owner "$OWNER_NAME" \
  --argjson closed "$CLOSED_ITEMS_JSON" \
  --argjson prs "$COMPLETED_PRS_JSON" \
'{
  today: $today,
  week_start: $week_start,
  week_end: $week_end,
  owner_name: $owner,
  closed_items: $closed,
  completed_prs: $prs,
  closed_count: ($closed | length),
  pr_count: ($prs | length)
}'
