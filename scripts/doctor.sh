#!/usr/bin/env bash

set -euo pipefail

# Read-only check of the local prerequisites for the template workflow.
# Uses only Bash builtins besides the tools it checks, except for the check
# of the Codex sandbox, which lays out a scratch repository in a temporary
# directory (mkdir, git init, rm), waits for the session (sleep) and removes
# it again. Nothing of the project is changed.

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" != "${BASH_SOURCE[0]}" ]] || script_dir="."
root="$script_dir/.."
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/github.sh"
source "$script_dir/lib/attribution.sh"

failed=0
gh_ready=0

ok() {
  echo "OK       $1"
}

warn() {
  echo "WARNING  $1"
  echo "         $2"
}

missing() {
  echo "FAILED   $1"
  echo "         $2"
  failed=1
}

# note: a fact to know that nothing here can change.
note() {
  echo "NOTE     $1"
  echo "         $2"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

# check_main_protection
# Warns when a pull request into 'main' can be merged without a passing status
# check. Rulesets are read first, then classic branch protection.
check_main_protection() {
  local count

  [[ "$gh_ready" -eq 1 ]] || return 0
  count="$(github_required_checks main)"

  if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
    ok "branch 'main' requires a passing status check before a merge"
  elif [[ "$count" == "0" ]]; then
    warn "branch 'main' accepts a merge while its checks fail" \
      "Add a ruleset for 'main' that requires the CI status check; see docs/repository-setup.md."
  else
    warn "could not read the rules of branch 'main' on GitHub" \
      "Check that 'main' requires the CI status check; see docs/repository-setup.md."
  fi
}

# check_codex_sandbox <model> <roles>
# Codex 0.164 mounts .agents/ read-only in its workspace-write sandbox, so a
# Codex session with write access gets the runtime directories it has to
# write opened as writable roots (lib/agent.sh, AGENT_CODEX_WRITABLE_DIRS).
# Whether that works with the Codex of this host is tried for real: a session
# of the unattended profile, with <model>, in a scratch repository laid out
# like a feature worktree, runs a probe that writes into every one of the
# directories, and a directory the probe cannot write is reported with its
# path. The session asks nothing ('codex exec' never does); one that does not
# end within DOCTOR_CODEX_TIMEOUT seconds (180 by default) is stopped and
# reported as a warning. Skipped, with a warning, when codex is not logged in.
check_codex_sandbox() {
  local model="$1"
  local roles="$2"
  local limit="${DOCTOR_CODEX_TIMEOUT:-180}"
  local scratch="${TMPDIR:-/tmp}/doctor-codex-sandbox.$$.$RANDOM"
  local probe="$scratch/sandbox-probe.sh"
  local results="$scratch/sandbox-probe-results"
  local final="$scratch/final.md"
  local prompt
  local dir
  local line
  local denied=""
  local writable=""
  local pid
  local attempt
  local waited
  local status

  # Inside a Codex session a second codex cannot start: its sandbox refuses
  # the files codex writes in its own home.
  if [[ -n "${CODEX_SESSION_ID:-}${CODEX_THREAD_ID:-}" ]]; then
    warn "whether codex can write the runtime files under .agents/ inside its sandbox was not checked: this runs inside a Codex session, which cannot start another one" \
      "Run this script from a terminal."
    return 0
  fi
  if ! codex login status </dev/null >/dev/null 2>&1; then
    warn "whether codex can write the runtime files under .agents/ inside its sandbox was not checked: codex is not logged in" \
      "Run 'codex login', then this script again. The roles$roles run Codex with write access."
    return 0
  fi

  if ! mkdir -p "$scratch/.agents/policies" "$scratch/.agents/prompts" 2>/dev/null ||
    ! git -C "$scratch" init -q 2>/dev/null; then
    rm -rf "$scratch" 2>/dev/null || true
    warn "whether codex can write the runtime files under .agents/ inside its sandbox was not checked: no scratch repository could be made under ${TMPDIR:-/tmp}" \
      "Check that the directory is writable, then run this script again."
    return 0
  fi

  # The probe writes a file in every runtime directory and notes the result
  # in the repository root, which the sandbox lets the session write. Bash
  # builtins only: it runs with whatever the sandbox offers.
  {
    echo '#!/usr/bin/env bash'
    printf ': >%q\n' "$results"
    for dir in $AGENT_CODEX_WRITABLE_DIRS; do
      printf 'if echo probe >%q 2>/dev/null; then echo "writable %s"; else echo "denied %s"; fi >>%q\n' \
        "$scratch/$dir/sandbox-probe" "$dir" "$dir" "$results"
    done
  } >"$probe"
  prompt="This is a check of your sandbox. Use your shell tool to run the command: bash $probe
Then reply with the single word done. Do not create or change any other file."

  # The session runs in a process group of its own, so that a session that
  # does not end can be stopped with everything it started. A model that
  # answers without running the command proves nothing: one more session,
  # then the result stands.
  for attempt in 1 2; do
    rm -f "$results" "$final"
    waited=0
    status=0
    set -m
    (
      agent_run_session unattended codex "$model" "$scratch" "$prompt" "$final" >/dev/null 2>"$scratch/session.err"
    ) </dev/null &
    pid=$!
    set +m
    while kill -0 "$pid" 2>/dev/null && [[ "$waited" -lt "$limit" ]]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -rf "$scratch" 2>/dev/null || true
      warn "the codex session that checks the sandbox did not end within $limit seconds and was stopped; whether codex can write the runtime files under .agents/ was not checked" \
        "Run this script again; a slow network or provider may be the cause. DOCTOR_CODEX_TIMEOUT sets the seconds to wait."
      return 0
    fi
    wait "$pid" || status=$?
    [[ ! -s "$results" && "$status" -eq 0 && "$attempt" -eq 1 ]] || break
  done

  if [[ -s "$results" ]]; then
    while IFS= read -r line; do
      case "$line" in
        "denied "*) denied+=" ${line#denied }" ;;
        "writable "*) writable+=" ${line#writable }" ;;
      esac
    done <"$results"
  fi
  for dir in $AGENT_CODEX_WRITABLE_DIRS; do
    [[ " $writable " == *" $dir "* || " $denied " == *" $dir "* ]] || denied+=" $dir"
  done

  if [[ -s "$results" && -n "$denied" ]]; then
    missing "codex cannot write$denied inside its sandbox, which the roles$roles have to" \
      "scripts/lib/agent.sh opens these directories as writable roots of the workspace-write sandbox (sandbox_workspace_write.writable_roots); this codex ($(codex --version 2>/dev/null || echo "version unknown")) does not honour that. Update Codex, or give the roles to Claude in .agents/agents.conf."
  elif [[ "$status" -ne 0 ]]; then
    warn "whether codex can write the runtime files under .agents/ inside its sandbox was not checked: the codex session failed (status $status)" \
      "$(line="$(<"$scratch/session.err")"; echo "${line:-The session left no error output.}")"
  elif [[ ! -s "$results" ]]; then
    missing "codex did not write the runtime files under .agents/ inside its sandbox: the probe of the sandbox left no result" \
      "$(line="$(<"$final")"; echo "The session answered: ${line:-nothing}")"
  else
    ok "codex can write the runtime directories under .agents/ inside its sandbox (${AGENT_CODEX_WRITABLE_DIRS// /, })"
  fi
  rm -rf "$scratch" 2>/dev/null || true
}

echo "== Agentic template doctor =="

if have git; then
  ok "git is installed"
else
  missing "git is not installed" "Install Git: https://git-scm.com/downloads"
fi

if have jq; then
  # The workflow scripts are written for jq 1.6 and later.
  jq_version="$(jq --version 2>/dev/null || true)"
  if [[ "$jq_version" =~ ^jq-([0-9]+)\.([0-9]+) ]] &&
    ((BASH_REMATCH[1] < 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] < 6))); then
    missing "jq $jq_version is too old" "Install jq 1.6 or later: 'brew install jq' or 'sudo apt-get install jq'"
  else
    ok "jq is installed"
  fi
else
  missing "jq is not installed" "Install jq: 'brew install jq' or 'sudo apt-get install jq'"
fi

if have gh; then
  ok "GitHub CLI (gh) is installed"
  if gh auth status >/dev/null 2>&1; then
    ok "GitHub CLI is authenticated"
    gh_ready=1
  else
    missing "GitHub CLI is not authenticated" "Run: gh auth login"
  fi
else
  missing "GitHub CLI (gh) is not installed" "Install it: https://cli.github.com"
fi

# Providers that .agents/agents.conf assigns to a role are required, on its
# plain line and on its lines per risk level ('<role>@<level>'). The file is
# validated as a whole by agent_lookup: an unsupported provider or model on
# any line, also of a role that is not started, makes it invalid.
codex_roles=""
claude_roles=""
# The roles with write access that use Codex, and the model of the first: the
# Codex sandbox is tried with it (check_codex_sandbox).
codex_write_roles=""
codex_write_model=""
# configured_provider <role> [level]: the provider the role resolves to for
# a feature of the level, by the line of the level or the plain line; nothing
# when neither exists.
configured_provider() {
  agent_lookup "$root" "$1" "${2:-}"
  if [[ -n "${2:-}" && -n "$AGENT_LEVEL_PROVIDER" ]]; then
    printf '%s' "$AGENT_LEVEL_PROVIDER"
  else
    printf '%s' "$AGENT_CONFIG_PROVIDER"
  fi
}
if config_error="$( (agent_lookup "$root" implementer) 2>&1)"; then
  if [[ -f "${AGENT_CONFIG_FILE:-$root/.agents/agents.conf}" ]]; then
    ok "agent configuration is valid"
    for role in $AGENT_ROLES; do
      agent_lookup "$root" "$role"
      role_levels="$AGENT_CONFIG_LEVELS"
      case "$AGENT_CONFIG_PROVIDER" in
        codex)
          codex_roles+=" $role"
          if [[ " $AGENT_WRITE_ROLES " == *" $role "* ]]; then
            codex_write_roles+=" $role"
            codex_write_model="${codex_write_model:-$AGENT_CONFIG_MODEL}"
          fi
          ;;
        claude) claude_roles+=" $role" ;;
      esac
      for level in $role_levels; do
        agent_lookup "$root" "$role" "$level"
        case "$AGENT_LEVEL_PROVIDER" in
          codex)
            codex_roles+=" $role@$level"
            if [[ " $AGENT_WRITE_ROLES " == *" $role "* ]]; then
              codex_write_roles+=" $role@$level"
              codex_write_model="${codex_write_model:-$AGENT_LEVEL_MODEL}"
            fi
            ;;
          claude) claude_roles+=" $role@$level" ;;
        esac
      done
      if [[ -n "$role_levels" && " $AGENT_FEATURE_ROLES " != *" $role "* ]]; then
        warn "role '$role' has a line per risk level ($role_levels) that never applies" \
          "Only a role of a feature (${AGENT_FEATURE_ROLES// /, }) runs with a risk level; the plain line of '$role' is used."
      fi
    done
    # A reviewing role and the role whose work it reviews should resolve to
    # different providers: for the plain lines, and for every level that
    # either side has a line for.
    for pair in $AGENT_REVIEW_PAIRS; do
      reviewing="${pair%%:*}"
      reviewed="${pair#*:}"
      reviewing_provider="$(configured_provider "$reviewing")"
      reviewed_provider="$(configured_provider "$reviewed")"
      if [[ -n "$reviewing_provider" && "$reviewing_provider" == "$reviewed_provider" ]]; then
        warn "roles '$reviewing' and '$reviewed' use the same agent ($reviewing_provider)" \
          "Use a different provider for a reviewing role than for the role whose work it reviews."
      fi
      for level in $AGENT_LEVELS; do
        agent_lookup "$root" "$reviewing" "$level"
        pair_levels="$AGENT_LEVEL_PROVIDER"
        agent_lookup "$root" "$reviewed" "$level"
        pair_levels+="$AGENT_LEVEL_PROVIDER"
        [[ -n "$pair_levels" ]] || continue
        reviewing_provider="$(configured_provider "$reviewing" "$level")"
        reviewed_provider="$(configured_provider "$reviewed" "$level")"
        if [[ -n "$reviewing_provider" && "$reviewing_provider" == "$reviewed_provider" ]]; then
          warn "roles '$reviewing' and '$reviewed' use the same agent ($reviewing_provider) for a $level-risk feature" \
            "The pair resolved for the level ('<role>@$level', or the plain line) should use different providers."
        fi
      done
    done
  else
    warn "agent configuration .agents/agents.conf was not found" \
      "Every workflow script then needs --agent and --model."
  fi
else
  missing "agent configuration is invalid" "${config_error#Error: }"
fi

# The project's preference on agent attribution, and how far the clients
# can be made to follow it. What a client cannot be configured to do is said
# as such: the check of finish-feature.sh and publish-feature.sh is then the
# only enforcement.
if attribution="$( (attribution_preference "$root") 2>&1)"; then
  case "$attribution" in
    unconfigured)
      warn "agent attribution is not configured" \
        "Select it in $ATTRIBUTION_CONFIG: '$ATTRIBUTION_SETTING: allowed' or '$ATTRIBUTION_SETTING: disabled'. Until then agents attribute their work as their clients do, and nothing is checked."
      ;;
    allowed)
      ok "agent attribution is allowed ($ATTRIBUTION_CONFIG)"
      ;;
    disabled)
      ok "agent attribution is disabled ($ATTRIBUTION_CONFIG): finish-feature.sh and publish-feature.sh refuse a commit or a description that carries it"
      claude_settings="${ATTRIBUTION_CLAUDE_SETTINGS_FILE:-$root/.claude/settings.json}"
      claude_settings_relative=".claude/settings.json"
      claude_settings_hint="Claude sessions that the scripts start get the setting on their command line. For a session you start yourself, add to $claude_settings_relative: {\"attribution\": {\"commit\": \"\", \"pr\": \"\"}}"
      if [[ ! -f "$claude_settings" ]]; then
        warn "Claude Code's attribution is not turned off: $claude_settings_relative does not exist" "$claude_settings_hint"
      elif ! have jq; then
        warn "Claude Code's attribution in $claude_settings_relative could not be checked without jq" "$claude_settings_hint"
      elif jq -e '(.attribution == false) or (.attribution.commit == "" and .attribution.pr == "") or (.includeCoAuthoredBy == false and (.attribution | type) != "object")' "$claude_settings" >/dev/null 2>&1; then
        ok "Claude Code's attribution is turned off in $claude_settings_relative"
      else
        warn "Claude Code's attribution is not turned off in $claude_settings_relative" "$claude_settings_hint"
      fi
      note "codex has no attribution setting, and Cursor's can be set only for the user, not in the project" \
        "For them, AGENTS.md and the check of finish-feature.sh and publish-feature.sh are what applies."
      ;;
  esac
else
  missing "the attribution configuration is invalid" "${attribution#Error: }"
fi

for agent in codex claude; do
  roles="${agent}_roles"
  if have "$agent"; then
    ok "$agent CLI is installed"
  elif [[ -n "${!roles}" ]]; then
    missing "$agent CLI is not installed" "It is configured for:${!roles}. Install it or change .agents/agents.conf."
  else
    warn "$agent CLI is not installed" "Install it before selecting '$agent' in a workflow script."
  fi
done

# A Codex role with write access has to write the runtime files of a feature
# under .agents/, which Codex's sandbox refuses unless agent.sh's grant works.
if [[ -n "$codex_write_roles" ]]; then
  if have codex; then
    check_codex_sandbox "$codex_write_model" "$codex_write_roles"
  else
    warn "whether codex can write the runtime files under .agents/ inside its sandbox was not checked: codex is not installed" \
      "Install it and run this script again. The roles$codex_write_roles run Codex with write access."
  fi
fi

if have git; then
  # finish-feature.sh commits as you, after the implementation, the review,
  # and the triage are done; without a name and an address Git refuses the
  # commit then ("unable to auto-detect email address").
  if [[ -n "$(git config user.name 2>/dev/null)" && -n "$(git config user.email 2>/dev/null)" ]]; then
    ok "git has a commit identity (user.name and user.email)"
  else
    missing "git has no commit identity: finish-feature.sh could not commit" \
      "Run: git config --global user.name \"Your Name\" && git config --global user.email \"you@example.com\""
  fi
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    ok "current directory is inside a Git repository"
    if git remote get-url origin >/dev/null 2>&1; then
      ok "remote 'origin' is configured"
      # Never prompt and never wait indefinitely on an unresponsive remote.
      if GIT_TERMINAL_PROMPT=0 \
        GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o ConnectTimeout=10" \
        GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME=10 \
        git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
        ok "branch 'main' is reachable on origin"
        # Reading a public repository works with any identity; pushing does
        # not. A dry run asks the remote for permission without changing it.
        if GIT_TERMINAL_PROMPT=0 \
          GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o ConnectTimeout=10" \
          GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME=10 \
          git push --dry-run --quiet origin HEAD:refs/heads/doctor-push-check >/dev/null 2>&1; then
          ok "you can push to origin"
          check_main_protection
        else
          missing "you cannot push to origin" \
            "Check that the remote URL uses the GitHub account that owns the repository: git remote get-url origin; ssh -T git@github.com"
        fi
      else
        missing "branch 'main' is not reachable on origin" \
          "Check network access and that origin has a 'main' branch: git ls-remote --heads origin main"
      fi
    else
      missing "remote 'origin' is not configured" "Run: git remote add origin <repository-url>"
    fi
  else
    missing "current directory is not inside a Git repository" "Run this script from the project checkout."
  fi
fi

echo
if [[ "$failed" -ne 0 ]]; then
  echo "Doctor found problems. Fix the FAILED items above and run it again." >&2
  exit 1
fi

echo "All required prerequisites are available."
