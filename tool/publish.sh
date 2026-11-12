#!/usr/bin/env bash
# Creates the GitHub repository and pushes this source tree from an authenticated workstation.
# Prerequisites: git, gh, git identity, and permission to create repos under agent-axiom.
set -euo pipefail
cd "$(dirname "$0")/.."

for cmd in git gh; do
  if ! command -v "$cmd" >/dev/null; then
    printf 'Error: %s is required.\n' "$cmd" >&2
    exit 1
  fi
done

gh auth status >/dev/null

if [[ ! -d .git ]]; then
  git init -b main
fi

# Never overwrite an unrelated remote.
remote_url=$(git remote get-url origin 2>/dev/null || true)
if [[ -n "$remote_url" && "$remote_url" != 'https://github.com/agent-axiom/axiom-edge.git' && "$remote_url" != 'git@github.com:agent-axiom/axiom-edge.git' ]]; then
  printf 'Error: origin points to a different repository: %s\n' "$remote_url" >&2
  exit 1
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -m 'feat: bootstrap Axiom Edge mobile harness with APK CI and releases'
fi

git branch -M main
if ! gh repo view agent-axiom/axiom-edge >/dev/null 2>&1; then
  gh repo create agent-axiom/axiom-edge \
    --public \
    --description 'On-device LLM harness for Android and iOS: local inference, benchmarks and evals'
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin https://github.com/agent-axiom/axiom-edge.git
fi

git push -u origin main
printf 'Published: https://github.com/agent-axiom/axiom-edge\n'
printf 'CI: https://github.com/agent-axiom/axiom-edge/actions\n'
printf 'After the first green CI: git tag v0.1.1 && git push origin v0.1.1\n'
