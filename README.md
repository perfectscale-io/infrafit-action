# infrafit-action

A GitHub Action that fetches [PerfectScale](https://perfectscale.io) InfraFit
Karpenter NodePool recommendations and applies them to your Karpenter
configuration files as a pull request.  Nothing is applied to a live cluster — the PR review is
the gate.

## How it works

1. Authenticates to the PerfectScale public API using your service token.
2. Lists all clusters and fetches Karpenter NodePool recommendations for each
   cluster that appears in your `.github/infrafit-cluster-map.json`.
3. For each actionable NodePool, calls your AI provider with the current YAML
   file and the structured list of changes — the AI returns the edited YAML.
4. Opens a pull request (or one per cluster, depending on `pr_mode`) with the
   diff.  Recommendations that cannot be applied automatically are collected
   into a GitHub issue for manual review.

AI is used only for the YAML editing step.  All API calls, file routing, git
operations, and PR/issue creation are handled by the action itself.

## Supported AI providers

| Provider | Configuration | Default model |
|---|---|---|
| Anthropic | `ai_api_key` with an `sk-ant-*` key (auto-detected) | `claude-sonnet-5` |
| OpenAI | `ai_api_key` with any other key (auto-detected) | `gpt-5.6` |
| Amazon Bedrock | set `ai_provider: bedrock` + AWS credentials — no API key needed (see below) | `anthropic.claude-sonnet-5` |
| Azure OpenAI | set `ai_provider: openai` + `ai_base_url: https://<resource>.openai.azure.com/openai` (the `/openai` suffix is required) + `ai_model: <deployment name>` | your deployment |
| Any OpenAI-compatible endpoint | set `ai_provider: openai` + `ai_base_url` | your model |

### Using Amazon Bedrock

With `ai_provider: bedrock` the action calls Claude in Amazon Bedrock and
authenticates with AWS credentials instead of an API key. Configure
credentials before the action runs — the standard pattern is OIDC via
`aws-actions/configure-aws-credentials` (requires `id-token: write` in the
job's permissions):

```yaml
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@517a711dbcd0e402f90c77e7e2f81e849156e31d   # v6.2.2
        with:
          role-to-assume: arn:aws:iam::<account-id>:role/<role-name>
          aws-region: us-east-1

      - name: Run InfraFit apply
        uses: perfectscale-io/infrafit-action@v1
        with:
          ps_client_id:     ${{ secrets.PS_CLIENT_ID }}
          ps_client_secret: ${{ secrets.PS_CLIENT_SECRET }}
          ai_provider:      bedrock
          github_token:     ${{ steps.token.outputs.token }}
```

Requirements:

- The AWS account must have [Bedrock model access](https://console.aws.amazon.com/bedrock/home#/modelaccess)
  enabled for the Claude model in use.
- The assumed role needs the `bedrock-mantle:CreateInference` permission on
  the allowed model ARNs.
- The region comes from `aws-region` above; pass the `aws_region` input to
  override it.
- Alternatively, a short-lived Bedrock bearer token (from
  `aws-bedrock-token-generator`) can be passed as `ai_api_key` instead of AWS
  credentials.

## Setup

### 1. Add the cluster map

Copy [`cluster-map.example.json`](cluster-map.example.json) to
`.github/infrafit-cluster-map.json` in your repository and fill in your
cluster UIDs and the repo-relative paths to your Karpenter configuration
files.

```json
{
  "_readme": "Maps PerfectScale cluster UIDs to Karpenter configuration files.",
  "abc123-your-cluster-uid": "karpenter-profiles/values/prod.yaml",
  "xyz789-another-cluster":  "karpenter-profiles/values/staging.yaml"
}
```

**Finding your cluster UID:**

Log in to the [PerfectScale UI](https://app.perfectscale.io) and open the
cluster — the UID is shown in the URL and on the cluster settings page.

**Configuration file requirements:**

Each mapped file must have a top-level `NodePools` key with one entry per
pool, keyed by the NodePool name. This is how the action routes each
recommendation to the right piece of YAML: it looks up the recommended
NodePool by name under `NodePools:` and edits only that entry — pools not
found there are skipped and reported in the tracking issue.

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

### 2. GitHub App

A GitHub App is required for the token you pass as `github_token`. The App
must be installed on the repository with these repository permissions:

| Permission | Access | Used for |
|---|---|---|
| Contents | Read and write | pushing branches with the proposed changes |
| Pull requests | Read and write | opening pull requests |
| Issues | Read and write | creating/updating the tracking issue for skipped items |

> **Note:** an App token carries the App's own permissions — the
> `permissions:` block in your workflow YAML has no effect on it. A run
> failing with `Resource not accessible by integration` means the App lacks
> one of the permissions above.

### 3. Add repository secrets

| Secret | Description |
|---|---|
| `PS_CLIENT_ID` | PerfectScale API client id (Org Settings → API Tokens) |
| `PS_CLIENT_SECRET` | PerfectScale API client secret |
| `AI_API_KEY` | Anthropic or OpenAI API key |
| `APP_ID` | GitHub App client id (used to open PRs as the App) |
| `PRIVATE_KEY` | GitHub App private key |

### 4. Add the workflow

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
| `ai_api_key` | anthropic/openai | — | AI provider API key (not needed for `bedrock`) |
| `github_token` | ✅ | — | GitHub token with write access |
| `cluster_map` | | `.github/infrafit-cluster-map.json` | Path to cluster-map file |
| `pr_mode` | | `per-cluster` | `per-cluster` or `single` |
| `title_prefix` | | `feat(INFRAFIT-0):` | Prefix for PR titles and commit subjects |
| `base_branch` | | `main` | Branch to target for PRs |
| `ps_base_url` | | `https://api.app.perfectscale.io/public/v1` | PerfectScale API URL |
| `ai_provider` | | auto-detected | `anthropic`, `openai` or `bedrock` (bedrock must be explicit) |
| `ai_base_url` | | provider default | Override AI endpoint |
| `ai_model` | | provider default | Override AI model |
| `aws_region` | | ambient `AWS_REGION` | AWS region for Bedrock |

## What gets skipped

Any recommendation that cannot be applied automatically is collected into a
GitHub issue with a reason and instructions for manual resolution:

| Reason | How to fix |
|---|---|
| UID not in infrafit-cluster-map.json | Add the cluster UID to `.github/infrafit-cluster-map.json`, or ignore if intentionally unmanaged |
| Values file not found | Verify the path in `.github/infrafit-cluster-map.json` matches the actual file |
| Values file shared with another cluster | Per-cluster PRs need one file per cluster — use `pr_mode: single` or split the mapping |
| Pool not defined in values file | Add the NodePool or update the mapping |
| AI edit failed or failed validation | The edit was discarded (API error, truncated/invalid YAML, or dropped pools). Re-run; apply manually if it persists |

## License

[Apache 2.0](LICENSE)
