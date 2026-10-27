#!/bin/bash
# Thin wrapper over Linear's GraphQL API (https://api.linear.app/graphql) for the factory skills.
# Exactly the calls the skills make, nothing else.
#
#   linear.sh issues <project> [label]     {project, issues:[...]} for the issues carrying the label (default: factory)
#   linear.sh issue <ID>                   one issue with comments and relations
#   linear.sh state <ID> "<state name>"    move the issue to the workflow state with that name (emoji included)
#   linear.sh assign <ID> [me]             assign the issue to the token's user
#   linear.sh comment <ID> <body|->        add a comment (body as the argument, or on stdin with -)
#
# <project> is the Linear project identifier (P-KIM-206), its slug id, or its UUID. <ID> is an issue identifier (KIM-123).
# Each issue is printed as: identifier, id, title, description, priority, createdAt, url, branchName, state, stateType,
# assignee, labels, blockedBy [{identifier, state, resolved}], blocks [identifier], comments [{createdAt, user, body}]
# (comments oldest first).
#
# Auth: LINEAR_TOKEN, brokered in by `keycard agent exec --config keycard.toml` (resource https://api.linear.app). It is
# either a personal API key (lin_api_..., sent bare, as Linear documents) or an OAuth access token (sent as Bearer).
# When it is unset and keycard is on PATH, the script re-runs itself under keycard agent exec, so by-hand use is
# brokered and audited too. Any failure, including a rejected token, is exit 1 with the reason on stderr; nothing
# is retried.
set -euo pipefail

api=https://api.linear.app/graphql
here=$(cd "$(dirname "$0")" && pwd)

die() { echo "linear.sh: $*" >&2; exit 1; }

if [[ -z ${LINEAR_TOKEN:-} ]]; then
  [[ -z ${FACTORY_LINEAR_REEXEC:-} ]] || die "keycard agent exec did not provide LINEAR_TOKEN; check [[credentials.default]] in $here/../keycard.toml"
  command -v keycard >/dev/null || die "LINEAR_TOKEN is not set and keycard is not on PATH; run under keycard agent exec --config keycard.toml"
  # shellcheck disable=SC2086
  FACTORY_LINEAR_REEXEC=1 exec keycard agent exec --config "$here/../keycard.toml" ${KEYCARD_ZONE:+--zone "$KEYCARD_ZONE"} -- "$0" "$@"
fi

# Personal API keys go bare in the Authorization header; OAuth access tokens take the Bearer scheme.
if [[ $LINEAR_TOKEN == lin_api_* ]]; then auth=$LINEAR_TOKEN; else auth="Bearer $LINEAR_TOKEN"; fi

# gql <query> <variables-json>: prints .data, or dies with Linear's error.
gql() {
  local body out code json
  body=$(jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')
  out=$(curl -sS -w '\n%{http_code}' -X POST "$api" \
        -H "Authorization: $auth" -H 'Content-Type: application/json' --data "$body") \
    || die "cannot reach $api"
  code=${out##*$'\n'}; json=${out%$'\n'*}
  case $code in
    200|400) ;;
    401|403) die "Linear token rejected (HTTP $code); check the https://api.linear.app resource in Keycard (API key revoked or missing Read/Write?)" ;;
    *) die "HTTP $code from Linear: $(printf %s "$json" | head -c 300)" ;;
  esac
  if printf %s "$json" | jq -e '(.errors // []) | length > 0' >/dev/null; then
    die "$(printf %s "$json" | jq -r '[.errors[].message] | join("; ")')"
  fi
  printf '%s\n' "$json" | jq '.data'
}

# jq normalization of an Issue selected with $fields.
norm='def norm: {
  identifier, id, title, description, priority, createdAt, url, branchName,
  state: .state.name, stateType: .state.type,
  assignee: (.assignee.email // .assignee.name),
  labels: [.labels.nodes[].name],
  blockedBy: [.inverseRelations.nodes[] | select(.type == "blocks")
              | {identifier: .issue.identifier, state: .issue.state.name,
                 resolved: (.issue.state.type == "completed" or .issue.state.type == "canceled")}],
  blocks: [.relations.nodes[] | select(.type == "blocks") | .relatedIssue.identifier],
  comments: ([.comments.nodes[] | {createdAt, user: (.user.name // .botActor.name // "unknown"), body}] | sort_by(.createdAt))
};'
fields='id identifier title description priority createdAt url branchName
  state { name type } assignee { name email } labels { nodes { name } }
  comments(first: 100) { nodes { createdAt body user { name } botActor { name } } }
  inverseRelations { nodes { type issue { identifier state { name type } } } }
  relations { nodes { type relatedIssue { identifier state { name type } } } }'

# resolve_project <ref>: prints {id, identifier, name, url}. Runs inside $(...), where bash drops errexit,
# so every gql failure exits explicitly.
resolve_project() {
  local ref=$1 after=null page found
  if [[ $ref =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    page=$(gql 'query($id: String!) { project(id: $id) { id identifier name url } }' "$(jq -n --arg id "$ref" '{id: $id}')") || exit 1
    jq '.project' <<<"$page"
    return
  fi
  while :; do
    page=$(gql 'query($after: String) { projects(first: 100, after: $after) {
                  nodes { id identifier slugId name url previousIdentifiers } pageInfo { hasNextPage endCursor } } }' \
                "$(jq -n --argjson after "$after" '{after: $after}')") || exit 1
    found=$(jq -c --arg r "$ref" 'first(.projects.nodes[] | select(.identifier == $r or .slugId == $r or (.previousIdentifiers | index($r))))
                                  | {id, identifier, name, url}' <<<"$page")
    [[ -z $found ]] || { printf '%s\n' "$found"; return; }
    jq -e '.projects.pageInfo.hasNextPage' <<<"$page" >/dev/null || die "no Linear project matches '$ref'"
    after=$(jq '.projects.pageInfo.endCursor' <<<"$page")
  done
}

# issue_uuid <ID>: prints the issue's UUID (mutations take ids, not identifiers).
issue_uuid() {
  local d
  d=$(gql 'query($id: String!) { issue(id: $id) { id } }' "$(jq -n --arg id "$1" '{id: $id}')") || exit 1
  jq -r '.issue.id' <<<"$d"
}

usage() { sed -n '2,10p' "$0" >&2; exit 2; }

cmd=${1:-}; [[ $# -ge 2 ]] || usage
id=$2
case $cmd in
  issues)
    label=${3:-factory}
    project=$(resolve_project "$id")
    gql "query(\$pid: ID!, \$label: String!) {
           issues(first: 250, filter: { project: { id: { eq: \$pid } }, labels: { some: { name: { eq: \$label } } } }) {
             nodes { $fields } } }" \
        "$(jq -n --arg pid "$(jq -r .id <<<"$project")" --arg label "$label" '{pid: $pid, label: $label}')" \
      | jq --argjson project "$project" "$norm"'{project: $project, issues: [.issues.nodes[] | norm]}'
    ;;
  issue)
    gql "query(\$id: String!) { issue(id: \$id) { $fields } }" "$(jq -n --arg id "$id" '{id: $id}')" | jq "$norm"'.issue | norm'
    ;;
  state)
    [[ $# -eq 3 ]] || usage
    name=$3
    d=$(gql 'query($id: String!) { issue(id: $id) { id identifier team { states(first: 100) { nodes { id name } } } } }' \
            "$(jq -n --arg id "$id" '{id: $id}')")
    # Exact name first, then the same name ignoring emoji, variation selectors, spacing and case.
    sid=$(jq -r --arg n "$name" '
      def key: gsub("[^A-Za-z0-9]"; "") | ascii_downcase;
      .issue.team.states.nodes as $s
      | (first($s[] | select(.name == $n)) // first($s[] | select((.name | key) == ($n | key))) // empty).id' <<<"$d")
    [[ -n $sid ]] || die "no workflow state named '$name' on $id's team; states: $(jq -r '[.issue.team.states.nodes[].name] | join(", ")' <<<"$d")"
    gql 'mutation($id: String!, $sid: String!) { issueUpdate(id: $id, input: { stateId: $sid }) { success issue { identifier state { name } } } }' \
        "$(jq -n --arg id "$(jq -r .issue.id <<<"$d")" --arg sid "$sid" '{id: $id, sid: $sid}')" \
      | jq -r '"\(.issueUpdate.issue.identifier) → \(.issueUpdate.issue.state.name)"'
    ;;
  assign)
    [[ ${3:-me} == me ]] || die "assign: only 'me' (the token's user) is supported"
    d=$(gql 'query($id: String!) { viewer { id name } issue(id: $id) { id } }' "$(jq -n --arg id "$id" '{id: $id}')")
    gql 'mutation($id: String!, $uid: String!) { issueUpdate(id: $id, input: { assigneeId: $uid }) { success issue { identifier assignee { name } } } }' \
        "$(jq -n --arg id "$(jq -r .issue.id <<<"$d")" --arg uid "$(jq -r .viewer.id <<<"$d")" '{id: $id, uid: $uid}')" \
      | jq -r '"\(.issueUpdate.issue.identifier) → \(.issueUpdate.issue.assignee.name)"'
    ;;
  comment)
    [[ $# -eq 3 ]] || usage
    body=$3; [[ $body != - ]] || body=$(cat)
    [[ -n $body ]] || die "comment: empty body"
    iid=$(issue_uuid "$id")
    gql 'mutation($iid: String!, $body: String!) { commentCreate(input: { issueId: $iid, body: $body }) { success comment { url } } }' \
        "$(jq -n --arg iid "$iid" --arg body "$body" '{iid: $iid, body: $body}')" \
      | jq -r '.commentCreate.comment.url'
    ;;
  *) usage ;;
esac
