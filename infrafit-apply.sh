#!/usr/bin/env bash
# infrafit-apply.sh — PerfectScale InfraFit NodePool reconciliation
#
# Fetches Karpenter NodePool recommendations from the PerfectScale API,
# translates them into edits on the caller's Karpenter configuration files,
# and opens a GitHub pull request for review.  Nothing is applied to a live cluster.
#
# AI is used for exactly one focused step: given the current YAML file and the
# structured list of changes from the API, produce the edited YAML.  Every
# other step — API calls, file routing, git operations, PR/issue creation — is
# plain shell.  Supported providers: Anthropic, OpenAI (or any
# OpenAI-compatible chat-completions endpoint, e.g. Azure OpenAI), Claude in
# Amazon Bedrock, and GitHub Copilot (via the Copilot CLI).
#
# This script is invoked by action.yml and is not intended to be called
# directly in most cases.  All configuration is passed via environment
# variables (set by action.yml from action inputs) and CLI flags.
#
# Flags:
#   --pr-mode      per-cluster|single   (default: per-cluster)
#   --title-prefix STRING               (default: "feat(INFRAFIT-0):")
#
# Required environment variables:
#   PS_CLIENT_ID        PerfectScale API client id
#   PS_CLIENT_SECRET    PerfectScale API client secret
#   GH_TOKEN            GitHub token (contents:write, pull-requests:write, issues:write)
#   AI_API_KEY          API key for the AI provider (required for anthropic/openai;
#                       for bedrock, either AWS credentials or a Bedrock bearer
#                       token passed here — see below)
#
# Optional environment variables:
#   PS_BASE_URL         PerfectScale API base URL
#                       (default: https://api.app.perfectscale.io/public/v1)
#   AI_PROVIDER         anthropic|openai|bedrock|copilot  (anthropic/openai are
#                       auto-detected from the key prefix; bedrock and copilot
#                       must be set explicitly)
#   AI_BASE_URL         Override AI endpoint (e.g. Azure OpenAI deployment URL)
#   AI_MODEL            Override AI model
#   AWS_REGION          AWS region for bedrock (also read from the standard AWS
#                       environment, e.g. set by aws-actions/configure-aws-credentials)
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
#                       AWS credentials for bedrock SigV4 signing
#   GITHUB_TOKEN        Workflow token for copilot (set by action.yml from
#                       github.token; the workflow must grant the
#                       `copilot-requests: write` permission)
#   CLUSTER_MAP         Path to the cluster-map JSON file
#                       (default: .github/infrafit-cluster-map.json)
#   BRANCH_BASE         Base branch for PRs  (default: main)
#   RATE_LIMIT_SLEEP    Seconds between PerfectScale API calls  (default: 6)
#
# Runtime dependencies: bash ≥4, curl, jq, yq (mikefarah/yq v4+), git, gh

set -euo pipefail

# ─── constants ────────────────────────────────────────────────────────────────

readonly DEFAULT_PS_BASE_URL="https://api.app.perfectscale.io/public/v1"
readonly DEFAULT_RATE_LIMIT_SLEEP=6   # PS API allows 10 req/min per client → 60/10 = 6s min spacing
readonly DEFAULT_PR_MODE="per-cluster"
readonly DEFAULT_TITLE_PREFIX="feat(INFRAFIT-0):"
readonly DEFAULT_BRANCH_BASE="main"
readonly DEFAULT_CLUSTER_MAP=".github/infrafit-cluster-map.json"
readonly MAX_PAGES=100                # pagination safety cap

# ─── runtime configuration ────────────────────────────────────────────────────

# Required — must be set in the environment; validated explicitly below.
PS_CLIENT_ID="${PS_CLIENT_ID:-}"
PS_CLIENT_SECRET="${PS_CLIENT_SECRET:-}"
GH_TOKEN="${GH_TOKEN:-}"
AI_API_KEY="${AI_API_KEY:-}"

# Optional — fall back to defaults when not set.
PS_BASE_URL="${PS_BASE_URL:-$DEFAULT_PS_BASE_URL}"
RATE_LIMIT_SLEEP="${RATE_LIMIT_SLEEP:-$DEFAULT_RATE_LIMIT_SLEEP}"
CLUSTER_MAP="${CLUSTER_MAP:-$DEFAULT_CLUSTER_MAP}"
BRANCH_BASE="${BRANCH_BASE:-$DEFAULT_BRANCH_BASE}"
AI_PROVIDER="${AI_PROVIDER:-}"
AI_BASE_URL="${AI_BASE_URL:-}"
AI_MODEL="${AI_MODEL:-}"
# The aws_region action input takes precedence over the ambient AWS_REGION
# (typically exported by aws-actions/configure-aws-credentials).
AWS_REGION="${INPUT_AWS_REGION:-${AWS_REGION:-}}"

# ─── argument parsing ─────────────────────────────────────────────────────────

PR_MODE="$DEFAULT_PR_MODE"
TITLE_PREFIX="$DEFAULT_TITLE_PREFIX"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr-mode)      PR_MODE="$2";      shift 2 ;;
    --title-prefix) TITLE_PREFIX="$2"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ "$PR_MODE" == "per-cluster" || "$PR_MODE" == "single" ]] \
  || { echo "ERROR: --pr-mode must be 'per-cluster' or 'single', got: ${PR_MODE}" >&2; exit 1; }

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

for var in PS_CLIENT_ID PS_CLIENT_SECRET GH_TOKEN; do
  [[ -n "${!var:-}" ]] \
    || { echo "ERROR: required environment variable is not set: ${var}" >&2; exit 1; }
done

# ─── AI provider resolution ───────────────────────────────────────────────────

if [[ -z "$AI_PROVIDER" ]]; then
  if [[ "$AI_API_KEY" == sk-ant-* ]]; then
    AI_PROVIDER="anthropic"
  elif [[ -n "$AI_API_KEY" ]]; then
    AI_PROVIDER="openai"
  else
    echo "ERROR: cannot auto-detect the AI provider without ai_api_key — set ai_api_key (anthropic/openai) or set ai_provider explicitly ('bedrock' and 'copilot' always require it)" >&2
    exit 1
  fi
fi

case "$AI_PROVIDER" in
  anthropic)
    [[ -n "$AI_API_KEY" ]] \
      || { echo "ERROR: ai_api_key is required when ai_provider is 'anthropic'" >&2; exit 1; }
    AI_BASE_URL="${AI_BASE_URL:-https://api.anthropic.com}"
    AI_MODEL="${AI_MODEL:-claude-sonnet-5}"
    ;;
  openai)
    [[ -n "$AI_API_KEY" ]] \
      || { echo "ERROR: ai_api_key is required when ai_provider is 'openai'" >&2; exit 1; }
    AI_BASE_URL="${AI_BASE_URL:-https://api.openai.com}"
    AI_MODEL="${AI_MODEL:-gpt-5.6}"
    ;;
  bedrock)
    # Auth is either AWS SigV4 (credentials in the standard AWS env vars, e.g.
    # set by aws-actions/configure-aws-credentials) or a Bedrock bearer token
    # passed as ai_api_key. SigV4 wins when both are present.
    [[ -n "$AWS_REGION" ]] \
      || { echo "ERROR: an AWS region is required when ai_provider is 'bedrock' — set the aws_region input or export AWS_REGION (aws-actions/configure-aws-credentials does this)" >&2; exit 1; }
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
      [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] \
        || { echo "ERROR: AWS_ACCESS_KEY_ID is set but AWS_SECRET_ACCESS_KEY is not" >&2; exit 1; }
    elif [[ -z "$AI_API_KEY" ]]; then
      echo "ERROR: 'bedrock' needs AWS credentials in the environment (e.g. via aws-actions/configure-aws-credentials) or a Bedrock bearer token passed as ai_api_key" >&2
      exit 1
    fi
    AI_BASE_URL="${AI_BASE_URL:-https://bedrock-mantle.${AWS_REGION}.api.aws/anthropic}"
    AI_MODEL="${AI_MODEL:-anthropic.claude-sonnet-5}"
    ;;
  copilot)
    # Copilot CLI authenticates with the workflow's GITHUB_TOKEN (passed
    # through by action.yml); the workflow must grant `copilot-requests: write`
    # and the org must allow Copilot CLI billed to the organization.
    [[ -n "${GITHUB_TOKEN:-}" ]] \
      || { echo "ERROR: GITHUB_TOKEN is required when ai_provider is 'copilot' — grant the workflow the 'copilot-requests: write' permission" >&2; exit 1; }
    command -v copilot >/dev/null 2>&1 \
      || { echo "ERROR: required command not found: copilot (the action installs it automatically when ai_provider is 'copilot')" >&2; exit 1; }
    [[ -z "$AI_MODEL" ]] \
      || echo "WARN: ai_model is ignored for 'copilot' — the Copilot CLI selects its own model" >&2
    ;;
  *)
    echo "ERROR: AI_PROVIDER must be 'anthropic', 'openai', 'bedrock' or 'copilot', got: ${AI_PROVIDER}" >&2
    exit 1
    ;;
esac

# ─── helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[infrafit] $*"; }
warn() { echo "[infrafit] WARN: $*" >&2; }
die()  { echo "[infrafit] ERROR: $*" >&2; exit 1; }

# ps_get <path>
# Perform an authenticated GET against the PerfectScale public API.
# The PS API allows 10 requests/minute per client. Callers space requests by
# RATE_LIMIT_SLEEP to stay under that, but if a 429 still comes back (shared
# token, clock drift), honour Retry-After and retry a bounded number of times.
ps_get() {
  local api_path="$1"
  local attempt=0 http_code body retry_after hdr_file
  hdr_file="$(mktemp)"
  while true; do
    attempt=$(( attempt + 1 ))
    # Capture body and trailing HTTP status without -f, so we can inspect 429.
    body="$(curl -sS --connect-timeout 10 --max-time 60 \
      -D "$hdr_file" \
      -w $'\n%{http_code}' \
      -H "Authorization: Bearer ${TOKEN}" \
      "${PS_BASE_URL}${api_path}")" || { rm -f "$hdr_file"; return 1; }
    http_code="${body##*$'\n'}"
    body="${body%$'\n'*}"

    if [[ "$http_code" == "429" && $attempt -le 5 ]]; then
      retry_after="$(awk 'tolower($1) == "retry-after:" {print $2}' "$hdr_file" | tr -d '\r' | tail -1)"
      [[ "$retry_after" =~ ^[0-9]+$ ]] || retry_after="$RATE_LIMIT_SLEEP"
      warn "  rate limited (429) on ${api_path} — waiting ${retry_after}s (attempt ${attempt}/5)"
      sleep "$retry_after"
      continue
    fi

    rm -f "$hdr_file"
    [[ "$http_code" =~ ^2 ]] || return 1
    printf '%s' "$body"
    return 0
  done
}

# ai_edit_yaml <values_file> <pool_name> <changes_json>
# Ask the configured AI provider to apply <changes_json> (a JSON array of
# {path, operation, currentValue, recommendedValue} objects) to the
# NodePool named <pool_name> inside <values_file>.
# Prints the complete edited and validated file content to stdout.
# Fails (non-zero) when the AI call fails or the output does not survive
# validation: non-empty, parseable YAML, every previously-present NodePool
# still present.
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

Changes (JSON array — each entry has path, operation, currentValue, recommendedValue):
${changes_json}

Editing rules:
1. Each change path is a JSONPath relative to the NodePool spec (e.g.
   ".spec.disruption.consolidationPolicy").  In the values file, the same
   field lives under NodePools.<pool_name>.<path_after_.spec.> (e.g.
   NodePools.${pool_name}.disruption.consolidationPolicy).
2. "replace" and "add": set the target field to recommendedValue, preserving
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

  local edited fence='```'
  edited="$(_ai_call "$prompt")" || return 1

  # Strip a markdown code fence if the model added one despite the prompt.
  if [[ "$edited" == "$fence"* ]]; then
    edited="${edited#*$'\n'}"
    edited="${edited%$'\n'"$fence"}"
  fi

  if [[ -z "$edited" ]]; then
    warn "AI returned empty output for pool '${pool_name}'"
    return 1
  fi

  local tmp_out
  tmp_out="$(mktemp)"
  printf '%s\n' "$edited" > "$tmp_out"

  if ! yq -e '.' "$tmp_out" >/dev/null 2>&1; then
    warn "AI output for pool '${pool_name}' is not valid YAML"
    rm -f "$tmp_out"
    return 1
  fi

  # Every NodePool present before the edit must still be present after it.
  local missing
  missing="$(comm -23 \
    <(yq '.NodePools | keys | .[]' "$values_file" 2>/dev/null | sort) \
    <(yq '.NodePools | keys | .[]' "$tmp_out"     2>/dev/null | sort))"
  if [[ -n "$missing" ]]; then
    warn "AI output for pool '${pool_name}' dropped NodePool(s): ${missing//$'\n'/, }"
    rm -f "$tmp_out"
    return 1
  fi

  rm -f "$tmp_out"
  printf '%s\n' "$edited"
}

# _ai_call <prompt>
# POST <prompt> to the configured provider and print the model's text reply.
# Fails (non-zero) on transport errors, unexpected response shapes, and
# responses truncated at the max_tokens cap.
_ai_call() {
  local prompt="$1"

  # Copilot is CLI-based (no HTTP endpoint) — handled before the curl path.
  # --yolo runs non-interactively per GitHub's Actions guidance; since the
  # CLI is agentic, the subshell drops every secret except the GITHUB_TOKEN
  # it authenticates with, so tool use can never read them.
  if [[ "$AI_PROVIDER" == "copilot" ]]; then
    local response
    response="$( (
      unset GH_TOKEN PS_CLIENT_ID PS_CLIENT_SECRET AI_API_KEY \
            AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
      copilot --yolo -p "$prompt"
    ) )" || { warn "copilot CLI call failed"; return 1; }
    printf '%s' "$response"
    return 0
  fi

  local url extract stop_filter token_param
  local -a auth_args

  case "$AI_PROVIDER" in
    anthropic)
      url="${AI_BASE_URL}/v1/messages"
      auth_args=(-H "x-api-key: ${AI_API_KEY}" -H "anthropic-version: 2023-06-01")
      # Claude models with adaptive thinking may lead with a thinking block —
      # select the first text block rather than assuming content[0].
      extract='[.content[] | select(.type == "text")][0].text'
      stop_filter='.stop_reason'
      token_param='max_tokens'
      ;;
    openai)
      url="${AI_BASE_URL}/v1/chat/completions"
      auth_args=(-H "Authorization: Bearer ${AI_API_KEY}")
      extract='.choices[0].message.content'
      stop_filter='.choices[0].finish_reason'
      # GPT-5-family reasoning models reject the legacy max_tokens parameter.
      token_param='max_completion_tokens'
      ;;
    bedrock)
      # Claude in Amazon Bedrock serves the same Messages API shape as the
      # first-party Anthropic endpoint; only the host and auth differ.
      url="${AI_BASE_URL}/v1/messages"
      auth_args=(-H "anthropic-version: 2023-06-01")
      if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
        auth_args+=(--aws-sigv4 "aws:amz:${AWS_REGION}:bedrock-mantle" \
                    --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}")
        if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
          auth_args+=(-H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
        fi
      else
        auth_args+=(-H "x-api-key: ${AI_API_KEY}")
      fi
      extract='[.content[] | select(.type == "text")][0].text'
      stop_filter='.stop_reason'
      token_param='max_tokens'
      ;;
  esac

  # 16000 leaves room for reasoning/thinking tokens, which count against the
  # same budget as the emitted YAML on current reasoning models.
  local payload
  payload="$(jq -n \
    --arg model   "$AI_MODEL" \
    --arg content "$prompt" \
    --arg tp      "$token_param" \
    '{model: $model, messages: [{role: "user", content: $content}]}
     + {($tp): 16000}')"

  local response
  response="$(curl -sSf --connect-timeout 10 --max-time 300 \
    -X POST "$url" \
    "${auth_args[@]}" \
    -H "content-type: application/json" \
    -d "$payload")" \
    || { warn "${AI_PROVIDER} API call failed"; return 1; }

  local stop_reason
  stop_reason="$(jq -r "$stop_filter" <<<"$response")"
  if [[ "$stop_reason" == "max_tokens" || "$stop_reason" == "length" ]]; then
    warn "${AI_PROVIDER} response was truncated at the max_tokens cap — the file is too large to edit in one call"
    return 1
  fi

  jq -re "$extract" <<<"$response" \
    || { warn "unexpected ${AI_PROVIDER} response shape: ${response}"; return 1; }
}

# ─── infrafit-cluster-map ─────────────────────────────────────────────────────

[[ -f "$CLUSTER_MAP" ]] \
  || die "cluster-map not found at '${CLUSTER_MAP}'. Create this file in your repository and map your PerfectScale cluster UIDs to Karpenter configuration file paths. See https://github.com/perfectscale-io/infrafit-action#setup for instructions."

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

auth_response="$(curl -sSf --connect-timeout 10 --max-time 60 \
  -X POST "${PS_BASE_URL}/auth/public_auth" \
  -H "content-type: application/json" \
  -d "$auth_payload")" \
  || die "PerfectScale authentication request failed"

TOKEN="$(jq -re '.data.access_token // .access_token // .token' <<<"$auth_response")" \
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

declare -A EDITED_FILES      # uid → values file path (repo path, untouched until phase 4)
declare -A EDITED_TMP        # uid → temp file holding that cluster's edited content
declare -A FILE_CLAIMED_BY   # values file path → last uid that produced edits for it
declare -A CLUSTER_SUMMARIES # uid → human-readable summary of applied changes
SKIP_LIST=()                 # entries: "uid\tcluster_name\treason"

TODAY="$(date -u +%Y%m%d)"

# Clusters visible to the API but missing from the cluster map are surfaced in
# the tracking issue rather than silently ignored.
declare -A IS_MAPPED
for uid in "${MAPPED_UIDS[@]}"; do IS_MAPPED["$uid"]=1; done
for uid in "${!CLUSTER_NAME_BY_UID[@]}"; do
  if [[ -z "${IS_MAPPED[$uid]:-}" ]]; then
    warn "cluster '${CLUSTER_NAME_BY_UID[$uid]}' (uid: ${uid}) is not in ${CLUSTER_MAP} — skipping"
    SKIP_LIST+=("${uid}	${CLUSTER_NAME_BY_UID[$uid]}	uid not in infrafit-cluster-map.json")
  fi
done

# ─── phases 1–3: fetch recommendations, map, edit ────────────────────────────

log "phase 1-3: processing clusters"

for uid in "${MAPPED_UIDS[@]}"; do

  cluster_name="${CLUSTER_NAME_BY_UID[$uid]:-$uid}"
  log "  cluster: ${cluster_name} (uid: ${uid})"

  # Phase 2: resolve uid → values file
  values_file="$(jq -r --arg u "$uid" '.[$u] // empty' "$CLUSTER_MAP")"

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

  # In per-cluster mode each PR must contain exactly one cluster's edits, so a
  # values file already claimed by an earlier cluster cannot be edited again.
  if [[ "$PR_MODE" == "per-cluster" && -n "${FILE_CLAIMED_BY[$values_file]:-}" ]]; then
    warn "  ${values_file} already has edits for cluster ${FILE_CLAIMED_BY[$values_file]} — per-cluster PRs cannot share a values file"
    SKIP_LIST+=("${uid}	${cluster_name}	values file ${values_file} is shared with cluster ${FILE_CLAIMED_BY[$values_file]} — use pr_mode: single or split the mapping")
    continue
  fi

  # Phase 1: fetch recommendations
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

    api_path="/clusters/${uid}/node-groups?period=30d&pageSize=200&hasRecommendations=true"
    if [[ -n "$next_cursor" ]]; then
      # The page token is an opaque server token — URL-encode it.
      api_path="${api_path}&pageToken=$(jq -rn --arg c "$next_cursor" '$c|@uri')"
    fi

    page_json="$(ps_get "$api_path")" \
      || die "failed to fetch recommendations for cluster ${uid} (page ${page})"

    if [[ -z "$recs_json" ]]; then
      recs_json="$page_json"
    else
      recs_json="$(jq -s '.[0].data += .[1].data | .[0]' \
        <(echo "$recs_json") <(echo "$page_json"))"
    fi

    next_cursor="$(jq -r '.meta.pagination.next // empty' <<<"$page_json")"
    [[ -n "$next_cursor" ]] || break
    sleep "$RATE_LIMIT_SLEEP"
  done

  # Phase 1: filter to actionable Karpenter pools
  actionable_pools="$(jq -c '
    .data[]
    | select(
        .recommendations.type == "karpenter"
        and .recommendations.hasChanges == true
      )
    | {
        pool:    .recommendations.recommendedConfig.metadata.name,
        changes: .recommendations.changes
      }
  ' <<<"$recs_json")"

  if [[ -z "$actionable_pools" ]]; then
    log "  no actionable Karpenter recommendations"
    continue
  fi

  pool_count="$(jq -s 'length' <<<"$actionable_pools")"
  log "  ${pool_count} actionable pool(s)"

  # Edits are applied to a temp copy; the repository working tree is only
  # touched in phase 4, on the PR branch itself. In single mode a values file
  # shared by several clusters accumulates their edits in sequence.
  work_file="$(mktemp)"
  if [[ -n "${FILE_CLAIMED_BY[$values_file]:-}" ]]; then
    cp "${EDITED_TMP[${FILE_CLAIMED_BY[$values_file]}]}" "$work_file"
  else
    cp "$values_file" "$work_file"
  fi

  cluster_applied=""

  while IFS= read -r pool_entry; do
    pool_name="$(jq -re '.pool'    <<<"$pool_entry")"
    changes_json="$(jq -c '.changes' <<<"$pool_entry")"

    log "    pool: ${pool_name}"

    # Verify the pool exists in the values file before spending an AI call.
    # strenv keeps the API-supplied name inert, whatever characters it holds.
    if ! POOL="$pool_name" yq -e '.NodePools[strenv(POOL)]' "$work_file" >/dev/null 2>&1; then
      warn "    pool '${pool_name}' not found under .NodePools in ${values_file}"
      SKIP_LIST+=("${uid}	${cluster_name}	pool '${pool_name}' not defined in ${values_file}")
      continue
    fi

    log "    calling AI (${AI_PROVIDER}/${AI_MODEL})"
    if ! edited_yaml="$(ai_edit_yaml "$work_file" "$pool_name" "$changes_json")"; then
      warn "    AI edit failed or failed validation for pool '${pool_name}' — skipping"
      SKIP_LIST+=("${uid}	${cluster_name}	AI edit failed or failed validation for pool '${pool_name}'")
      continue
    fi

    printf '%s\n' "$edited_yaml" > "$work_file"
    log "    staged edit for: ${values_file}"

    change_summary="$(jq -r \
      '.[] | "      \(.path): \(.currentValue) → \(.recommendedValue)"' \
      <<<"$changes_json")"
    cluster_applied+="${pool_name}:"$'\n'"${change_summary}"$'\n'

  done <<<"$actionable_pools"

  if [[ -n "$cluster_applied" ]]; then
    EDITED_FILES["$uid"]="$values_file"
    EDITED_TMP["$uid"]="$work_file"
    FILE_CLAIMED_BY["$values_file"]="$uid"
    CLUSTER_SUMMARIES["$uid"]="$cluster_applied"
  else
    rm -f "$work_file"
  fi

done

# ─── phase 4: open PR(s) ──────────────────────────────────────────────────────

log "phase 4: opening PR(s)"

# open_pr <branch> <title> <body> <file> [<file> …]
# Creates (or updates, on re-runs) <branch> off $BRANCH_BASE, applies the
# staged content for each <file> from its cluster's temp copy, commits,
# pushes, and opens a PR unless one is already open for the branch.
# The working tree is clean on entry and left clean on $BRANCH_BASE.
open_pr() {
  local branch="$1"
  local title="$2"
  local body="$3"
  shift 3
  local -a stage_files=("$@")

  git checkout "$BRANCH_BASE"
  git pull --ff-only

  local branch_exists=""
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    log "branch '${branch}' already exists on origin — it will be updated"
    branch_exists=1
    git fetch origin "$branch"
  fi

  git checkout -B "$branch"

  local f
  for f in "${stage_files[@]}"; do
    cp "${EDITED_TMP[${FILE_CLAIMED_BY[$f]}]}" "$f"
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

  if [[ -n "$branch_exists" ]]; then
    git push --force-with-lease -u origin "$branch"
  else
    git push -u origin "$branch"
  fi

  if [[ -n "$branch_exists" ]] \
     && [[ -n "$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty')" ]]; then
    log "PR for branch '${branch}' is already open — branch updated"
  else
    gh pr create \
      --base  "$BRANCH_BASE" \
      --title "$title" \
      --body  "$body"
  fi

  git checkout "$BRANCH_BASE"
}

build_pr_body() {
  local applied_section="$1"
  local skipped_section="$2"

  printf 'Automated InfraFit NodePool recommendations from PerfectScale.\n\n## Applied\n\n%s\n\n## Skipped (manual review required)\n\n%s\n\n---\nMerge → your cluster will pick up the changes on the next sync. No live changes were made by CI.\n' \
    "$applied_section" \
    "${skipped_section:-_None — all recommendations were applied._}"
}

uids_with_edits=()
for uid in "${!EDITED_FILES[@]}"; do
  uids_with_edits+=("$uid")
done

if [[ ${#uids_with_edits[@]} -eq 0 ]]; then
  log "no edits produced — no PRs to open"
else
  case "$PR_MODE" in

    per-cluster)
      for uid in "${uids_with_edits[@]}"; do
        cluster_name="${CLUSTER_NAME_BY_UID[$uid]:-$uid}"
        safe_name="${cluster_name//[^a-zA-Z0-9-]/-}"

        branch="infrafit/${safe_name}-${TODAY}"
        title="${TITLE_PREFIX} InfraFit NodePool tuning (${cluster_name})"
        applied="**${cluster_name}** (${EDITED_FILES[$uid]})"$'\n'"${CLUSTER_SUMMARIES[$uid]}"

        cluster_skips=""
        for entry in "${SKIP_LIST[@]}"; do
          [[ "${entry%%	*}" == "$uid" ]] && cluster_skips+="${entry##*	}"$'\n'
        done

        body="$(build_pr_body "$applied" "$cluster_skips")"
        open_pr "$branch" "$title" "$body" "${EDITED_FILES[$uid]}"
      done
      ;;

    single)
      branch="infrafit/all-${TODAY}"
      title="${TITLE_PREFIX} InfraFit NodePool tuning (${#uids_with_edits[@]} cluster(s))"

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

      body="$(build_pr_body "$all_applied" "$all_skips")"
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

  issue_title="InfraFit: ${#SKIP_LIST[@]} item(s) need manual review"

  issue_body="$(cat <<ISSUE
These InfraFit recommendations could not be applied automatically.

## Items requiring manual action

${skip_items}
## How to resolve

- **uid not in infrafit-cluster-map.json** — add the cluster UID to \`.github/infrafit-cluster-map.json\` mapped to the correct Karpenter configuration file, or ignore if the cluster is intentionally unmanaged.
- **values file not found** — verify the path in \`.github/infrafit-cluster-map.json\` matches the actual file location in this repository.
- **values file shared with another cluster** — in per-cluster PR mode every cluster needs its own values file. Switch to \`pr_mode: single\` or split the mapping.
- **pool not defined in values file** — the PerfectScale API returned a recommendation for a NodePool that does not appear under \`NodePools:\` in the mapped values file. Add the pool or update the mapping.
- **AI edit failed or failed validation** — the AI call errored, returned truncated/invalid YAML, or dropped existing NodePools, so the edit was discarded. Re-run the workflow; if it persists, apply the change manually and close this issue.
ISSUE
)"

  # Update the existing open tracking issue instead of filing a duplicate.
  # Issue reporting is best-effort: the PRs are already open at this point, so
  # a token without issues:write must not fail the run — the skip list is
  # always printed to the log above.
  existing_issue="$(gh issue list --state open --search 'InfraFit in:title' \
    --json number --jq '.[0].number // empty' 2>/dev/null)" || existing_issue=""
  if [[ -n "$existing_issue" ]]; then
    log "updating existing tracking issue #${existing_issue}"
    gh issue edit "$existing_issue" --title "$issue_title" --body "$issue_body" \
      || warn "could not update tracking issue #${existing_issue} — does the GitHub token have issues:write?"
  elif ! gh issue create --title "$issue_title" --body "$issue_body"; then
    warn "could not create tracking issue — does the GitHub token have issues:write? For GitHub App tokens, grant the App 'Issues: Read and write' (the workflow-level permissions block does not apply to App tokens)."
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
log "─────────────────────────────────────────────────────────────"
