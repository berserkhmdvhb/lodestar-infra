#!/usr/bin/env bash
# Decide whether a root's plan job has work: reads changed file paths on stdin, writes run=true|false
# to $GITHUB_OUTPUT. Usage: git diff --name-only HEAD^1 HEAD | scripts/ci-changed.sh <apps|prod>
# apps: envs/apps/, modules/. prod: envs/prod/, bootstrap/prod/, modules/. Both: this script, ci-plan.sh and plan.yml.
# A manual run (workflow_dispatch) always plans.
set -Eeuo pipefail

root="${1:?usage: ci-changed.sh <apps|prod>}"
case "$root" in
  apps) own='^envs/apps/' ;;
  prod) own='^(envs/prod|bootstrap/prod)/' ;;
  *) echo "unknown root: ${root}" >&2; exit 2 ;;
esac
shared='^(modules/|scripts/ci-plan\.sh$|scripts/ci-changed\.sh$|\.github/workflows/plan\.yml$)'

run=false
if [[ "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]]; then
  run=true
else
  while IFS= read -r f; do
    if [[ "$f" =~ $own || "$f" =~ $shared ]]; then run=true; fi
  done
fi
echo "run=${run}" >>"${GITHUB_OUTPUT:-/dev/null}"
