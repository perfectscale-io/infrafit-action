#!/usr/bin/env bash
# infrafit-apply.sh — PerfectScale InfraFit NodePool reconciliation
#
# Fetches Karpenter NodePool recommendations from the PerfectScale API,
# translates them into edits on the caller's Helm values files, and opens a
# GitHub pull request for review.  Nothing is applied to a live cluster.
#
# AI is used for exactly one focused step: given the current YAML file and the
# structured list of changes from the API, produce the edited YAML.  Every
# other step — API calls, file routing, git operations, PR/issue creation — is
# plain shell.  Any provider that exposes an OpenAI-compatible chat-completions
# endpoint works (Anthropic, OpenAI, Azure OpenAI, …).
#
# This script is invoked by action.yml and is not intended to be called
# directly in most cases.  All configuration is passed via environment
# variables (set by action.yml from action inputs) and CLI flags.
#
# Flags:
#   --pr-mode      per-cluster|single   (default: per-cluster)
#   --title-prefix STRING               (default: "feat(INFRAFIT-0):")
#   --stub-file    PATH                 Skip the per-cluster API fetch and use
#                                       this local JSON as recommendations for
#                                       every mapped cluster (test mode).
#   --dry-run                           Print what would happen; make no changes.
#
# Required environment variables:
#   PS_CLIENT_ID        PerfectScale API client id
#   PS_CLIENT_SECRET    PerfectScale API client secret
#   GH_TOKEN            GitHub token (contents:write, pull-requests:write, issues:write)
#   AI_API_KEY          API key for the AI provider
#
# Optional environment variables:
#   PS_BASE_URL         PerfectScale API base URL
#                       (default: https://api.app.perfectscale.io/public/v1)
#   AI_PROVIDER         anthropic|openai  (auto-detected from key prefix when empty)
#   AI_BASE_URL         Override AI endpoint (e.g. Azure OpenAI deployment URL)
#   AI_MODEL            Override AI model
#   CLUSTER_MAP         Path to the cluster-map JSON file
#                       (default: .github/infrafit-cluster-map.json)
#   BRANCH_BASE         Base branch for PRs  (default: master)
#   RATE_LIMIT_SLEEP    Seconds between PerfectScale API calls  (default: 7)
#
# Runtime dependencies: bash ≥4, curl, jq, yq (mikefarah/yq v4+), git, gh

set -euo pipefail

# ─── constants ────────────────────────────────────────────────────────────────

readonly DEFAULT_PS_BASE_URL="https://api.app.perfectscale.io/public/v1"
readonly DEFAULT_RATE_LIMIT_SLEEP=7   # stay under 10 req/min PS rate limit
readonly DEFAULT_PR_MODE="per-cluster"
readonly DEFAULT_TITLE_PREFIX="feat(INFRAFIT-0):"
readonly DEFAULT_BRANCH_BASE="master"
readonly DEFAULT_CLUSTER_MAP=".github/infrafit-cluster-map.json"
readonly MAX_PAGES=100                # pagination safety cap

# ─── runtime configuration ────────────────────────────────────────────────────

PS_BASE_URL="${PS_BASE_URL:-$DEFAULT_PS_BASE_URL}"
RATE_LIMIT_SLEEP="${RATE_LIMIT_SLEEP:-$DEFAULT_RATE_LIMIT_SLEEP}"
CLUSTER_MAP="${CLUSTER_MAP:-$DEFAULT_CLUSTER_MAP}"
BRANCH_BASE="${BRANCH_BASE:-$DEFAULT_BRANCH_BASE}"
AI_PROVIDER="${AI_PROVIDER:-}"
AI_BASE_URL="${AI_BASE_URL:-}"
AI_MODEL="${AI_MODEL:-}"

# ─── argument parsing ─────────────────────────────────────────────────────────

PR_MODE="$DEFAULT_PR_MODE"
TITLE_PREFIX="$DEFAULT_TITLE_PREFIX"
STUB_FILE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr-mode)      PR_MODE="$2";      shift 2 ;;
    --title-prefix) TITLE_PREFIX="$2"; shift 2 ;;
    --stub-file)    STUB_FILE="$2";    shift 2 ;;
    --dry-run)      DRY_RUN=true;      shift   ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ "$PR_MODE" == "per-cluster" || "$PR_MODE" == "single" ]] \
  || { echo "ERROR: --pr-mode must be 'per-cluster' or 'single', got: ${PR_MODE}" >&2; exit 1; }

if [[ -n "$STUB_FILE" && ! -f "$STUB_FILE" ]]; then
  echo "ERROR: --stub-file path does not exist: ${STUB_FILE}" >&2
  exit 1
fi

# ─── dependency check ─────────────────────────────────────────────────────────

for cmd in curl jq yq git gh; do
  command -v "$cmd" >/dev/null 2>&1 \
    || { echo "ERROR: required command not found: ${cmd}" >&2; exit 1; }
done

yq_version="$(yq --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
yq_major="${yq_version%%.*}"
[[ "$yq_major" -ge 4 ]] \
  || { echo "ERROR: yq v4+ (mikefarah/yq) is required, found: $(yq --version 2>&1)" >&2; exit 1; }

# ─── required environment variables ──────────────────────────────────────────

for var in PS_CLIENT_ID PS_CLIENT_SECRET GH_TOKEN AI_API_KEY; do
  [[ -n "${!var:-}" ]] \
    || { echo "ERROR: required environment variable is not set: ${var}" >&2; exit 1; }
done

# ─── AI provider resolution ───────────────────────────────────────────────────

if [[ -z "$AI_PROVIDER" ]]; then
  if [[ "$AI_API_KEY" == sk-ant-* ]]; then
    AI_PROVIDER="anthropic"
  else
    AI_PROVIDER="openai"
  fi
fi

case "$AI_PROVIDER" in
  anthropic)
    AI_BASE_URL="${AI_BASE_URL:-https://api.anthropic.com}"
    AI_MODEL="${AI_MODEL:-claude-sonnet-4-5}"
    ;;
  openai)
    AI_BASE_URL="${AI_BASE_URL:-https://api.openai.com}"
    AI_MODEL="${AI_MODEL:-gpt-4o}"
    ;;
  *)
    echo "ERROR: AI_PROVIDER must be 'anthropic' or 'openai', got: ${AI_PROVIDER}" >&2
    exit 1
    ;;
esac

# ─── helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[infrafit] $*"; }
warn() { echo "[infrafit] WARN: $*" >&2; }
die()  { echo "[infrafit] ERROR: $*" >&2; exit 1; }

# ps_get <path>
# Perform an authenticated GET against the PerfectScale public API.
ps_get() {
  local api_path="$1"
  curl -sSf \
    -H "Authorization: Bearer ${TOKEN}" \
    "${PS_BASE_URL}${api_path}"
}

# ai_edit_yaml <values_file> <pool_name> <changes_json>
# Ask the configured AI provider to apply <changes_json> (a JSON array of
# {path, operation, current_value, recommended_value} objects) to the
# NodePool named <pool_name> inside <values_file>.
# Prints the complete edited file content to stdout.
ai_edit_yaml() {
  local values_file="$1"
  local pool_name="$2"
  local changes_json="$3"
  local yaml_content
  yaml_content="$(cat "$values_file")"

  # The prompt is intentionally strict: the AI acts as a deterministic editing
  # tool, not a reasoning agent. It must return raw YAML only.
  local prompt
  prompt="$(cat <<PROMPT
You are a YAML editing tool. Output ONLY the complete edited YAML file — no
explanation, no markdown code fences, no commentary of any kind. Raw YAML only.

Task: apply the NodePool changes listed below to the YAML file provided.

NodePool name: ${pool_name}

Changes (JSON array — each entry has path, operation, current_value, recommended_value):
${changes_json}

Editing rules:
1. Each change path is a JSONPath relative to the NodePool spec (e.g.
   ".spec.disruption.consolidationPolicy").  In the values file, the same
   field lives under NodePools.<pool_name>.<path_after_.spec.> (e.g.
   NodePools.${pool_name}.disruption.consolidationPolicy).
2. "replace" and "add": set the target field to recommended_value, preserving
   the surrounding YAML structure, indentation, and inline comments exactly.
3. "remove": delete the field entirely.  For list elements matched by a key
   predicate (e.g. a requirements[] entry), remove only the matching element.
4. If the NodePool key is absent from the file, return the file unchanged.
5. Preserve everything else exactly as-is: other NodePools, comments, blank
   lines, indentation style, key ordering.
6. Output the complete file.  Do not truncate or summarise.

YAML file to edit:
${yaml_content}
PROMPT
)"

  case "$AI_PROVIDER" in
    anthropic) _ai_call_anthropic "$prompt" ;;
    openai)    _ai_call_openai    "$prompt" ;;
  esac
}

_ai_call_anthropic() {
  local prompt="$1"
  local payload
  payload="$(jq -n \
    --arg model   "$AI_MODEL" \
    --arg content "$prompt" \
    '{model: $model, max_tokens: 8192,
      messages: [{role: "user", content: $content}]}')"

  local response
  response="$(curl -sSf \
    -X POST "${AI_BASE_URL}/v1/messages" \
    -H "x-api-key: ${AI_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$payload")" \
    || die "Anthropic API call failed"

  jq -re '.content[0].text' <<<"$response" \
    || die "unexpected Anthropic response shape: ${response}"
}

_ai_call_openai() {
  local prompt="$1"
  local payload
  payload="$(jq -n \
    --arg model   "$AI_MODEL" \
    --arg content "$prompt" \
    '{model: $model, max_tokens: 8192,
      messages: [{role: "user", content: $content}]}')"

  local response
  response="$(curl -sSf \
    -X POST "${AI_BASE_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${AI_API_KEY}" \
    -H "content-type: application/json" \
    -d "$payload")" \
    || die "OpenAI API call failed"

  jq -re '.choices[0].message.content' <<<"$response" \
    || die "unexpected OpenAI response shape: ${response}"
}

# ─── infrafit-cluster-map ─────────────────────────────────────────────────────

[[ -f "$CLUSTER_MAP" ]] \
  || die "cluster-map not found at '${CLUSTER_MAP}'. Create this file in your repository and map your PerfectScale cluster UIDs to Helm values file paths. See https://github.com/perfectscale-io/infrafit-action#setup for instructions."

# Validate it is parseable JSON before doing anything else.
jq -e . "$CLUSTER_MAP" >/dev/null \
  || die "infrafit-cluster-map.json is not valid JSON: ${CLUSTER_MAP}"

# Keys starting with _ are documentation comments; everything else is a mapping.
mapfile -t MAPPED_UIDS < <(
  jq -r 'keys[] | select(startswith("_") | not)' "$CLUSTER_MAP"
)

[[ ${#MAPPED_UIDS[@]} -gt 0 ]] \
  || die "infrafit-cluster-map.json has no UID entries (only comment keys starting with '_'): ${CLUSTER_MAP}"

log "infrafit-cluster-map.json: ${#MAPPED_UIDS[@]} UID(s) — ${MAPPED_UIDS[*]}"

# ─── phase 0: authenticate ────────────────────────────────────────────────────

log "phase 0: authenticating to PerfectScale API"

auth_payload="$(jq -n \
  --arg id  "$PS_CLIENT_ID" \
  --arg sec "$PS_CLIENT_SECRET" \
  '{client_id: $id, client_secret: $sec}')"

auth_response="$(curl -sSf \
  -X POST "${PS_BASE_URL}/auth/public_auth" \
  -H "content-type: application/json" \
  -d "$auth_payload")" \
  || die "PerfectScale authentication request failed"

TOKEN="$(jq -re '.access_token // .token' <<<"$auth_response")" \
  || die "authentication failed — no token in response: ${auth_response}"

log "authenticated"

# ─── phase 0: list clusters ───────────────────────────────────────────────────

log "phase 0: listing clusters"

clusters_json="$(ps_get "/clusters")" \
  || die "failed to fetch cluster list from PerfectScale API"

cluster_count="$(jq '.data | length' <<<"$clusters_json")"
log "discovered ${cluster_count} cluster(s)"

# uid → display name (used in PR/issue bodies only; never for routing)
declare -A CLUSTER_NAME_BY_UID
while IFS=$'\t' read -r uid name; do
  CLUSTER_NAME_BY_UID["$uid"]="$name"
done < <(jq -r \
  '.data[] | select(.uid != null and .uid != "") | [.uid, .name] | @tsv' \
  <<<"$clusters_json")

# ─── state ────────────────────────────────────────────────────────────────────

declare -A EDITED_FILES      # uid → values file path
declare -A CLUSTER_SUMMARIES # uid → human-readable summary of applied changes
SKIP_LIST=()                 # entries: "uid\tcluster_name\treason"

TODAY="$(date -u +%Y%m%d)"

# ─── phases 1–3: fetch recommendations, map, edit ────────────────────────────

log "phase 1-3: processing clusters"

for uid in "${MAPPED_UIDS[@]}"; do

  cluster_name="${CLUSTER_NAME_BY_UID[$uid]:-$uid}"
  log "  cluster: ${cluster_name} (uid: ${uid})"

  # Phase 2: resolve uid → values file
  values_file="$(jq -re --arg u "$uid" '.[$u] // empty' "$CLUSTER_MAP")"

  if [[ -z "$values_file" ]]; then
    # Should not happen since MAPPED_UIDS came from the map itself, but guard.
    warn "  uid ${uid} maps to an empty file path — skipping"
    SKIP_LIST+=("${uid}	${cluster_name}	uid maps to empty path in infrafit-cluster-map.json")
    continue
  fi

  if [[ ! -f "$values_file" ]]; then
    warn "  values file not found: ${values_file}"
    SKIP_LIST+=("${uid}	${cluster_name}	values file not found: ${values_file}")
    continue
  fi

  # Phase 1: fetch recommendations (or load stub)
  if [[ -n "$STUB_FILE" ]]; then
    log "  [stub] loading recommendations from ${STUB_FILE}"
    recs_json="$(cat "$STUB_FILE")"
  else
    log "  fetching recommendations (sleeping ${RATE_LIMIT_SLEEP}s for rate limit)"
    sleep "$RATE_LIMIT_SLEEP"

    recs_json=""
    next_cursor=""
    page=0

    while true; do
      page=$(( page + 1 ))
      if [[ $page -gt $MAX_PAGES ]]; then
        warn "  pagination cap (${MAX_PAGES} pages) reached for uid ${uid}"
        break
      fi

      api_path="/clusters/${uid}/infra-fit?period=30d&page_size=200&has_recommended_changes=true"
      [[ -n "$next_cursor" ]] && api_path="${api_path}&cursor=${next_cursor}"

      page_json="$(ps_get "$api_path")" \
        || die "failed to fetch recommendations for cluster ${uid} (page ${page})"

      if [[ -z "$recs_json" ]]; then
        recs_json="$page_json"
      else
        recs_json="$(jq -s '.[0].data += .[1].data | .[0]' \
          <(echo "$recs_json") <(echo "$page_json"))"
      fi

      next_cursor="$(jq -re '.meta.pagination.next // empty' <<<"$page_json")"
      [[ -n "$next_cursor" ]] || break
      sleep "$RATE_LIMIT_SLEEP"
    done
  fi

  # Phase 1: filter to actionable Karpenter pools
  actionable_pools="$(jq -c '
    .data[]
    | select(
        .recommendations.type == "karpenter"
        and .recommendations.has_recommended_changes == true
      )
    | {
        pool:    .recommendations.recommended_config.metadata.name,
        changes: .recommendations.changes
      }
  ' <<<"$recs_json")"

  if [[ -z "$actionable_pools" ]]; then
    log "  no actionable Karpenter recommendations"
    continue
  fi

  pool_count="$(jq -s 'length' <<<"$actionable_pools")"
  log "  ${pool_count} actionable pool(s)"

  cluster_applied=""

  while IFS= read -r pool_entry; do
    pool_name="$(jq -re '.pool'    <<<"$pool_entry")"
    changes_json="$(jq -c '.changes' <<<"$pool_entry")"

    log "    pool: ${pool_name}"

    # Verify the pool exists in the values file before spending an AI call.
    if ! yq -e ".NodePools.${pool_name}" "$values_file" >/dev/null 2>&1; then
      warn "    pool '${pool_name}' not found under .NodePools in ${values_file}"
      SKIP_LIST+=("${uid}	${cluster_name}	pool '${pool_name}' not defined in ${values_file}")
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log "    [dry-run] would apply to ${values_file}: ${changes_json}"
      cluster_applied+="${pool_name} (dry-run)"$'\n'
      continue
    fi

    log "    calling AI (${AI_PROVIDER}/${AI_MODEL})"
    edited_yaml="$(ai_edit_yaml "$values_file" "$pool_name" "$changes_json")"

    if [[ -z "$edited_yaml" ]]; then
      warn "    AI returned empty output for pool '${pool_name}' — skipping"
      SKIP_LIST+=("${uid}	${cluster_name}	AI returned empty output for pool '${pool_name}'")
      continue
    fi

    printf '%s' "$edited_yaml" > "$values_file"
    log "    written: ${values_file}"

    change_summary="$(jq -r \
      '.[] | "      \(.path): \(.current_value) → \(.recommended_value)"' \
      <<<"$changes_json")"
    cluster_applied+="${pool_name}:"$'\n'"${change_summary}"$'\n'

  done <<<"$actionable_pools"

  if [[ -n "$cluster_applied" && "$DRY_RUN" == "false" ]]; then
    EDITED_FILES["$uid"]="$values_file"
    CLUSTER_SUMMARIES["$uid"]="$cluster_applied"
  fi

done

# ─── phase 4: open PR(s) ──────────────────────────────────────────────────────

log "phase 4: opening PR(s)"

# open_pr <branch> <title> <body> <file> [<file> …]
open_pr() {
  local branch="$1"
  local title="$2"
  local body="$3"
  shift 3
  local -a stage_files=("$@")

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] would open PR '${title}' on branch '${branch}'"
    return
  fi

  git checkout "$BRANCH_BASE"
  git pull --ff-only

  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    warn "branch '${branch}' already exists on origin — skipping PR"
    return
  fi

  git checkout -b "$branch"

  for f in "${stage_files[@]}"; do
    git add "$f"
  done

  if git diff --cached --quiet; then
    warn "no effective changes after AI edits for branch '${branch}' — skipping PR"
    git checkout "$BRANCH_BASE"
    git branch -D "$branch"
    return
  fi

  git --no-pager diff --cached
  git commit -m "${TITLE_PREFIX} apply InfraFit recommendations (${branch#infrafit*/})"
  git push -u origin HEAD

  gh pr create \
    --base  "$BRANCH_BASE" \
    --title "$title" \
    --body  "$body"

  git checkout "$BRANCH_BASE"
}

build_pr_body() {
  local applied_section="$1"
  local skipped_section="$2"
  local stub_notice="$3"

  printf '%s\nAutomated InfraFit NodePool recommendations from PerfectScale.\n\n## Applied\n\n%s\n\n## Skipped (manual review required)\n\n%s\n\n---\nMerge → ArgoCD syncs on the next reconcile. No live changes were made by CI.\n' \
    "$stub_notice" \
    "$applied_section" \
    "${skipped_section:-_None — all recommendations were applied._}"
}

uids_with_edits=()
for uid in "${!EDITED_FILES[@]}"; do
  uids_with_edits+=("$uid")
done

stub_notice=""
[[ -n "$STUB_FILE" ]] \
  && stub_notice="> ⚠️ TEST RUN — recommendations were loaded from a local stub file, not the live API."

if [[ ${#uids_with_edits[@]} -eq 0 ]]; then
  log "no edits produced — no PRs to open"
else
  case "$PR_MODE" in

    per-cluster)
      for uid in "${uids_with_edits[@]}"; do
        cluster_name="${CLUSTER_NAME_BY_UID[$uid]:-$uid}"
        safe_name="${cluster_name//[^a-zA-Z0-9-]/-}"
        branch_prefix="infrafit"; [[ -n "$STUB_FILE" ]] && branch_prefix="infrafit-test"
        title_tag="";             [[ -n "$STUB_FILE" ]] && title_tag=" [TEST]"

        branch="${branch_prefix}/${safe_name}-${TODAY}"
        title="${TITLE_PREFIX}${title_tag} InfraFit NodePool tuning (${cluster_name})"
        applied="**${cluster_name}** (${EDITED_FILES[$uid]})"$'\n'"${CLUSTER_SUMMARIES[$uid]}"

        cluster_skips=""
        for entry in "${SKIP_LIST[@]}"; do
          [[ "${entry%%	*}" == "$uid" ]] && cluster_skips+="${entry##*	}"$'\n'
        done

        body="$(build_pr_body "$applied" "$cluster_skips" "$stub_notice")"
        open_pr "$branch" "$title" "$body" "${EDITED_FILES[$uid]}"
      done
      ;;

    single)
      branch_prefix="infrafit"; [[ -n "$STUB_FILE" ]] && branch_prefix="infrafit-test"
      title_tag="";             [[ -n "$STUB_FILE" ]] && title_tag=" [TEST]"

      branch="${branch_prefix}/all-${TODAY}"
      title="${TITLE_PREFIX}${title_tag} InfraFit NodePool tuning (${#uids_with_edits[@]} cluster(s))"

      all_applied=""
      all_files=()
      for uid in "${uids_with_edits[@]}"; do
        cluster_name="${CLUSTER_NAME_BY_UID[$uid]:-$uid}"
        all_applied+="**${cluster_name}** (${EDITED_FILES[$uid]})"$'\n'"${CLUSTER_SUMMARIES[$uid]}"$'\n'
        all_files+=("${EDITED_FILES[$uid]}")
      done

      all_skips=""
      for entry in "${SKIP_LIST[@]}"; do
        all_skips+="${entry##*	}"$'\n'
      done

      body="$(build_pr_body "$all_applied" "$all_skips" "$stub_notice")"
      open_pr "$branch" "$title" "$body" "${all_files[@]}"
      ;;
  esac
fi

# ─── phase 5: tracking issue ──────────────────────────────────────────────────

log "phase 5: tracking issue"

if [[ ${#SKIP_LIST[@]} -gt 0 ]]; then
  skip_items=""
  for entry in "${SKIP_LIST[@]}"; do
    uid_part="${entry%%	*}"
    rest="${entry#*	}"
    name_part="${rest%%	*}"
    reason="${rest#*	}"
    skip_items+="- **${name_part}** (\`${uid_part}\`): ${reason}"$'\n'
  done

  issue_title_tag=""; [[ -n "$STUB_FILE" ]] && issue_title_tag=" [TEST]"
  issue_title="InfraFit${issue_title_tag}: ${#SKIP_LIST[@]} item(s) need manual review"

  issue_body="$(cat <<ISSUE
${stub_notice}
These InfraFit recommendations could not be applied automatically.

## Items requiring manual action

${skip_items}
## How to resolve

- **uid not in infrafit-cluster-map.json** — add the cluster UID to \`.github/infrafit-cluster-map.json\` mapped to the correct Helm values file.
- **values file not found** — verify the path in \`.github/infrafit-cluster-map.json\` matches the actual file location in this repository.
- **pool not defined in values file** — the PerfectScale API returned a recommendation for a NodePool that does not appear under \`NodePools:\` in the mapped values file. Add the pool or update the mapping.
- **AI returned empty output** — re-run the workflow. If the issue persists, apply the change manually and close this issue.
ISSUE
)"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] would open tracking issue: ${issue_title}"
  else
    gh issue create --title "$issue_title" --body "$issue_body"
  fi
else
  log "no skipped items — tracking issue not needed"
fi

# ─── summary ──────────────────────────────────────────────────────────────────

echo ""
log "────────────────── run summary ──────────────────────────────"
log "clusters discovered : ${cluster_count}"
log "clusters with edits : ${#uids_with_edits[@]}"
log "items skipped       : ${#SKIP_LIST[@]}"
[[ "$DRY_RUN" == "true" ]] && log "mode                : DRY RUN — no changes made"
log "─────────────────────────────────────────────────────────────"
