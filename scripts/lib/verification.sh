#!/usr/bin/env bash

# The record of the last passed verification of a working tree.
# Source this file; do not execute it. It needs scripts/lib/fingerprint.sh.
#
# ./scripts/verify.sh writes the record after a run in which every check
# passed. It names the content that was verified by its fingerprint, so any
# change to a file that Git does not ignore makes it stale. A script that
# needs a passed verification can then skip a second run on identical content
# with './scripts/verify.sh --reuse'.
#
# Next to it, the results of the budget checks of that run
# (VERIFICATION_BUDGETS): a check declared as '<name> [<group>] budget:
# <command>' measures something against a target, and a result over the
# target does not fail the verification. The record keeps every budget result
# with the output of its check, so that the scripts that reuse the pass can
# show the measurement where a decision is made: the reviewer's context, the
# handoff note, the commit message, and the pull request. The file exists only
# together with the pass, and only when the run had a budget check.
#
# The record is a working file that Git ignores. Without that ignore rule no
# record is written, because the file would become part of the fingerprint.
#
# A run inside an agent session counts like any other: the record says which
# content passed, whoever started the run. An agent could write the file
# instead of running the checks; that is accepted, because CI runs every check
# on a clean checkout before a merge.

VERIFICATION_RECORD=".agents/verification/passed"
VERIFICATION_BUDGETS=".agents/verification/budgets"

# verification_recordable <root>
# Succeeds when a record can be kept for the working tree at <root>.
verification_recordable() {
  command -v git >/dev/null 2>&1 || return 1
  [[ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" == "$1" ]] || return 1
  git -C "$1" check-ignore -q "$VERIFICATION_RECORD" 2>/dev/null
}

# verification_field <root> <field>
# Prints the value of 'tree', 'workflow-tests', or 'verified-at' in the
# record, or nothing when there is no record.
verification_field() {
  [[ -f "$1/$VERIFICATION_RECORD" ]] || return 0
  sed -n "s/^$2: //p" "$1/$VERIFICATION_RECORD" | head -n 1
}

# verification_write <root> <tree> <workflow-tests> [<budgets-file>]
# <workflow-tests> is 'ran', 'skipped', or 'none'. <budgets-file> holds the
# budget results of the run in the format of verification_budget_add; it is
# kept with the record, and without one, or with an empty one, no budget
# record is kept.
verification_write() {
  mkdir -p "$(dirname "$1/$VERIFICATION_RECORD")" &&
    printf 'tree: %s\nworkflow-tests: %s\nverified-at: %s\n' \
      "$2" "$3" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >"$1/$VERIFICATION_RECORD" || return 1
  if [[ -n "${4:-}" && -s "$4" ]]; then
    cp "$4" "$1/$VERIFICATION_BUDGETS"
  else
    rm -f "$1/$VERIFICATION_BUDGETS"
  fi
}

# verification_forget <root>
verification_forget() {
  rm -f "$1/$VERIFICATION_RECORD" "$1/$VERIFICATION_BUDGETS"
}

# verification_budget_add <budgets-file> <name> <status> <exit> <output-file>
# Appends the result of one budget check: <status> is 'exceeded' or 'within'.
# The format is plain text, one record per check, which the readers below
# parse: the output lines are indented by two spaces, so a line of the output
# is never taken for a field.
#
#   budget: <name>
#   status: exceeded | within
#   exit: <status of the check>
#   output:
#     <line of the output>
#   <empty line>
verification_budget_add() {
  {
    printf 'budget: %s\nstatus: %s\nexit: %s\noutput:\n' "$2" "$3" "$4"
    [[ ! -s "$5" ]] || sed 's/^/  /' "$5"
    echo
  } >>"$1"
}

# verification_budgets <root>
# Prints the recorded budget results of the last passed verification, in the
# format of verification_budget_add, and nothing without a record.
verification_budgets() {
  [[ -f "$1/$VERIFICATION_RECORD" && -f "$1/$VERIFICATION_BUDGETS" ]] || return 0
  cat "$1/$VERIFICATION_BUDGETS"
}

# verification_budgets_exceeded <budgets-text>
# Succeeds when the budget results name a budget that exceeded its target.
verification_budgets_exceeded() {
  grep -qx 'status: exceeded' <<<"$1"
}

# verification_budgets_json <budgets-file>
# Prints the budget results of a file as a JSON array of objects with name,
# status, exit, and output (one string, the lines joined), for the run record.
# Needs jq. An empty or missing file is an empty array.
verification_budgets_json() {
  if [[ ! -s "$1" ]]; then
    echo '[]'
    return 0
  fi
  jq -Rs '
    split("\n")
    | reduce .[] as $line ([];
        if ($line | startswith("budget: ")) then . + [{name: $line[8:], status: null, exit: null, output: []}]
        elif length == 0 then .
        elif ($line | startswith("status: ")) then .[-1].status = $line[8:]
        elif ($line | startswith("exit: ")) then .[-1].exit = ($line[6:] | tonumber? // null)
        elif ($line | startswith("  ")) then .[-1].output += [$line[2:]]
        else . end)
    | map(.output |= join("\n"))' "$1"
}

# verification_budget_report [<max-lines> [<where>]]
# Reads budget results in the format of verification_budget_add from standard
# input and prints one entry per budget, for a person: the first line starts
# with 'budget ', the lines of the output are indented by two spaces. A
# budget within its target is one line; an exceeded one shows the whole
# output of its check, which is the measurement. A caller that cannot carry
# a long output, such as a commit message, passes <max-lines> (0 is no
# limit, the default): the report then shows the last <max-lines> lines and
# says how many were left out, and where the full output is when <where>
# is given.
#
#   budget <name> exceeded: <the one line of output>
#   budget <name> exceeded:
#     <line of the output>
#   budget <name> exceeded:
#     (<n> earlier lines of the output left out; the full output is in <where>)
#     <line of the output>
#   budget <name> exceeded (exit <status>, no output)
#   budget <name> within its target
verification_budget_report() {
  awk -v max="${1:-0}" -v where="${2:-}" '
    function flush(    i, first, count) {
      if (name == "") return
      if (status != "exceeded") {
        print "budget " name " within its target"
      } else if (lines == 0) {
        print "budget " name " exceeded (exit " code ", no output)"
      } else if (lines == 1) {
        print "budget " name " exceeded: " output[1]
      } else {
        print "budget " name " exceeded:"
        first = 1
        if (max > 0 && lines > max) {
          first = lines - max + 1
          print "  (" (first - 1) " earlier lines of the output left out" (where == "" ? "" : "; the full output is in " where) ")"
        }
        for (i = first; i <= lines; i++) print "  " output[i]
      }
      name = ""; status = ""; code = ""; lines = 0
      delete output
    }
    /^budget: / { flush(); name = substr($0, 9); next }
    /^status: / { status = substr($0, 9); next }
    /^exit: / { code = substr($0, 7); next }
    /^output:$/ { next }
    /^  / { lines++; output[lines] = substr($0, 3); next }
    END { flush() }'
}
