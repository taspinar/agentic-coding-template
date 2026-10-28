# Reports on the run records (lib/records.sh), for scripts/report-runs.sh.
#
# Input, as named arguments:
#   $active     the events of .agents/run/records/*.jsonl, as one array
#   $copies     the events of .agents/records/*.jsonl, as one array
#   $selection  [{kind, subject}], the subjects to report on
#   $since, $until, $split   epoch seconds, or null
#   $mode       "json", "markdown", or "summary" (the GitHub summary)
#
# A run is read from its own file while that file exists, and from the copy
# of its subject only when it does not, so no event is counted twice.

def roles: ["project-grill", "project-planner", "planning-reviewer", "implementer",
            "reviewer", "triage", "triage-implementer", "analyst"];

def number_or_null: if type == "number" then . else null end;

# tokens(f; g): the sum over the calls, with how many calls are in each of
# three states. f is the complete figure of a call (known). Without it, g is
# the figure that only some turns of the call reported (partial): it counts
# in the sum, which is then a lower bound. A call with neither is unknown,
# never 0.
def tokens(f; g):
  map({complete: (f | number_or_null), partial: (g | number_or_null)}) as $values
  | ($values | map(select(.complete != null))) as $known
  | ($values | map(select(.complete == null and .partial != null))) as $partial
  | {sum: (($known | map(.complete) | add // 0) + ($partial | map(.partial) | add // 0)),
     known: ($known | length),
     partial: ($partial | length),
     unknown: (($values | length) - ($known | length) - ($partial | length))};

def input_tokens: (.usage // {}) | .total_input;
def output_tokens: (.usage // {}) | .output_tokens;
def partial_input_tokens: (.usage // {}) | .partial | if type == "object" then .input_tokens else null end;
def partial_output_tokens: (.usage // {}) | .partial | if type == "object" then .output_tokens else null end;
def input_of: tokens(input_tokens; partial_input_tokens);
def output_of: tokens(output_tokens; partial_output_tokens);

# The elapsed time of intervals [start, end] that may overlap: their union,
# so that two runs side by side count once.
def union_seconds:
  sort_by(.[0])
  | reduce .[] as $i ({total: 0, current: null};
      if .current == null then .current = $i
      elif $i[0] <= .current[1] then .current[1] = ([.current[1], $i[1]] | max)
      else .total += (.current[1] - .current[0]) | .current = $i
      end)
  | .total + (if .current == null then 0 else .current[1] - .current[0] end);

def state_of($finish):
  if $finish == null then "incomplete"
  elif $finish.status == 0 then "completed"
  elif $finish.status == 3 then "blocked"
  elif $finish.status == 130 then "interrupted"
  else "failed"
  end;

def starts_of($events; $kind; $subject):
  $events | map(select(.type == "run-start" and .kind == $kind and ((.subject | tostring) == $subject)));

# The events of the runs of one subject, each run from one source.
def events_of($kind; $subject):
  (starts_of($active; $kind; $subject) | map({key: .run, value: true}) | from_entries) as $from_active
  | (starts_of($copies; $kind; $subject) | map(select($from_active[.run] | not)) | map({key: .run, value: true}) | from_entries) as $from_copy
  | ($active | map(select(.run as $r | $from_active[$r]))) + ($copies | map(select(.run as $r | $from_copy[$r])));

def runs_of($events):
  $events | group_by(.run) | map(
    (map(select(.type == "run-start")) | first) as $start
    | (map(select(.type == "run-end")) | last) as $finish
    | select($start != null)
    | {run: $start.run, command: $start.command, seq: $start.seq,
       start: $start.epoch, end: ($finish | if . == null then null else .epoch end),
       status: ($finish | if . == null then null else .status end), state: state_of($finish),
       versions: ($start.versions // {}),
       events: .})
  | map(select(($since == null or .start >= $since) and ($until == null or .start < $until)))
  | sort_by(.start, .seq // 0);

def step_name: .name | sub(", round [0-9].*$"; "");

# finished_or_open($events; begin; stop): the end events, and every start
# without its end as an unfinished one: its duration, status, and usage are
# unknown. A start and its end share the run and the id.
def finished_or_open($events; $begin; $stop):
  ($events | map(select(.type == $stop))) as $stops
  | ($stops | map(select(.id != null) | {key: "\(.run) \(.id)", value: true}) | from_entries) as $stoped
  | $stops + ($events | map(select(.type == $begin and ($stoped["\(.run) \(.id)"] | not))
                       | . + {type: $stop, status: null, seconds: null, usage: null, unfinished: true}));

def report_subject($kind; $subject):
  runs_of(events_of($kind; $subject)) as $runs
  | ($runs | map(.events[])) as $events
  | finished_or_open($events; "agent-start"; "agent-call") as $calls
  | finished_or_open($events; "step-start"; "step") as $steps
  | {kind: $kind, subject: $subject, has_record: ($runs | length > 0),
     runs: {total: ($runs | length),
            completed: ($runs | map(select(.state == "completed")) | length),
            failed: ($runs | map(select(.state == "failed")) | length),
            blocked: ($runs | map(select(.state == "blocked")) | length),
            interrupted: ($runs | map(select(.state == "interrupted")) | length),
            incomplete: ($runs | map(select(.state == "incomplete")) | length)},
     first_start: ($runs | map(.start) | min),
     elapsed: {seconds: ($runs | map(select(.end != null) | [.start, .end]) | union_seconds),
               runs_without_end: ($runs | map(select(.end == null)) | length)},
     # The workflow profile of the risk policy, as the latest risk event of
     # the runs recorded it; null for runs recorded before the profiles.
     profile: ($events | map(select(.type == "risk" and (.profile | type) == "string")) | last | .profile // null),
     agent_seconds: ($calls | map(.seconds | number_or_null // 0) | add // 0),
     unfinished_calls: ($calls | map(select(.unfinished == true)) | length),
     steps: ($steps | group_by(step_name) | map({
       name: (first | step_name), count: length,
       seconds: (map(.seconds | number_or_null // 0) | add),
       failed: (map(select(.status != null and .status != 0)) | length),
       unfinished: (map(select(.unfinished == true)) | length)})),
     verification: ($events | map(select(.type == "verification")) | {
       count: length, seconds: (map(.seconds | number_or_null // 0) | add // 0),
       reused: (map(select(.reused == true)) | length),
       failed: (map(select(.status != 0)) | length),
       interrupted: (($events | map(select(.type == "verification-start")) | length) - length)}),
     agents: ($calls | group_by([.role, .agent, .model]) | map({
       role: first.role, agent: first.agent, model: first.model, calls: length,
       failed: (map(select(.status != null and .status != 0)) | length),
       unfinished: (map(select(.unfinished == true)) | length),
       seconds: (map(.seconds | number_or_null // 0) | add),
       input: input_of, output: output_of})),
     # The calls by the risk level of the feature when each started and by
     # what selected the agent (lib/agent.sh); a call recorded before the
     # levels existed has none and is left out here.
     levels: ($calls | map(select((.level | type) == "string"))
       | group_by([.level, .role, .agent, .model, .selection])
       | map({
           level: first.level, role: first.role, agent: first.agent, model: first.model,
           selection: (first.selection // "unknown"), calls: length,
           failed: (map(select(.status != null and .status != 0)) | length),
           unfinished: (map(select(.unfinished == true)) | length),
           seconds: (map(.seconds | number_or_null // 0) | add),
           input: input_of, output: output_of})
       | sort_by(({low: 0, medium: 1, high: 2}[.level] // 3), (.role as $role | roles | index([$role]) // 99), .agent, .model, .selection)),
     by_run: ($runs | map(finished_or_open(.events; "agent-start"; "agent-call") as $c | {
       run, command, seq, state, status,
       seconds: (if .end == null then null else .end - .start end),
       input: ($c | input_of), output: ($c | output_of),
       # The verifications of the run that ran checks (a reused pass ran
       # none; one recorded before the durations has none), each with the
       # sum of its checks and its five slowest.
       verifications: (.events | map(select(.type == "verification" and ((.checks // []) | type) == "array" and ((.checks // []) | length) > 0)
         | {status, seconds,
            checks_seconds: (.checks | map(.seconds | number_or_null // 0) | add),
            slowest: (.checks | map(select((.seconds | number_or_null) != null)) | sort_by(-.seconds) | .[:5]
                      | map({name, config, seconds, result}))}))})),
     rounds: {
       review: ($calls | map(select((.role == "reviewer" or .role == "planning-reviewer") and .status == 0)) | length),
       triage: ($calls | map(select(.role == "triage" and .status == 0)) | length),
       repair: (($calls | map(select(.role == "triage-implementer")) | length)
               + ($runs | map(select(.command == "revise-planning.sh") | .events[]
                   | select(.type == "agent-call" and .role == "project-planner")) | length))},
     interventions: ($events | map(select(.type == "intervention")) | group_by(.what)
                     | map({what: first.what, count: length})),
     resumed: ($events | map(select(.type == "resumed")) | length),
     versions: ($runs | map(.versions) | unique),
     models: ($calls | map({agent, model}) | unique),
     input: ($calls | input_of), output: ($calls | output_of)};

# What differs between the subjects of a comparison.
def differences($subjects):
  [ (["template", "prompts", "agents_conf"][] as $field
     | ($subjects | map({subject: "\(.kind) \(.subject)", values: (.versions | map(.[$field]) | map(select(. != null)) | unique)})) as $per
     | select(($per | map(.values) | unique | length) > 1)
     | {field: $field, per_subject: $per}),
    (($subjects | map({subject: "\(.kind) \(.subject)", values: (.models | map("\(.agent)/\(.model)"))})) as $per
     | select(($per | map(.values) | unique | length) > 1)
     | {field: "models", per_subject: $per}) ];

def caution:
  "These figures describe what happened; they do not show why. Features differ in size and difficulty, so a difference between totals or averages is no evidence that a version, a prompt, or a model caused it.";

def mean(f): if length == 0 then null else (map(f) | add) / length end;

def series($subjects; $name):
  {label: $name, features: ($subjects | length),
   mean_elapsed_seconds: ($subjects | map(select(.elapsed.runs_without_end == 0)) | mean(.elapsed.seconds)),
   features_with_incomplete_elapsed: ($subjects | map(select(.elapsed.runs_without_end > 0)) | length),
   mean_review_rounds: ($subjects | mean(.rounds.review)),
   mean_repair_rounds: ($subjects | mean(.rounds.repair)),
   mean_input_tokens: ($subjects | map(select(.input.unknown == 0 and .input.partial == 0)) | if length == 0 then null else mean(.input.sum) end),
   mean_output_tokens: ($subjects | map(select(.output.unknown == 0 and .output.partial == 0)) | if length == 0 then null else mean(.output.sum) end),
   features_with_unknown_tokens: ($subjects | map(select(.input.unknown > 0 or .input.partial > 0 or .output.unknown > 0 or .output.partial > 0)) | length)};

def report:
  ($selection | map(report_subject(.kind; .subject))) as $all
  | ($all | map(select(.has_record))) as $found
  | {schema: "run-report/v1",
     subjects: $found,
     without_record: ($all | map(select(.has_record | not) | {kind, subject})),
     comparison: (if ($found | length) > 1 then {differences: differences($found), caution: caution} else null end),
     before_after: (if $split == null then null else
       {split: ($split | todate),
        before: series($found | map(select(.first_start < $split)); "before"),
        after: series($found | map(select(.first_start >= $split)); "after"),
        caution: caution} end)};

# --- Markdown ---------------------------------------------------------------

def duration:
  if . == null then "unknown"
  else (. | floor) as $s
    | if $s >= 3600 then "\($s / 3600 | floor)h \(($s % 3600) / 60 | floor)m"
      elif $s >= 60 then "\($s / 60 | floor)m \($s % 60)s"
      else "\($s)s" end
  end;

# A token sum as text: "unknown" when no call reported any figure, "at least"
# when some calls reported only part of it or nothing.
def token_text:
  (.known + .partial + .unknown) as $calls
  | if $calls == 0 then "–"
  elif .known == 0 and .partial == 0 then "unknown"
  elif .partial > 0 or .unknown > 0 then
    "at least \(.sum) (" + ([(if .partial > 0 then "\(.partial) of \($calls) calls with partial figures" else empty end),
                             (if .unknown > 0 then (if .partial > 0 then "\(.unknown) without figures" else "\(.unknown) of \($calls) calls without figures" end) else empty end)] | join(", ")) + ")"
  else "\(.sum)" end;

# The elapsed time of a subject as text: "at least" when a run has no end.
def elapsed_text:
  if .runs_without_end > 0 then "at least \(.seconds | duration) (\(.runs_without_end) runs without an end)"
  else .seconds | duration end;

def subject_markdown:
  "## \(.kind | if . == "feature" then "Feature #" else "Planning " end)\(.subject)\n\n"
  + "| | |\n|---|---|\n"
  + "| Runs | \(.runs.total): \(.runs.completed) completed, \(.runs.failed) failed, \(.runs.blocked) blocked, \(.runs.interrupted) interrupted, \(.runs.incomplete) without an end |\n"
  + (if .kind == "feature" then "| Workflow profile | \(.profile // "not recorded") |\n" else "" end)
  + "| Elapsed time | \(.elapsed | elapsed_text) |\n"
  + "| Agent time | \(.agent_seconds | duration) (the sum of all agent calls; higher than the elapsed time when work ran side by side\(if .unfinished_calls > 0 then "; without \(.unfinished_calls) calls that did not finish" else "" end)) |\n"
  + "| Review rounds | \(.rounds.review) |\n"
  + "| Triage | \(.rounds.triage) |\n"
  + "| Repair sessions | \(.rounds.repair) |\n"
  + "| Input tokens | \(.input | token_text) |\n"
  + "| Output tokens | \(.output | token_text) |\n"
  + "| Verification | \(.verification.count) runs, \(.verification.seconds | duration), \(.verification.reused) reused, \(.verification.failed) failed\(if .verification.interrupted > 0 then ", \(.verification.interrupted) interrupted" else "" end) |\n"
  + "\n### Agents\n\n"
  + (if (.agents | length) == 0 then "No agent call was recorded.\n" else
      "| Role | Agent | Model | Calls | Time | Input tokens | Output tokens |\n|---|---|---|---|---|---|---|\n"
      + (.agents | map("| \(.role) | \(.agent) | \(.model) | \(.calls)\([(if .failed > 0 then "\(.failed) failed" else empty end), (if .unfinished > 0 then "\(.unfinished) unfinished" else empty end)] | if length > 0 then " (\(join(", ")))" else "" end) | \(.seconds | duration) | \(.input | token_text) | \(.output | token_text) |\n") | add)
    end)
  + (if (.levels | length) == 0 then "" else
      "\n### Per risk level\n\nThe risk level of the feature when each call started, and what selected its agent: the line of the role for that level (`level-line`), the plain line of the role (`plain-line`), or `--agent`/`--model` (`command-line`).\n\n"
      + "| Level | Role | Agent | Model | Selected by | Calls | Time | Input tokens | Output tokens |\n|---|---|---|---|---|---|---|---|---|\n"
      + (.levels | map("| \(.level) | \(.role) | \(.agent) | \(.model) | \(.selection) | \(.calls)\([(if .failed > 0 then "\(.failed) failed" else empty end), (if .unfinished > 0 then "\(.unfinished) unfinished" else empty end)] | if length > 0 then " (\(join(", ")))" else "" end) | \(.seconds | duration) | \(.input | token_text) | \(.output | token_text) |\n") | add)
    end)
  + (if (.steps | length) == 0 then "" else
      "\n### Steps of run-feature.sh\n\n| Step | Times | Time | Failed | Unfinished |\n|---|---|---|---|---|\n"
      + (.steps | map("| \(.name) | \(.count) | \(.seconds | duration) | \(.failed) | \(.unfinished) |\n") | add)
    end)
  + "\n### Runs\n\n| # | Command | State | Time | Input tokens | Output tokens |\n|---|---|---|---|---|---|\n"
  + (.by_run | map("| \(.seq // "–") | \(.command) | \(.state)\(if .status != null and .status != 0 then " (\(.status))" else "" end) | \(.seconds | duration) | \(.input | token_text) | \(.output | token_text) |\n") | add)
  + ([.by_run[] as $run | $run.verifications[] | {seq: $run.seq, command: $run.command} + .] as $verifications
     | if ($verifications | length) == 0 then "" else
      "\n### Slowest checks\n\nThe five slowest checks of each verification that ran its checks, with the sum of the durations of all of its checks.\n\n| # | Command | Verification | Checks | Slowest checks |\n|---|---|---|---|---|\n"
      + ($verifications | map("| \(.seq // "–") | \(.command) | \(if .status == 0 then "passed" else "failed" end), \(.seconds | duration) | \(.checks_seconds | duration) | \(.slowest | map("\(.name) \(.seconds | duration)\(if .result == "fail" then " (failed)" else "" end)") | join(", ")) |\n") | add)
    end)
  + "\n### Interventions\n\n"
  + (if (.interventions | length) == 0 then "None were recorded.\n" else
      (.interventions | map("- \(.what): \(.count)\n") | add) end)
  + (if .resumed > 0 then "\n\(.resumed) runs followed a run that stopped; who started them is not recorded.\n" else "" end)
  + "\n### Versions\n\n"
  + (if (.versions | length) == 0 then "None were recorded.\n" else
      (.versions | map("- template \(.template // "unknown"), prompts \(.prompts // "unknown"), agents.conf \(.agents_conf // "unknown")\n") | add) end);

def markdown:
  "# Run report\n\n"
  + (if (.subjects | length) == 0 then "No run was recorded for the selection.\n\n" else "" end)
  + (if (.without_record | length) > 0 then
      "Without any \(if $period then "run in the selected period" else "record" end): \(.without_record | map("\(.kind) \(.subject)") | join(", ")). They are left out, not counted as zero.\n\n"
    else "" end)
  + (.subjects | map(subject_markdown + "\n") | add // "")
  + (if .comparison == null then "" else
      "## Comparison\n\n| Subject | Elapsed time | Runs | Review rounds | Repair sessions | Input tokens | Output tokens |\n|---|---|---|---|---|---|---|\n"
      + (.subjects | map("| \(.kind) \(.subject) | \(.elapsed | elapsed_text) | \(.runs.total) | \(.rounds.review) | \(.rounds.repair) | \(.input | token_text) | \(.output | token_text) |\n") | add)
      + "\n"
      + (if (.comparison.differences | length) == 0 then "The subjects ran with the same versions and models.\n"
         else "Differences between the subjects:\n\n"
           + (.comparison.differences | map("- \(.field): " + (.per_subject | map("\(.subject) \(.values | join(", ") | if . == "" then "unknown" else . end)") | join("; ")) + "\n") | add)
         end)
      + "\n\(.comparison.caution)\n\n" end)
  + (if .before_after == null then "" else
      "## Before and after \(.before_after.split)\n\n| Series | Features | Mean elapsed time | Mean review rounds | Mean repair sessions | Mean input tokens | Mean output tokens |\n|---|---|---|---|---|---|---|\n"
      + ([.before_after.before, .before_after.after] | map(.features as $features | "| \(.label) | \(.features) | \(.mean_elapsed_seconds | if . == null then "–" else duration end) | \(.mean_review_rounds // "–") | \(.mean_repair_rounds // "–") | \(.mean_input_tokens | if type == "number" then floor elif $features == 0 then "–" else "unknown" end) | \(.mean_output_tokens | if type == "number" then floor elif $features == 0 then "–" else "unknown" end) |\n") | add)
      + "\nMeans of elapsed time leave out the features with runs without an end (before: \(.before_after.before.features_with_incomplete_elapsed), after: \(.before_after.after.features_with_incomplete_elapsed)). Means of tokens leave out the features with calls without complete figures (before: \(.before_after.before.features_with_unknown_tokens), after: \(.before_after.after.features_with_unknown_tokens)).\n\n\(.before_after.caution)\n" end);

# --- The summary on GitHub ---------------------------------------------------
#
# Built from an explicit list of numeric fields, so that no path, time of day,
# status reason, or other text of the records can reach a public comment. A
# role outside the known roles and a model name with other characters become
# "other".

def summary_fields:
  .subjects[0] as $s
  | if $s == null then null else
    {elapsed_seconds: ($s.elapsed.seconds | number_or_null // 0 | floor),
     runs: ($s.runs.total | number_or_null // 0),
     runs_without_end: ($s.runs.incomplete | number_or_null // 0),
     review_rounds: ($s.rounds.review | number_or_null // 0),
     repair_sessions: ($s.rounds.repair | number_or_null // 0),
     tokens: ($s.agents | map({
       role: (.role as $r | if (roles | index([$r])) != null then $r else "other" end),
       model: (.model | if type == "string" and test("^[A-Za-z0-9._-]{1,64}$") then . else "other" end),
       calls: (.calls | number_or_null // 0),
       input: (.input.sum | number_or_null // 0), input_known: (.input.known | number_or_null // 0),
       input_partial: (.input.partial | number_or_null // 0), input_unknown: (.input.unknown | number_or_null // 0),
       output: (.output.sum | number_or_null // 0), output_known: (.output.known | number_or_null // 0),
       output_partial: (.output.partial | number_or_null // 0), output_unknown: (.output.unknown | number_or_null // 0)})
       # Rows that became the same role and model are one row.
       | group_by([.role, .model]) | map({role: first.role, model: first.model,
           calls: (map(.calls) | add), input: (map(.input) | add), input_known: (map(.input_known) | add),
           input_partial: (map(.input_partial) | add), input_unknown: (map(.input_unknown) | add), output: (map(.output) | add),
           output_known: (map(.output_known) | add), output_partial: (map(.output_partial) | add),
           output_unknown: (map(.output_unknown) | add)}))}
    end;

def summary_markdown:
  def figure($sum; $known; $partial; $unknown):
    if $known == 0 and $partial == 0 and $unknown > 0 then "unknown"
    elif $partial > 0 or $unknown > 0 then "≥ \($sum)" else "\($sum)" end;
  summary_fields
  | if . == null then null else
    "<!-- run-records-summary -->\n### Run summary\n\n"
    + "| | |\n|---|---|\n"
    + "| Elapsed time | \(if .runs_without_end > 0 then "≥ " else "" end)\(.elapsed_seconds | duration)\(if .runs_without_end > 0 then " (\(.runs_without_end) runs without an end)" else "" end) |\n"
    + "| Runs | \(.runs) |\n"
    + "| Review rounds | \(.review_rounds) |\n"
    + "| Repair sessions | \(.repair_sessions) |\n"
    + (if (.tokens | length) == 0 then "" else
        "\n| Role | Model | Calls | Input tokens | Output tokens | Input calls: complete / partial / unknown | Output calls: complete / partial / unknown |\n|---|---|---|---|---|---|---|\n"
        + (.tokens | map("| \(.role) | \(.model) | \(.calls) | \(figure(.input; .input_known; .input_partial; .input_unknown)) | \(figure(.output; .output_known; .output_partial; .output_unknown)) | \(.input_known) / \(.input_partial) / \(.input_unknown) | \(.output_known) / \(.output_partial) / \(.output_unknown) |\n") | add)
      end)
    + "\n≥ marks a sum to which some calls reported no figure or only part of it. Replaced each time the feature is published.\n"
    end;

report
| if $mode == "json" then .
  elif $mode == "summary" then summary_markdown
  else markdown end
