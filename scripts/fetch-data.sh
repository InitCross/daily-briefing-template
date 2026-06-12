#!/usr/bin/env bash
# Fetch source data for the daily briefing: your open work items + active PRs
# from Azure DevOps. Output: single JSON object on stdout.
set -euo pipefail

: "${ADO_PAT:?ADO_PAT not set}"

ADO_ORG="${ADO_ORG:-https://dev.azure.com/infogrammer}"
ADO_AUTH=$(printf ':%s' "$ADO_PAT" | base64 -w0)
OWNER_NAME="${OWNER_NAME:-there}"

# Bangkok = UTC+7
TODAY_BKK=$(TZ='Asia/Bangkok' date +%Y-%m-%d)
WEEKDAY_BKK=$(TZ='Asia/Bangkok' date +%u)        # 1=Mon..7=Sun
WEEKDAY_NAME_TH=$(TZ='Asia/Bangkok' date +%A | sed -e 's/Monday/จันทร์/' -e 's/Tuesday/อังคาร/' -e 's/Wednesday/พุธ/' -e 's/Thursday/พฤหัสบดี/' -e 's/Friday/ศุกร์/' -e 's/Saturday/เสาร์/' -e 's/Sunday/อาทิตย์/')

###############################################################################
# Azure DevOps: my work items via WIQL
###############################################################################
WIQL_QUERY=$(cat <<'EOF'
{
  "query": "SELECT [System.Id] FROM WorkItems WHERE [System.AssignedTo] = @Me AND [System.State] NOT IN ('Closed','Done','Removed') ORDER BY [Microsoft.VSTS.Common.Priority] ASC, [System.ChangedDate] DESC"
}
EOF
)

WIQL_RESPONSE=$(curl -sS -X POST \
  -H "Authorization: Basic ${ADO_AUTH}" \
  -H "Content-Type: application/json" \
  -d "$WIQL_QUERY" \
  "${ADO_ORG}/_apis/wit/wiql?api-version=7.1")

WORK_ITEM_IDS=$(echo "$WIQL_RESPONSE" | jq -r '.workItems[].id' | head -50 | paste -sd, -)

WORK_ITEMS_JSON='[]'
ITERATION_MAP='{}'
if [ -n "$WORK_ITEM_IDS" ]; then
  WI_FIELDS="System.Id,System.Title,System.WorkItemType,System.State,System.TeamProject,System.IterationPath,System.Tags,System.ChangedDate,Microsoft.VSTS.Common.Priority,Microsoft.VSTS.Scheduling.TargetDate"
  WI_RAW=$(curl -sS \
    -H "Authorization: Basic ${ADO_AUTH}" \
    "${ADO_ORG}/_apis/wit/workitems?ids=${WORK_ITEM_IDS}&fields=${WI_FIELDS}&api-version=7.1")

  # Build iteration map: iteration_path -> finishDate (per project)
  PROJECTS=$(echo "$WI_RAW" | jq -r '[.value[].fields["System.TeamProject"]] | unique | .[]')
  for proj in $PROJECTS; do
    enc_proj=$(jq -rn --arg s "$proj" '$s|@uri')
    tree=$(curl -sS -H "Authorization: Basic ${ADO_AUTH}" \
      "${ADO_ORG}/${enc_proj}/_apis/wit/classificationnodes/iterations?%24depth=10&api-version=7.1" \
      || echo '{}')
    # Flatten tree → array of {path, finishDate}
    flat=$(echo "$tree" | jq '
      [.. | objects | select(.path? and .attributes?) | {
        tree_path: .path,
        finishDate: .attributes.finishDate,
        startDate: .attributes.startDate
      }] | map(select(.finishDate != null))
      | map(. + {iteration_path: (.tree_path | sub("^\\\\"; "") | sub("\\\\Iteration\\\\"; "\\") | sub("\\\\Iteration$"; ""))})
    ' 2>/dev/null || echo '[]')
    # Merge into ITERATION_MAP (keyed by iteration_path)
    ITERATION_MAP=$(jq -s '
      .[0] as $base |
      .[1] | reduce .[] as $i ($base; .[$i.iteration_path] = {finishDate: $i.finishDate, startDate: $i.startDate})
    ' <(echo "$ITERATION_MAP") <(echo "$flat"))
  done

  WORK_ITEMS_JSON=$(echo "$WI_RAW" \
    | jq --arg today "$TODAY_BKK" --argjson iter_map "$ITERATION_MAP" '[.value[] | {
        id: .id,
        title: .fields["System.Title"],
        type: .fields["System.WorkItemType"],
        state: .fields["System.State"],
        project: .fields["System.TeamProject"],
        priority: (.fields["Microsoft.VSTS.Common.Priority"] // null),
        iteration: (.fields["System.IterationPath"] // null),
        iteration_end: (
          if .fields["System.IterationPath"] then
            ($iter_map[.fields["System.IterationPath"]].finishDate // null)
          else null end
        ),
        iteration_overdue: (
          if .fields["System.IterationPath"] and $iter_map[.fields["System.IterationPath"]].finishDate then
            ($iter_map[.fields["System.IterationPath"]].finishDate[0:10] < $today)
          else false end
        ),
        target_date: (.fields["Microsoft.VSTS.Scheduling.TargetDate"] // null),
        target_overdue: (
          if .fields["Microsoft.VSTS.Scheduling.TargetDate"] then
            (.fields["Microsoft.VSTS.Scheduling.TargetDate"][0:10] < $today)
          else false end
        ),
        tags: (.fields["System.Tags"] // null),
        days_since_changed: (
          if .fields["System.ChangedDate"] then
            (((($today + "T00:00:00Z") | fromdateiso8601) - (.fields["System.ChangedDate"] | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) / 86400 | floor)
          else null end
        ),
        url: ("https://dev.azure.com/infogrammer/_workitems/edit/" + (.id|tostring))
      }]')
fi

###############################################################################
# Azure DevOps: my active PRs (across all projects)
###############################################################################
ME_ID=$(curl -sS \
  -H "Authorization: Basic ${ADO_AUTH}" \
  "${ADO_ORG}/_apis/connectionData?api-version=1.0" \
  | jq -r '.authenticatedUser.id')

MY_PRS_JSON='[]'
if [ -n "$ME_ID" ] && [ "$ME_ID" != "null" ]; then
  MY_PRS_JSON=$(curl -sS \
    -H "Authorization: Basic ${ADO_AUTH}" \
    "${ADO_ORG}/_apis/git/pullrequests?searchCriteria.creatorId=${ME_ID}&searchCriteria.status=active&api-version=7.1" \
    | jq --arg today "$TODAY_BKK" '[.value[] | {
        id: .pullRequestId,
        title: .title,
        repo: .repository.name,
        project: .repository.project.name,
        url: ("https://dev.azure.com/infogrammer/" + (.repository.project.name|@uri) + "/_git/" + (.repository.name|@uri) + "/pullrequest/" + (.pullRequestId|tostring)),
        is_draft: .isDraft,
        merge_status: .mergeStatus,
        created_at: .creationDate,
        days_open: (((($today + "T00:00:00Z") | fromdateiso8601) - (.creationDate | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) / 86400 | floor),
        has_any_vote: ([.reviewers[].vote // 0] | map(select(. != 0)) | length > 0),
        max_vote: ([.reviewers[].vote // 0] | max // 0),
        min_vote: ([.reviewers[].vote // 0] | min // 0),
        reviewers: [.reviewers[] | {name: .displayName, vote: .vote}]
      }]')
fi

###############################################################################
# Assemble final output
###############################################################################
jq -n \
  --arg today "$TODAY_BKK" \
  --arg weekday "$WEEKDAY_BKK" \
  --arg weekday_th "$WEEKDAY_NAME_TH" \
  --arg owner "$OWNER_NAME" \
  --argjson work_items "$WORK_ITEMS_JSON" \
  --argjson my_prs "$MY_PRS_JSON" \
'{
  today: $today,
  weekday_iso: ($weekday | tonumber),
  weekday_th: $weekday_th,
  is_weekend: (($weekday | tonumber) >= 6),
  owner_name: $owner,
  work_items: $work_items,
  my_prs: $my_prs
}'
