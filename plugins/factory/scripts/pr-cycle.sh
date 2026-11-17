#!/usr/bin/env bash
# The factory's pull-request cycle as one script: gate, open a draft, mark ready,
# wait for CI, read the review verdict, merge. The skills call its subcommands
# instead of spelling out the gh steps, so the order and the guards live in one
# place and cannot drift between execute-issue and implement-feature.
#
#   pr-cycle.sh gate                                   run FACTORY.md's gate, stamp HEAD on green
#   pr-cycle.sh open  [--base B] --title T --body-file F   push, open a DRAFT PR, print its number
#   pr-cycle.sh ready <n>                              mark ready (needs a gate stamp for HEAD)
#   pr-cycle.sh wait  <n>                              block until CI settles; exit code is the verdict
#   pr-cycle.sh ship  <n>                              ready, then wait (run it backgrounded)
#   pr-cycle.sh unready <n>                            back to draft, to push fixes
#   pr-cycle.sh merge <n> [--dispositioned] [--delete-branch]
#                                                      merge once required checks are green and reviewed
#
# WHY REST ONLY. Cloud sessions get HTTP 403 on GitHub GraphQL, and `gh pr view`,
# `gh pr checks`, `gh pr create` and `gh pr ready` are all GraphQL. Every read and
# write here is `gh api` REST, so the same script works on the Mac and in the cloud.
# The one write REST has no route for, draft <-> ready, tries `gh pr ready` first
# and falls back to the cloud proxy's `ccr/ready_for_review` / `ccr/convert_to_draft`.
#
# WHY THE HOOKS ARE CALLED BY HAND. PreToolUse hooks see only the outer command,
# `pr-cycle.sh open ...`, never the PR creation inside it. So `open` pipes the same
# payloads to deny-stale-pr.sh and deny-ai-attribution.sh itself and stops on a deny.
# The ready-gate hook (deny-unverified-ready.sh, if present) matches `pr-cycle.sh
# ready|ship` directly; `ready` also refuses on its own without a gate stamp, so the
# rule holds whichever of the two is installed.
#
# GATE STAMP. `ready` requires a green gate for exactly the tree that is pushed,
# checked rather than remembered. The stamp belongs to gate-stamp.sh: when it
# exists, `gate` calls `gate-stamp.sh --record` after a green run and `ready` calls
# `gate-stamp.sh --check`. Until it lands, this script writes and reads the same
# stamp itself, `$(git rev-parse --git-common-dir)/factory/gate-<HEAD^{tree}>`, keyed
# by tree in the shared git dir so a gate run in another worktree on the same tree
# counts. Never a silent pass: no stamp, no ready.
#
# FIX ROUNDS. `wait` counts CI failures per PR in `<git-dir>/factory/pr-<n>-ci-fails`
# and resets on green. Up to PR_CYCLE_MAX_FIX_ROUNDS (default 2) failures exit 1:
# root-cause, fix, `unready`, push, `ship` again. The next failure exits 6: stop and
# ask the user, with what failed and what was tried.
#
# Exit codes (every subcommand):
#   0  done / green
#   1  CI failed; a fix round is still allowed
#   2  usage or environment problem
#   3  status could not be determined (API error) — never treat as green
#   4  timed out with checks still pending
#   5  refused: a precondition failed (no gate stamp, dirty tree, behind base,
#      unreviewed, spec PR, hook deny) — the message says what to do
#   6  CI failed and the fix-round cap is reached: ask the user
#
# Tunables: PR_CYCLE_INTERVAL (poll seconds, 30), PR_CYCLE_TIMEOUT (seconds, 2700),
# PR_CYCLE_MAX_FIX_ROUNDS (2). PR_CYCLE_GH overrides the gh binary (tests only).

set -uo pipefail

gh_bin=${PR_CYCLE_GH:-gh}

die() {
  local code=$1; shift
  for line in "$@"; do echo "pr-cycle: $line" >&2; done
  exit "$code"
}
say() { echo "pr-cycle: $*"; }

command -v jq >/dev/null 2>&1 || die 2 "jq is not on PATH."
command -v "$gh_bin" >/dev/null 2>&1 || die 2 "gh is not on PATH."

# The repo is the caller's git toplevel, not this script's location, so the same
# script works when it ships in a plugin.
root=$(git rev-parse --show-toplevel 2>/dev/null) || die 2 "not inside a git work tree."
# Sibling scripts and hooks are this plugin's own, found beside this script.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || die 2 "cannot resolve the script's directory."
hooks_dir=$(cd "$here/../hooks" && pwd) || die 2 "cannot find the plugin's hooks beside $here."
git_dir=$(git rev-parse --absolute-git-dir) || die 2 "cannot resolve the git dir."
common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd) || die 2 "cannot resolve the common git dir."
state_dir="$git_dir/factory"
stamp_tool="$here/gate-stamp.sh"
factory_md="$root/FACTORY.md"
[ -f "$factory_md" ] || die 2 "$factory_md is missing; the factory needs this repo's contract."

# factory_value <key> — the first `key: value` in FACTORY.md's contract, with any
# trailing `# comment` removed. Values in this file never contain ' #'.
factory_value() {
  sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "$factory_md" | head -1 | sed 's/[[:space:]]\{1,\}#.*$//; s/[[:space:]]*$//'
}

repo_slug=$(factory_value github)
default_branch=$(factory_value default_branch)
spec_prefix=$(factory_value spec_branch | sed 's/<.*//')
[ -n "$repo_slug" ] && [ -n "$default_branch" ] || die 2 "FACTORY.md has no repo.github or repo.default_branch."

api() { "$gh_bin" api "$@"; }

need_pr() {
  case ${1-} in
    ''|*[!0-9]*) die 2 "usage: pr-cycle.sh $sub <pr-number>" ;;
  esac
}

# pr_json <n> — the pull request object over REST.
pr_json() {
  local out
  out=$(api "repos/$repo_slug/pulls/$1" 2>&1) || die 3 "cannot read PR #$1: $out"
  printf '%s' "$out" | jq -e '.number' >/dev/null 2>&1 || die 3 "unexpected response for PR #$1."
  printf '%s' "$out"
}

stamp_record() {
  if [ -x "$stamp_tool" ]; then "$stamp_tool" --record --dir "$root"; return; fi
  mkdir -p "$common_dir/factory" && git -C "$root" rev-parse HEAD >"$common_dir/factory/gate-$(git -C "$root" rev-parse 'HEAD^{tree}')"
}
# stamp_check — 0 when a green gate is stamped for HEAD's tree and the tree is clean.
stamp_check() {
  if [ -x "$stamp_tool" ]; then "$stamp_tool" --check --dir "$root"; return; fi
  tree_clean && [ -f "$common_dir/factory/gate-$(git -C "$root" rev-parse 'HEAD^{tree}')" ]
}

tree_clean() { [ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ]; }

# --- check classification -------------------------------------------------
# Both filters take the raw REST payloads and are the only place buckets are
# decided, so check-pr-cycle.sh runs them through real jq against fixtures.
#
# Latest run per check name only: a re-run leaves the old failed run in the list.
# shellcheck disable=SC2016
runs_filter='
  [.check_runs[]] | group_by(.name) | map(max_by(.id)) | map({
    name,
    bucket: (if .status != "completed" then "pending"
             elif (.conclusion == "success" or .conclusion == "neutral") then "pass"
             elif .conclusion == "skipped" then "skipping"
             elif .conclusion == "cancelled" then "cancel"
             else "fail" end),
    link: .html_url
  })'
# shellcheck disable=SC2016
status_filter='
  [.statuses[]] | group_by(.context) | map(max_by(.id)) | map({
    name: .context,
    bucket: (if .state == "pending" then "pending"
             elif .state == "success" then "pass"
             else "fail" end),
    link: .target_url
  })'

# none: no run on the commit has actually run (only draft-time skips, or nothing
# yet); running: a run is still going; settled: every run completed, one for real.
# shellcheck disable=SC2016
workflow_filter='
  [.workflow_runs[]] as $w
  | if ([$w[] | select(.conclusion != "skipped")] | length) == 0 then "none"
    elif ([$w[] | select(.status != "completed")] | length) > 0 then "running"
    else "settled" end'

# checks_for <sha> — one JSON array of {name,bucket,link} for the commit.
checks_for() {
  local runs statuses
  runs=$(api "repos/$repo_slug/commits/$1/check-runs?per_page=100" 2>/dev/null) || return 1
  statuses=$(api "repos/$repo_slug/commits/$1/status?per_page=100" 2>/dev/null) || statuses='{"statuses":[]}'
  jq -n --argjson r "$runs" --argjson s "$statuses" \
    "(\$r | $runs_filter) + (\$s | $status_filter)" 2>/dev/null
}

# review_marker <n> — the last claude-review marker on the PR, or empty.
review_marker() {
  api "repos/$repo_slug/issues/$1/comments?per_page=100" --paginate \
    --jq '.[].body | select(contains("<!-- claude-review v1"))' 2>/dev/null \
    | grep -o '<!-- claude-review v1[^>]*' | tail -1
}

set_draft() { # <n> ready|draft
  local n=$1 want=$2 out
  if [ "$want" = ready ]; then
    out=$("$gh_bin" pr ready "$n" 2>&1) && { say "PR #$n marked ready."; return 0; }
    out=$(api -X POST "repos/$repo_slug/pulls/$n/ccr/ready_for_review" 2>&1) && { say "PR #$n marked ready."; return 0; }
  else
    out=$("$gh_bin" pr ready --undo "$n" 2>&1) && { say "PR #$n is a draft again."; return 0; }
    out=$(api -X POST "repos/$repo_slug/pulls/$n/ccr/convert_to_draft" 2>&1) && { say "PR #$n is a draft again."; return 0; }
  fi
  die 3 "could not change PR #$n to $want: $out" \
    "Use the GitHub connector's update_pull_request (draft: $([ "$want" = ready ] && echo false || echo true)) instead."
}

# hook_check <hook> <payload> — run a repo hook as Claude Code would; a deny stops us.
hook_check() {
  local hook="$hooks_dir/$1" out
  [ -x "$hook" ] || return 0
  out=$(printf '%s' "$2" | "$hook" 2>&1)
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    die 5 "$1 refused: $(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null || printf '%s' "$out")"
  fi
}

# --- subcommands -----------------------------------------------------------

cmd_gate() {
  local gate cwd head
  gate=$(factory_value gate)
  cwd=$(factory_value cwd)
  [ -n "$gate" ] || die 2 "FACTORY.md has no commands.gate."
  tree_clean || die 5 "the working tree has uncommitted changes; commit them first, so the stamp describes a commit."
  head=$(git -C "$root" rev-parse HEAD)
  say "gate on ${head:0:8}: $gate (in ${cwd:-.})"
  ( cd "$root/${cwd:-.}" && bash -c "$gate" ) || die 1 "the gate failed on ${head:0:8}. Fix it before opening or marking ready."
  [ "$(git -C "$root" rev-parse HEAD)" = "$head" ] && tree_clean \
    || die 5 "HEAD or the tree changed while the gate ran; run it again."
  stamp_record || die 3 "cannot record the gate stamp."
  say "gate green on ${head:0:8}; stamped."
}

cmd_open() {
  local base=$default_branch title='' body_file='' branch existing out n
  while [ $# -gt 0 ]; do
    case $1 in
      --base) base=${2-}; shift 2 ;;
      --title) title=${2-}; shift 2 ;;
      --body-file) body_file=${2-}; shift 2 ;;
      *) die 2 "open: unknown argument '$1'." ;;
    esac
  done
  [ -n "$title" ] && [ -f "$body_file" ] || die 2 "usage: pr-cycle.sh open [--base B] --title T --body-file F"
  branch=$(git -C "$root" branch --show-current)
  [ -n "$branch" ] && [ "$branch" != "$base" ] && [ "$branch" != "$default_branch" ] \
    || die 5 "open from a work branch, not '${branch:-detached HEAD}'."
  tree_clean || die 5 "uncommitted changes; commit or stash them first."

  git -C "$root" fetch -q origin "$base" || die 3 "cannot fetch origin/$base."
  git -C "$root" merge-base --is-ancestor "origin/$base" HEAD \
    || die 5 "$branch is behind origin/$base. Merge it (git merge origin/$base), re-run the gate, then open."

  hook_check deny-ai-attribution.sh "$(jq -n --arg c "gh pr create --title x --body-file $body_file" '{tool_input:{command:$c}}')"
  printf '%s\n' "$title" | grep -qiE 'generated with claude|co-?authored-by|in collaboration with claude' \
    && [ "$(factory_value ai_attribution)" = deny ] && die 5 "the title carries an AI-attribution phrase."

  git -C "$root" push -q -u origin "$branch" || die 3 "push of $branch failed; fix the push before opening anything."
  hook_check deny-stale-pr.sh "$(jq -n --arg c "gh pr create --base $base --head $branch" --arg d "$root" '{cwd:$d,tool_input:{command:$c}}')"

  existing=$(api "repos/$repo_slug/pulls?head=${repo_slug%%/*}:$branch&state=open" --jq '.[0].number // empty' 2>/dev/null)
  if [ -n "$existing" ]; then
    say "PR #$existing is already open for $branch; reusing it."
    echo "$existing"; return 0
  fi
  out=$(api -X POST "repos/$repo_slug/pulls" -f title="$title" -f head="$branch" -f base="$base" \
          -F draft=true -F body=@"$body_file" 2>&1) || die 3 "PR create failed: $out"
  n=$(printf '%s' "$out" | jq -r '.number // empty')
  [ -n "$n" ] || die 3 "PR create returned no number: $out"
  say "opened draft PR #$n ($branch -> $base): $(printf '%s' "$out" | jq -r .html_url)"
  echo "$n"
}

cmd_ready() {
  local n=$1 pr head base pr_head
  pr=$(pr_json "$n")
  [ "$(printf '%s' "$pr" | jq -r .state)" = open ] || die 5 "PR #$n is not open."
  head=$(git -C "$root" rev-parse HEAD)
  pr_head=$(printf '%s' "$pr" | jq -r .head.sha)
  base=$(printf '%s' "$pr" | jq -r .base.ref)
  tree_clean || die 5 "uncommitted changes: the gate stamp would not describe what is pushed."
  [ "$pr_head" = "$head" ] || die 5 "PR #$n's head is ${pr_head:0:8} but local HEAD is ${head:0:8}. Push (or pull) so they match."
  git -C "$root" fetch -q origin "$base" || die 3 "cannot fetch origin/$base."
  git -C "$root" merge-base --is-ancestor "origin/$base" HEAD \
    || die 5 "behind origin/$base. Mark draft, merge the base, re-run the gate, push, then ready."
  stamp_check || die 5 "no green gate for ${head:0:8}'s tree. Run: $here/pr-cycle.sh gate"
  if [ "$(printf '%s' "$pr" | jq -r .draft)" != true ]; then
    say "PR #$n is already ready."; return 0
  fi
  set_draft "$n" ready
}

cmd_unready() {
  local n=$1
  [ "$(pr_json "$n" | jq -r .draft)" = true ] && { say "PR #$n is already a draft."; return 0; }
  set_draft "$n" draft
}

cmd_wait() {
  local n=$1 interval=${PR_CYCLE_INTERVAL:-30} timeout=${PR_CYCLE_TIMEOUT:-2700}
  local max=${PR_CYCLE_MAX_FIX_ROUNDS:-2} started pr wf sha sha2 checks total pending fails fail_file count marker empty=0
  case "$interval$timeout$max" in *[!0-9]*) die 2 "PR_CYCLE_INTERVAL, _TIMEOUT and _MAX_FIX_ROUNDS must be whole numbers." ;; esac
  started=$(date +%s)
  pr=$(pr_json "$n")
  [ "$(printf '%s' "$pr" | jq -r .draft)" = true ] \
    && die 5 "PR #$n is a draft, and CI skips drafts. Mark it ready first: pr-cycle.sh ship $n"
  sha=$(printf '%s' "$pr" | jq -r .head.sha)
  say "waiting on PR #$n at ${sha:0:8} (every ${interval}s, deadline ${timeout}s)"
  while : ; do
    # Workflow runs first. While a PR was a draft every run on this commit
    # completed as `skipped`, and the run that marking ready starts takes a few
    # seconds to register. Reading check runs alone in that window reports the
    # draft's skips as green. So wait until at least one run actually ran and
    # every run on the commit has completed.
    wf=$(api "repos/$repo_slug/actions/runs?head_sha=$sha&per_page=100" \
           --jq "$workflow_filter" 2>/dev/null) || die 3 "cannot read workflow runs for ${sha:0:8}."
    checks=$(checks_for "$sha") || die 3 "cannot read checks for ${sha:0:8}. Do not treat this as a pass."
    total=$(printf '%s' "$checks" | jq length)
    pending=$(printf '%s' "$checks" | jq '[.[] | select(.bucket == "pending")] | length')
    if [ "$wf" = settled ] && [ "$pending" -eq 0 ]; then
      [ "$total" -gt 0 ] || die 3 "every workflow run on ${sha:0:8} finished but reported no checks; nothing is green."
      break
    fi
    if [ "$wf" = none ]; then
      empty=$((empty + 1))
      [ "$empty" -le 4 ] || die 3 "no workflow run has actually run on ${sha:0:8}. CI has not tested it; nothing is green."
    fi
    [ $(( $(date +%s) - started )) -lt "$timeout" ] \
      || die 4 "timed out with checks pending: $(printf '%s' "$checks" | jq -r '[.[] | select(.bucket=="pending") | .name] | join(", ")')."
    sleep "$interval"
  done
  sha2=$(pr_json "$n" | jq -r .head.sha)
  [ "$sha2" = "$sha" ] || die 3 "PR #$n's head moved to ${sha2:0:8} during the wait; these checks describe ${sha:0:8}. Run wait again."

  printf '%s' "$checks" | jq -r '.[] | "  \(.bucket | ascii_upcase)\t\(.name)\t\(.link // "")"' | sort
  fails=$(printf '%s' "$checks" | jq '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | length')
  mkdir -p "$state_dir"; fail_file="$state_dir/pr-$n-ci-fails"
  if [ "$fails" -gt 0 ]; then
    count=$(( $(cat "$fail_file" 2>/dev/null || echo 0) + 1 ))
    echo "$count" >"$fail_file"
    if [ "$count" -gt "$max" ]; then
      die 6 "CI failed on PR #$n for the $count time; the cap is $max fix rounds." \
        "Stop and ask the user: name the failing checks, the root cause you found, and what each round tried."
    fi
    die 1 "CI is NOT green on PR #$n (failure $count of $max allowed fix rounds)." \
      "Root-cause it (gh run view <id> --log-failed), fix, then: pr-cycle.sh unready $n; push; pr-cycle.sh gate; pr-cycle.sh ship $n"
  fi
  rm -f "$fail_file"
  [ "$(printf '%s' "$checks" | jq '[.[] | select(.bucket == "pass")] | length')" -gt 0 ] \
    || say "WARNING: every check was skipped on ${sha:0:8}; nothing actually ran."
  say "all checks passed on PR #$n (${sha:0:8})."
  # Advisory, as in wait-ci.sh: findings are never a gate here, but merge reads them.
  marker=$(review_marker "$n")
  "$here/review-verdict.sh" "$sha" "$marker" "$n" || true
  return 0
}

cmd_merge() {
  local n=$1 dispositioned=no delete_branch=no pr sha head_ref base required checks missing verdict_rc out
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --dispositioned) dispositioned=yes ;;
      --delete-branch) delete_branch=yes ;;
      *) die 2 "merge: unknown argument '$1'." ;;
    esac
    shift
  done
  pr=$(pr_json "$n")
  sha=$(printf '%s' "$pr" | jq -r .head.sha)
  head_ref=$(printf '%s' "$pr" | jq -r .head.ref)
  base=$(printf '%s' "$pr" | jq -r .base.ref)
  [ "$(printf '%s' "$pr" | jq -r .state)" = open ] || die 5 "PR #$n is not open."
  [ "$(printf '%s' "$pr" | jq -r .draft)" = true ] && die 5 "PR #$n is a draft; ship it first."
  if [ -n "$spec_prefix" ] && [ "${head_ref#"$spec_prefix"}" != "$head_ref" ]; then
    die 5 "PR #$n is a spec PR ($head_ref). The repo owner merges those, never an agent."
  fi

  # Required checks come from the base branch's ruleset, so this follows the
  # ruleset rather than a list copied into a script.
  required=$(api "repos/$repo_slug/rules/branches/$base" \
    --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]' 2>/dev/null) \
    || die 3 "cannot read the rules for $base."
  checks=$(checks_for "$sha") || die 3 "cannot read checks for ${sha:0:8}."
  missing=$(jq -rn --argjson req "$required" --argjson c "$checks" \
    '$req - [$c[] | select(.bucket == "pass" or .bucket == "skipping") | .name] | join(", ")')
  [ -z "$missing" ] || die 5 "required checks not green on ${sha:0:8}: $missing. Run: pr-cycle.sh wait $n"

  verdict_rc=0
  "$here/review-verdict.sh" "$sha" "$(review_marker "$n")" "$n" >/dev/null || verdict_rc=$?
  case $verdict_rc in
    0) ;;
    1) [ "$dispositioned" = yes ] || die 5 "the review of ${sha:0:8} has findings. Read them ($here/pr-review-comments.sh $n)," \
         "reply to each (fixed with commit / not needed with evidence / question), then merge with --dispositioned." ;;
    *) die 5 "no review recorded for ${sha:0:8}. Do not merge an unreviewed head." ;;
  esac

  out=$(api -X PUT "repos/$repo_slug/pulls/$n/merge" -f merge_method=merge -f sha="$sha" 2>&1) \
    || die 3 "merge of PR #$n failed: $out"
  say "merged PR #$n ($head_ref -> $base) at ${sha:0:8}."
  if [ "$delete_branch" = yes ]; then
    api -X DELETE "repos/$repo_slug/git/refs/heads/$head_ref" >/dev/null 2>&1 \
      && say "deleted branch $head_ref." || say "could not delete branch $head_ref; delete it by hand."
  fi
  [ "$base" = "$default_branch" ] && say "merging to $default_branch deploys; confirm the deploy run's image tag matches the merge commit."
  return 0
}

sub=${1-}
[ $# -gt 0 ] && shift
case $sub in
  gate)    cmd_gate ;;
  open)    cmd_open "$@" ;;
  ready)   need_pr "${1-}"; cmd_ready "$1" ;;
  unready) need_pr "${1-}"; cmd_unready "$1" ;;
  wait)    need_pr "${1-}"; cmd_wait "$1" ;;
  ship)    need_pr "${1-}"; cmd_ready "$1" && cmd_wait "$1" ;;
  merge)   need_pr "${1-}"; cmd_merge "$@" ;;
  *) die 2 "usage: pr-cycle.sh gate | open [--base B] --title T --body-file F | ready|unready|wait|ship <n> | merge <n> [--dispositioned] [--delete-branch]" ;;
esac
