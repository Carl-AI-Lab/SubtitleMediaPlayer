#!/usr/bin/env bash
set -euo pipefail

REPO_NAME="${1:-CarlPlayer}"
VISIBILITY="${GITHUB_VISIBILITY:-private}"

if ! command -v gh >/dev/null 2>&1; then
  echo "missing dependency: gh" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not logged in. Run: gh auth login" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "tracked working tree is not clean; commit or stash tracked changes first" >&2
  exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  gh repo create "$REPO_NAME" "--$VISIBILITY" --source=. --remote=origin --push
else
  git push -u origin "$(git branch --show-current)"
fi
