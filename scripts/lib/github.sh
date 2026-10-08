#!/usr/bin/env bash

# Questions about the repository on GitHub.
# Source this file; do not execute it. It uses only Bash builtins and the
# GitHub CLI.

# github_required_checks <branch>
# Prints how many status checks a pull request into <branch> must pass before
# it can be merged: rulesets first, then classic branch protection. Prints
# nothing when that cannot be read, for example without access or network.
github_required_checks() {
  local count

  count="$(gh api "repos/{owner}/{repo}/rules/branches/$1" \
    --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]] | length' 2>/dev/null)" ||
    count=""
  if [[ "$count" == "0" ]]; then
    count="$(gh api "repos/{owner}/{repo}/branches/$1" \
      --jq '[(.protection.required_status_checks.contexts // [])[], (.protection.required_status_checks.checks // [])[]] | length' 2>/dev/null)" ||
      count=""
  fi
  [[ ! "$count" =~ ^[0-9]+$ ]] || printf '%s' "$count"
}
