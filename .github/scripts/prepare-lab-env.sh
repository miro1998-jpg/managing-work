#!/usr/bin/env bash
set -euo pipefail

# prepare-lab-env.sh — safer, clearer seed/delete helper for lab issues
# Usage: ./prepare-lab-env.sh [--seed-all|--delete]

# Require GH CLI installed
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI not found. Install from https://github.com/cli/cli" >&2
  exit 1
fi

# Determine repository (owner/repo) from environment or git
REPO="${GH_REPOSITORY:-}"
if [[ -z "$REPO" ]]; then
  if command -v git >/dev/null 2>&1; then
    REPO=$(git config --get remote.origin.url || true)
    # convert SSH/HTTPS remote to owner/repo
    REPO=${REPO#git@github.com:}
    REPO=${REPO#https://github.com/}
    REPO=${REPO%.git}
  fi
fi

if [[ -z "$REPO" ]]; then
  echo "Cannot determine repository (owner/repo). Set GH_REPOSITORY or run inside a git repo." >&2
  exit 1
fi

# Confirm destructive action
if [[ "$1" == "--delete" ]]; then
  echo "Deleting issues in $REPO — this is destructive. Pass --delete to confirm." >&2
  # Use gh api or gh issue list --json to get numbers safely
  issue_numbers=$(gh issue list --repo "$REPO" --limit 1000 --json number -q '.[].number') || true
  if [[ -n "$issue_numbers" ]]; then
    echo "Deleting $REPO issues: $issue_numbers"
    for n in $issue_numbers; do
      gh issue delete "$n" --repo "$REPO" --yes || true
    done
  fi
  exit 0
fi

if [[ "$1" == "--seed-all" || "$1" == "" ]]; then
  # load issue-seeds.json from the script directory
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  file_path="$script_dir/issue-seeds.json"
  if [[ ! -f "$file_path" ]]; then
    echo "No $file_path found; nothing to seed." >&2
    exit 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq required to parse $file_path. Install jq." >&2
    exit 1
  fi

  issue_seeds_json=$(jq -c '.[]' "$file_path")
  declare -A parent_issue_numbers=()

  while IFS= read -r issue_json; do
    title=$(echo "$issue_json" | jq -r '.title')
    body=$(echo "$issue_json" | jq -r '.body')
    labels=$(echo "$issue_json" | jq -r '.labels | join(",") // empty')
    milestone=$(echo "$issue_json" | jq -r '.milestone // empty')
    type=$(echo "$issue_json" | jq -r '.type // empty')
    id=$(echo "$issue_json" | jq -r '.id // empty')
    parent=$(echo "$issue_json" | jq -r '.parent // empty')

    if [[ -z "$title" || "$title" == "null" ]]; then
      echo "Skipping seed with empty title" >&2
      continue
    fi

    echo "Creating issue: $title"

    # create issue with gh; add labels and milestone if provided
    create_cmd=(gh issue create --repo "$REPO" --title "$title" --body "$body")
    if [[ -n "$labels" ]]; then
      IFS=',' read -ra labarr <<< "$labels"
      for L in "${labarr[@]}"; do
        create_cmd+=(--label "$L")
      done
    fi
    if [[ -n "$milestone" && "$milestone" != "null" ]]; then
      create_cmd+=(--milestone "$milestone")
    fi

    issue_url=$("${create_cmd[@]}") || { echo "Failed creating: $title" >&2; continue; }
    issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$' || true)
    if [[ -n "$issue_number" && -n "$id" ]]; then
      parent_issue_numbers["$id"]=$issue_number
    fi

    # If parent specified, attempt to add sub-issue relationship via REST API
    if [[ -n "$parent" && -n "${parent_issue_numbers[$parent]:-}" ]]; then
      parent_num=${parent_issue_numbers[$parent]}
      child_id=$(gh api -X GET "/repos/$REPO/issues/$issue_number" -q '.id') || true
      if [[ -n "$child_id" ]]; then
        # POST sub-issues using the repo API; user must have permission
        gh api -X POST "/repos/$REPO/issues/$parent_num/sub_issues" -f sub_issue_id="$child_id" || true
      fi
    fi

  done <<< "$issue_seeds_json"
fi
