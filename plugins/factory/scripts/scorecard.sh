#!/usr/bin/env bash
# The factory scorecard: one week of numbers that say whether the factory is getting
# better. review-sessions runs it every Monday and publishes the result.
#
#   scorecard.sh [--since ISO] [--until ISO] [--threads DIR] [--logs]
#
# Prints one JSON object: the week, a `metrics` block and a `prs` list with each
# merged PR's own numbers, so any figure can be traced to the PRs behind it.
#
# What each number means (count them the same way every week):
#
#   prs_merged        PRs merged in [since, until), into any base. `into_default` is
#                     the subset merged into the default branch.
#   first_pass_ci     Of merged PRs that ran CI, the share whose first CI round passed:
#                     every non-review workflow on the first head SHA that ran CI
#                     concluded success on attempt 1. A rerun to green is not a pass.
#   review_findings   Inline findings the reviewer left (top-level review comments by
#                     SCORECARD_REVIEWER, replies excluded), per merged PR. Also the
#                     number of PRs with at least one `outcome=findings` review round.
#   rework_pushes     Pushes after a PR was ready: distinct head SHAs that ran CI or
#                     review (drafts skip both), minus the first. Branch updates count.
#   asks_of_owner     From --threads only: times the owner had to answer in a project
#                     thread, by ask time in the window. Each owner message pairs with
#                     the agent's last message before it (unless the owner already
#                     wrote since), and each card pick with its decision card. Also the
#                     median hours from ask to answer. A check-in on a quiet thread
#                     counts too: it is still the owner's time. null without --threads,
#                     or when no saved thread had a message in the window.
#   usage_window_hits Subscription usage-limit hits: thread messages that report one
#                     (--threads), plus failed review runs whose log reports one (--logs,
#                     which downloads each failed review job's log). null when neither
#                     source was read.
#
# --threads DIR holds one JSON file per project thread, each the `read_thread` result
# for that thread ({"thread_id", "messages": [{author, created_at, body}...]}). Only
# a Claude session can read threads, so the caller saves them; this script only counts.
#
# The repo is the caller's: FACTORY.md's repo.github, found from the git toplevel.
# Tunables: SCORECARD_REVIEWER (claude[bot]), SCORECARD_GH (gh binary; tests only).
#
# Exit codes: 0 printed; 2 usage or environment problem; 3 a GitHub read failed.

set -uo pipefail

gh_bin=${SCORECARD_GH:-gh}
reviewer=${SCORECARD_REVIEWER:-claude[bot]}
# Phrases Claude Code and claude-code-action print when a subscription window runs
# out. Kept narrow on purpose: a review log also holds the review prompt, and a loose
# pattern such as "rate limit" would match the prompt rather than an event.
usage_re='usage limit reached|hit your (usage )?limit|limit will reset at|rate_limit_error|out of extra usage'

die() { local code=$1; shift; echo "scorecard: $*" >&2; exit "$code"; }

since="" until="" threads="" logs=0
while [ $# -gt 0 ]; do
  case $1 in
    --since) since=${2-}; shift 2 ;;
    --until) until=${2-}; shift 2 ;;
    --threads) threads=${2-}; shift 2 ;;
    --logs) logs=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die 2 "unknown argument '$1' (see --help)" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die 2 "jq is not on PATH."
command -v "$gh_bin" >/dev/null 2>&1 || die 2 "gh is not on PATH."
root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -f "$root/FACTORY.md" ] ||
  die 2 "not a factory repository: no FACTORY.md at the git toplevel."
factory_value() {
  sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "$root/FACTORY.md" | head -1 | sed 's/[[:space:]]\{1,\}#.*$//; s/[[:space:]]*$//'
}
repo=$(factory_value github)
default_branch=$(factory_value default_branch)
review_workflow=$(factory_value review_workflow)
[ -n "$repo" ] || die 2 "FACTORY.md has no repo.github."
[ -z "$threads" ] || [ -d "$threads" ] || die 2 "--threads '$threads' is not a directory."

iso_ok() { date -u -d "$1" +%s >/dev/null 2>&1; }
[ -n "$until" ] || until=$(date -u +%Y-%m-%dT%H:%M:%SZ)
iso_ok "$until" || die 2 "--until '$until' is not a date."
until=$(date -u -d "$until" +%Y-%m-%dT%H:%M:%SZ)
[ -n "$since" ] || since=$(date -u -d "$until - 7 days" +%Y-%m-%dT%H:%M:%SZ)
iso_ok "$since" || die 2 "--since '$since' is not a date."
since=$(date -u -d "$since" +%Y-%m-%dT%H:%M:%SZ)

api() { "$gh_bin" api "$@" 2>/dev/null || die 3 "GitHub read failed: gh api $*"; }

# Merged PRs in the window. Closed PRs sorted by last update, newest first; a PR
# merged in the window was updated at or after `since`, so stop at the first page
# whose oldest entry is older than that.
merged='[]'
page=1
while :; do
  batch=$(api "repos/$repo/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$page") || exit 3
  merged=$(jq -c --argjson m "$merged" --arg s "$since" --arg u "$until" \
    '$m + [.[] | select(.merged_at != null and .merged_at >= $s and .merged_at < $u)
          | {number, title, base: .base.ref, branch: .head.ref, created_at, merged_at}]' <<<"$batch")
  [ "$(jq 'length' <<<"$batch")" -lt 100 ] && break
  [ "$(jq -r --arg s "$since" 'last.updated_at < $s' <<<"$batch")" = true ] && break
  page=$((page + 1))
done

# pr_row <pr-json> — that PR's own numbers, as one JSON object on stdout.
pr_row() {
  local pr=$1 n branch enc window raw runs findings rounds
  n=$(jq -r .number <<<"$pr")
  branch=$(jq -r .branch <<<"$pr")
  # Runs on the branch between opening and merge, so a branch reused by another PR
  # contributes only its own runs. Drafts' runs conclude `skipped` and are dropped.
  enc=$(jq -rn --arg b "$branch" '$b|@uri')
  window=$(jq -r '"\(.created_at)..\(.merged_at)"' <<<"$pr")
  raw=$(api "repos/$repo/actions/runs?event=pull_request&branch=$enc&created=$window&per_page=100") || return 3
  runs=$(jq -c '[.workflow_runs[] | select(.conclusion != "skipped")
                 | {sha: .head_sha, path, name, conclusion, attempt: .run_attempt, created_at}]' <<<"$raw")
  raw=$(api "repos/$repo/pulls/$n/comments?per_page=100") || return 3
  findings=$(jq --arg r "$reviewer" '[.[] | select(.user.login == $r and .in_reply_to_id == null)] | length' <<<"$raw")
  raw=$(api "repos/$repo/issues/$n/comments?per_page=100") || return 3
  rounds=$(jq '[.[] | .body | select(test("<!-- claude-review v1 outcome=findings"))] | length' <<<"$raw")
  jq -c --argjson runs "$runs" --arg wf "$review_workflow" --argjson f "$findings" --argjson rounds "$rounds" '
    ($runs | map(select((.path | split("@")[0]) != $wf))) as $ci
    | ($ci | sort_by(.created_at) | .[0].sha // null) as $first
    | . + {
        ci_runs: ($ci | length),
        first_pass: (if $first == null then null
                     else ($ci | map(select(.sha == $first)) | all(.conclusion == "success" and .attempt == 1)) end),
        failed_first: (if $first == null then [] else
                       [$ci[] | select(.sha == $first and (.conclusion != "success" or .attempt > 1)) | .name] | unique end),
        rework_pushes: (if ($runs | length) == 0 then null else ([$runs[].sha] | unique | length) - 1 end),
        findings: $f,
        findings_rounds: $rounds
      }' <<<"$pr"
}

# Three reads per PR, a few hundred PRs a week: run SCORECARD_JOBS (8) at a time.
rows=$(mktemp -d) || die 2 "cannot make a temp dir."
trap 'rm -rf "$rows"' EXIT
i=0
while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  i=$((i + 1))
  { pr_row "$pr" > "$rows/$i.json" || echo fail > "$rows/$i.fail"; } &
  while [ "$(jobs -rp | wc -l)" -ge "${SCORECARD_JOBS:-8}" ]; do wait -n; done
done < <(jq -c '.[]' <<<"$merged")
wait
compgen -G "$rows/*.fail" >/dev/null && die 3 "a GitHub read failed for at least one PR; numbers would be partial."
prs=$(find "$rows" -name '*.json' -print0 | xargs -0 -r cat | jq -sc 'sort_by(.merged_at) | reverse')

# Usage-window hits in the reviewer's own runs (opt-in: one log download each).
review_hits=null
if [ "$logs" = 1 ] && [ -n "$review_workflow" ]; then
  wf_file=$(basename "$review_workflow")
  review_hits=0
  for job in $(api "repos/$repo/actions/workflows/$wf_file/runs?status=failure&created=$since..$until&per_page=100" |
               jq -r '.workflow_runs[].id' | while read -r id; do
                 api "repos/$repo/actions/runs/$id/jobs" | jq -r '.jobs[] | select(.conclusion == "failure") | .id'
               done); do
    if "$gh_bin" api "repos/$repo/actions/jobs/$job/logs" 2>/dev/null | grep -qiE "$usage_re"; then
      review_hits=$((review_hits + 1))
    fi
  done
fi

# Asks and usage hits from saved project threads.
thread_stats=null
if [ -n "$threads" ]; then
  thread_stats=$(find "$threads" -maxdepth 1 -name '*.json' -print0 | xargs -0 -r cat |
    jq -s --arg s "$since" --arg u "$until" --arg re "$usage_re" '
      # An ask is an agent message or a decision card that the owner answered.
      # A plain agent message is a candidate ask; status cards and activity notes
      # (JSON bodies with a `kind`) are not, except a decision card. The owner
      # answers with a message (pairing with the last candidate since their previous
      # message) or by picking a card option (pairing with that card).
      def cls:
        if .author == "user" then "answer"
        else ((try (.body | fromjson) catch null) as $j
          | if ($j | type) != "object" or $j.kind == null then "ask"
            elif $j.kind == "activity" and $j.tool == "ask_decision" then "card"
            elif $j.kind == "activity" and $j.tool == "decide" and ($j.chosen_by // null) != null then "decide"
            else null end)
        end;
      def secs: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      [ .[] | .thread_id as $tid
        | [ (.messages // []) | sort_by(.created_at)[] | select(.id != $tid)
            | . + {c: cls, dj: (try (.body | fromjson | .decision_id) catch null)}
            | select(.c != null) ] as $m
        | ( [ range(0; $m | length) as $i | select($m[$i].c == "answer")
              | ([range(0; $i) | select($m[.].c == "ask" or $m[.].c == "card")] | last) as $j
              | ([range(0; $i) | select($m[.].c == "answer")] | last // -1) as $p
              | select($j != null and $j > $p)
              | {id: $m[$j].id, asked: $m[$j].created_at, answered: $m[$i].created_at} ]
          + [ $m[] | select(.c == "decide") as $d
              | $m[] | select(.c == "card" and .id == $d.dj)
              | {id, asked: .created_at, answered: $d.created_at} ] )
        | group_by(.id) | map(min_by(.answered))[]
        | select(.asked >= $s and .asked < $u)
      ] as $asks
      | [ .[] | (.messages // [])[] | select(.created_at >= $s and .created_at < $u)
          | select((.body // "") | test($re; "i")) ] as $hits
      | { threads: ([.[] | select(any((.messages // [])[]; .created_at >= $s and .created_at < $u))] | length),
          asks: ($asks | length),
          # Median, not total: a thread left quiet for a day before the owner looks in
          # would swamp a total.
          ask_wait_hours: ([$asks[] | ((.answered | secs) - (.asked | secs)) / 3600] | sort
                           | if length == 0 then null else .[(length / 2 | floor)] * 10 | round / 10 end),
          usage_hits: ($hits | length) }')
fi

jq --arg repo "$repo" --arg s "$since" --arg u "$until" --arg db "$default_branch" \
   --argjson t "$thread_stats" --argjson rh "$review_hits" '
  . as $prs
  | ($prs | map(select(.first_pass != null))) as $ran
  | ($prs | map(select(.rework_pushes != null))) as $rw
  | def ratio(a; b): if b == 0 then null else (a / b * 1000 | round / 1000) end;
  { repo: $repo, since: $s, until: $u,
    partial: ((($u | fromdate) - ($s | fromdate)) < 604800),
    metrics: {
      prs_merged: ($prs | length),
      into_default: ($prs | map(select(.base == $db)) | length),
      first_pass_ci: { passed: ($ran | map(select(.first_pass)) | length), of: ($ran | length),
                       rate: ratio($ran | map(select(.first_pass)) | length; $ran | length) },
      review_findings: { total: ($prs | map(.findings) | add // 0),
                         per_pr: ratio($prs | map(.findings) | add // 0; $prs | length),
                         prs_with_findings: ($prs | map(select(.findings_rounds > 0 or .findings > 0)) | length) },
      rework_pushes: { total: ($rw | map(.rework_pushes) | add // 0),
                       per_pr: ratio($rw | map(.rework_pushes) | add // 0; $rw | length),
                       prs_with_rework: ($rw | map(select(.rework_pushes > 0)) | length) },
      asks_of_owner: (if $t == null or $t.threads == 0 then null else { asks: $t.asks, median_wait_hours: $t.ask_wait_hours, threads_read: $t.threads } end),
      usage_window_hits: (if $t == null and $rh == null then null
                          else { total: (($t.usage_hits // 0) + ($rh // 0)),
                                 threads: ($t.usage_hits // null), review_runs: $rh } end)
    },
    prs: $prs }' <<<"$prs"
