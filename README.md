# infrafit-action

A GitHub Action that fetches [PerfectScale](https://perfectscale.io) InfraFit
Karpenter NodePool recommendations and applies them to your Helm values files
as a pull request.  Nothing is applied to a live cluster — the PR review is
the gate.

## How it works

1. Authenticates to the PerfectScale public API using your service token.
2. Lists all clusters and fetches Karpenter NodePool recommendations for each
   cluster that appears in your `cluster-map.json`.
3. For each actionable NodePool, calls your AI provider with the current YAML
   file and the structured list of changes — the AI returns the edited YAML.
4. Opens a pull request (or one per cluster, depending on `pr_mode`) with the
   diff.  Recommendations that cannot be applied automatically are collected
   into a GitHub issue for manual review.

AI is used only for the YAML editing step.  All API calls, file routing, git
operations, and PR/issue creation are handled by the action itself.

## Supported AI providers

| Provider | Key prefix | Default model |
|---|---|---|
| Anthropic | `sk-ant-*` (auto-detected) | `claude-sonnet-4-5` |
| OpenAI | everything else (auto-detected) | `gpt-4o` |
| Azure OpenAI | set `ai_provider: openai` + `ai_base_url` | your deployment |
| Any OpenAI-compatible endpoint | set `ai_provider: openai` + `ai_base_url` | your model |

## Setup

### 1. Add the cluster map

Copy [`cluster-map.example.json`](cluster-map.example.json) to
`.github/infrafit/cluster-map.json` in your repository and fill in your
cluster UIDs and the repo-relative paths to your Helm values files.

```json
{
  "_readme": "Maps PerfectScale cluster UIDs to Helm values files.",
  "abc123-your-cluster-uid": "karpenter-profiles/values/prod.yaml",
  "xyz789-another-cluster":  "karpenter-profiles/values/staging.yaml"
}
```

**Finding your cluster UID:**

```bash
TOKEN=$(curl -s -X POST https://api.app.perfectscale.io/public/v1/auth/public_auth \
  -H 'content-type: application/json' \
  -d '{"client_id":"<id>","client_secret":"<secret>"}' | jq -r .access_token)

curl -s -H "Authorization: Bearer $TOKEN" \
  https://api.app.perfectscale.io/public/v1/clusters \
  | jq -r '.data[] | "\(.uid)  \(.name)"'
```

**Values file requirements:**

The values file must have a top-level `NodePools` key with one entry per pool:

```yaml
NodePools:
  my-nodepool:
    disruption:
      consolidationPolicy: WhenEmpty
      consolidateAfter: 2m
    limits:
      cpu: '100'
      memory: 400Gi
```

### 2. Add repository secrets

| Secret | Description |
|---|---|
| `PS_CLIENT_ID` | PerfectScale API client id (Org Settings → API Tokens) |
| `PS_CLIENT_SECRET` | PerfectScale API client secret |
| `AI_API_KEY` | Anthropic or OpenAI API key |
| `APP_ID` | GitHub App client id (used to open PRs as the App) |
| `PRIVATE_KEY` | GitHub App private key |

> **Why a GitHub App token?** PRs opened with the default `GITHUB_TOKEN`
> cannot trigger other workflows (branch protection checks).  A GitHub App
> token does not have this restriction.

### 3. Add the workflow

Create `.github/workflows/infrafit-apply.yaml` in your repository:

```yaml
name: InfraFit apply

on:
  workflow_dispatch:
    inputs:
      pr_mode:
        description: "PR grouping: per-cluster or single"
        type: choice
        options: [per-cluster, single]
        default: per-cluster
      title_prefix:
        description: "Prefix for every PR title (e.g. a Jira key)"
        type: string
        default: "feat(INFRAFIT-0):"

permissions:
  contents: write
  pull-requests: write
  issues: write

concurrency:
  group: infrafit-apply
  cancel-in-progress: false

jobs:
  propose:
    runs-on: ubuntu-latest
    steps:
      - name: Generate GitHub App token
        id: token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1   # v3.2.0
        with:
          client-id:   ${{ secrets.APP_ID }}
          private-key: ${{ secrets.PRIVATE_KEY }}
          owner:       ${{ github.repository_owner }}

      - name: Checkout
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0   # v7.0.0
        with:
          token:       ${{ steps.token.outputs.token }}
          fetch-depth: 0

      - name: Run InfraFit apply
        uses: perfectscale-io/infrafit-action@v1
        with:
          ps_client_id:     ${{ secrets.PS_CLIENT_ID }}
          ps_client_secret: ${{ secrets.PS_CLIENT_SECRET }}
          ai_api_key:       ${{ secrets.AI_API_KEY }}
          github_token:     ${{ steps.token.outputs.token }}
          pr_mode:          ${{ inputs.pr_mode }}
          title_prefix:     ${{ inputs.title_prefix }}
```

That is the complete setup.  Trigger the workflow manually from the GitHub
Actions UI or add a `schedule:` trigger to run it automatically.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `ps_client_id` | ✅ | — | PerfectScale API client id |
| `ps_client_secret` | ✅ | — | PerfectScale API client secret |
| `ai_api_key` | ✅ | — | AI provider API key |
| `github_token` | ✅ | — | GitHub token with write access |
| `cluster_map` | | `.github/infrafit/cluster-map.json` | Path to cluster-map file |
| `pr_mode` | | `per-cluster` | `per-cluster` or `single` |
| `title_prefix` | | `feat(INFRAFIT-0):` | Prefix for PR titles and commit subjects |
| `base_branch` | | `main` | Branch to target for PRs |
| `ps_base_url` | | `https://api.app.perfectscale.io/public/v1` | PerfectScale API URL |
| `ai_provider` | | auto-detected | `anthropic` or `openai` |
| `ai_base_url` | | provider default | Override AI endpoint |
| `ai_model` | | provider default | Override AI model |

## What gets skipped

Any recommendation that cannot be applied automatically is collected into a
GitHub issue with a reason and instructions for manual resolution:

| Reason | How to fix |
|---|---|
| UID not in cluster-map.json | Add the cluster UID to `.github/infrafit/cluster-map.json` |
| Values file not found | Verify the path in `cluster-map.json` matches the actual file |
| Pool not defined in values file | Add the NodePool or update the mapping |
| AI returned empty output | Re-run; apply manually if it persists |

## License

[Apache 2.0](LICENSE)
