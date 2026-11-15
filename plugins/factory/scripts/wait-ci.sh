#!/usr/bin/env bash
# Block until a pull request's CI checks finish, then exit on the REAL status.
#
# Intended use: one background Bash call with run_in_background=true. It blocks,
# the harness wakes the agent when it exits, and nobody polls or schedules a
# wake-up.
#
#   "${CLAUDE_PLUGIN_ROOT}"/scripts/wait-ci.sh 281
#
# Why it does not simply trust `gh pr checks --watch`: the watch's exit code is a
# WAKE-UP SIGNAL, not a verdict. It has been observed on this repo exiting 0 while
# a Go job was failing. So the watch is used only to block, and the verdict comes
# from a second, authoritative `gh pr checks --json` afterwards, read by bucket
# rather than by exit status.
#
# THIS SCRIPT'S WHOLE JOB IS TO REPORT FAILURE, so it is written to be incapable
# of a silent pass. Three guards in this same change were found to fail open — a
# hook that preferred a local ref over origin/<head>, a port check silently
# disabled by a missing `lsof`, and a Makefile exemption that ran its check anyway
# because each recipe line gets its own shell. The lesson each taught is the same:
# a checker that cannot determine the answer must SAY SO, loudly, and never
# succeed by default.
#
# It therefore exits 0 only when it positively observed at least one check and
# every one of them landed in `pass` or `skipping`. Every other outcome — a
# failing or cancelled check, checks still pending when time ran out, a PR that
# does not exist, a missing gh or jq, an API error, an unparseable response — exits
# non-zero and names what to do about it.
#
# Exit codes:
#   0  every check passed (or was skipped)
#   1  at least one check failed or was cancelled
#   2  usage / environment problem (bad argument, missing gh or jq, unknown repo)
#   3  status could not be determined (API error, unparseable response)
#   4  timed out with checks still pending
#
# "No checks reported" is treated as not-yet-registered rather than as a failure:
# GitHub takes a few seconds after a push to create the check runs, and the watch
# returns immediately in that window. That case re-arms once. If the second
# attempt still reports nothing, it exits non-zero rather than claiming success —
# a PR on which CI never ran is precisely the thing not to wave through.
#
# A check list is only meaningful for a specific commit, and `gh pr checks` is
# addressed by PULL REQUEST with no field naming the commit it reported on. So
# every list read here is put through head-checks-verdict.sh before any verdict
# is drawn from it: the head must not have moved during the watch, and it must
# actually have checks registered against it. Without that, a push whose ref has
# landed but which GitHub has not yet attached to the pull request yields the
# PREVIOUS commit's completed, passing checks — observed on PR #416, reported
# green in 5.5 seconds, for a commit that was no longer the tip. That guard has
# its own re-arm, separate from the one above.
#
# Read-only: it observes checks. It never pushes, merges, comments or closes.
#
# Tunable by environment variable:
#   WAIT_CI_INTERVAL   watch refresh, seconds (default 30)
#   WAIT_CI_TIMEOUT    overall deadline, seconds (default 2700 = 45 min)

set -uo pipefail

# The repository is the one the caller is standing in: its git toplevel, or
# FACTORY_REPO_ROOT when set. This script ships in the factory plugin, so its own
# location says nothing about which repository to query. `gh api
# repos/{owner}/{repo}/…` expands that placeholder from the current directory's
# git remote, so the script enters the resolved root before any query, and it
# refuses a root with no FACTORY.md: a repository that has not joined the factory
# is not one this script should be answering for.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || {
  echo "wait-ci: cannot resolve this script's own directory." >&2
  exit 2
}
repo_root=${FACTORY_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)} || repo_root=""
if [ -z "$repo_root" ] || [ ! -f "$repo_root/FACTORY.md" ]; then
  echo "wait-ci: '${repo_root:-$PWD}' is not a factory repository (no FACTORY.md at its git root) — refusing to query an unknown repository. Run this from inside the repository, or set FACTORY_REPO_ROOT." >&2
  exit 2
fi

# die <exit-code> <message...> — every abort goes through here, so no path can
# fall off the end of the script and inherit a zero status.
die() {
  local code=$1; shift
  for line in "$@"; do echo "wait-ci: $line" >&2; done
  exit "$code"
}

pr=${1-}
case $pr in
  '')       die 2 "usage: wait-ci.sh <pr-number>" ;;
  *[!0-9]*) die 2 "'$pr' is not a pull request number." "usage: wait-ci.sh <pr-number>" ;;
esac

interval=${WAIT_CI_INTERVAL:-30}
timeout=${WAIT_CI_TIMEOUT:-2700}
case $interval in ''|*[!0-9]*) die 2 "WAIT_CI_INTERVAL must be a whole number of seconds, got '$interval'." ;; esac
case $timeout  in ''|*[!0-9]*) die 2 "WAIT_CI_TIMEOUT must be a whole number of seconds, got '$timeout'." ;; esac

command -v gh >/dev/null 2>&1 || die 2 "gh is not on PATH, so CI status cannot be read. Install the GitHub CLI." \
  "Until then, check the PR's Checks tab by hand — do not assume it is green."
command -v jq >/dev/null 2>&1 || die 2 "jq is not on PATH, so the check list cannot be parsed. Install jq."

cd "$repo_root" || die 2 "cannot enter $repo_root"

pr_state=$(gh pr view "$pr" --json state -q .state 2>&1) || die 3 \
  "cannot read PR #$pr — it may not exist, or gh may not be authenticated." \
  "  $pr_state" \
  "Verify with: gh auth status"

# The head branch, so the verdict can be checked against the REF rather than
# against the pull request's own account of itself. headRepositoryOwner and
# headRepository make this correct for a fork PR too, where the branch does not
# live in this repository at all.
head_meta=$(gh pr view "$pr" --json headRefName,headRepositoryOwner,headRepository \
  --jq '[.headRefName, .headRepositoryOwner.login, .headRepository.name] | @tsv' 2>/dev/null || echo "")
head_ref_name=$(printf '%s' "$head_meta" | cut -f1)
head_owner=$(printf '%s' "$head_meta" | cut -f2)
head_repo=$(printf '%s' "$head_meta" | cut -f3)
[ -n "$head_ref_name" ] && [ -n "$head_owner" ] && [ -n "$head_repo" ] || die 3 \
  "cannot read the head branch of PR #$pr, so its checks cannot be attributed to a commit." \
  "Do not treat this as a pass. Verify with: gh pr view $pr --json headRefName,headRepositoryOwner"

# ref_sha — the head branch's actual tip, read from the git ref. This is the
# source of truth the pull request object is compared against; see
# head-checks-verdict.sh for why one gh field cannot validate itself. Read over
# HTTPS rather than with `git ls-remote`, which needs SSH and therefore an agent
# that has failed repeatedly here. Prints 'unknown' when unreadable, never a sha
# it guessed.
ref_sha() {
  local out
  out=$(gh api "repos/$head_owner/$head_repo/git/ref/heads/$head_ref_name" \
          --jq '.object.sha' 2>/dev/null) || out=""
  case $out in
    *[!0-9a-f]*|'') printf 'unknown' ;;
    *)              printf '%s' "$out" ;;
  esac
}

# Captured BEFORE the watch so a push landing mid-watch is detectable.
expected_ref=$(ref_sha)
[ "$expected_ref" != unknown ] || die 3 \
  "cannot read the tip of $head_owner/$head_repo:$head_ref_name, so no check result could be attributed to it." \
  "Do not treat this as a pass. Verify with: gh api repos/$head_owner/$head_repo/git/ref/heads/$head_ref_name"

# registered_for <sha> — how many checks GitHub has registered against a commit,
# counting both Actions check runs and legacy commit statuses. Prints 'unknown'
# when the check-runs API could not be read, so the caller can say so instead of
# assuming zero and reporting a mismatch that may not exist.
registered_for() {
  local sha=$1 cr st
  cr=$(gh api "repos/{owner}/{repo}/commits/$sha/check-runs" --jq '.total_count' 2>/dev/null) || cr=""
  case $cr in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  st=$(gh api "repos/{owner}/{repo}/commits/$sha/status" --jq '.statuses | length' 2>/dev/null) || st=""
  case $st in ''|*[!0-9]*) st=0 ;; esac
  printf '%s' "$((cr + st))"
}

echo "wait-ci: watching checks on PR #$pr (state $pr_state, interval ${interval}s, deadline ${timeout}s)"

watch_log=$(mktemp -t wait-ci) || die 3 "cannot create a temporary file for the watch log."
cleanup() { rm -f "$watch_log"; }
trap cleanup EXIT

started=$(date +%s)

# run_watch — block until the checks settle, bounded by the remaining deadline.
#
# The watch runs in the background and is polled with `kill -0` purely so the
# deadline can be enforced; `timeout(1)` is GNU coreutils and is absent from stock
# macOS, which is exactly the sort of missing-binary assumption that silently
# disabled the port check elsewhere in this change.
#
# Its exit status is deliberately discarded. It is recorded in the log for
# debugging and never consulted for the verdict.
run_watch() {
  local pid elapsed remaining
  remaining=$(( timeout - ($(date +%s) - started) ))
  [ "$remaining" -gt 0 ] || return 1

  gh pr checks "$pr" --watch --interval "$interval" >"$watch_log" 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$(( $(date +%s) - started ))
    if [ "$elapsed" -ge "$timeout" ]; then
      # Reap the watch's own children before it, so nothing is left holding a
      # terminal or a network connection. Real gh is a single process and needs
      # none of this; a wrapper on PATH would.
      command -v pkill >/dev/null 2>&1 && pkill -P "$pid" 2>/dev/null
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 1
    fi
    sleep 2
  done
  wait "$pid" 2>/dev/null
  return 0
}

# The authoritative read. Buckets are gh's own classification of each check and
# are what the verdict is based on.
read_checks() {
  local out
  out=$(gh pr checks "$pr" --json name,bucket,state,link,workflow 2>&1)
  # A missing check list is reported by gh as an error, so the "nothing yet"
  # case has to be recognised from the message rather than from the status.
  case $out in
    *"no checks reported"*) printf '[]'; return 0 ;;
  esac
  if ! printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "wait-ci: could not parse the check list for PR #$pr." >&2
    printf '%s\n' "$out" | head -5 | sed 's/^/  /' >&2
    return 1
  fi
  printf '%s' "$out"
}

attempt=1
max_attempts=2
# The attribution guard gets its own budget so a slow head update cannot consume
# the re-arm the pending path needs, and vice versa.
sha_attempt=1
sha_max_attempts=2

while : ; do
  timed_out=no
  if ! run_watch; then
    timed_out=yes
  fi

  checks=$(read_checks) || die 3 "the check list for PR #$pr could not be read, so its status is unknown." \
    "Do not treat this as a pass. Inspect by hand: gh pr checks $pr"

  # A deadline that expires while checks are genuinely outstanding is a real
  # timeout. One that expires after they have all settled is not — the answer is
  # available, so report it rather than an alarm. Either way the verdict comes
  # from the buckets below, never from having waited.
  if [ "$timed_out" = yes ]; then
    still=$(printf '%s' "$checks" | jq -r '[.[] | select(.bucket == "pending") | .name] | join(", ")')
    if [ -n "$still" ]; then
      die 4 "timed out after ${timeout}s with checks still running: $still." \
        "Status is NOT green — it is unfinished. Re-run this script, or inspect: gh pr checks $pr"
    fi
  fi

  total=$(printf '%s' "$checks" | jq 'length')
  case $total in ''|*[!0-9]*) die 3 "unexpected check-list length '$total' for PR #$pr." ;; esac

  if [ "$total" -eq 0 ]; then
    if [ "$attempt" -lt "$max_attempts" ]; then
      echo "wait-ci: no checks reported yet on PR #$pr — GitHub may not have registered them. Re-arming once in ${interval}s."
      attempt=$((attempt + 1))
      sleep "$interval"
      continue
    fi
    die 3 "no checks reported on PR #$pr after $max_attempts attempts." \
      "CI has not run on this head commit, so there is nothing green about it." \
      "Check the workflow triggers and that the branch is pushed: gh pr checks $pr"
  fi

  # ATTRIBUTION. The list just read is addressed by pull request, not by commit,
  # so before any verdict is drawn from it, confirm it describes the commit that
  # would actually be merged. Three shas, because the pull request object cannot
  # be used to validate itself — head-checks-verdict.sh explains why the first
  # version of this guard would not have caught the incident it was written for.
  current_ref=$(ref_sha)
  pr_head=$(gh pr view "$pr" --json headRefOid --jq .headRefOid 2>/dev/null || echo "unknown")
  registered=$(registered_for "$current_ref")
  # Capture with `|| rc=$?` and NOT with `if ! cmd; then rc=$?`. In bash, `!`
  # negates the status to a plain boolean, and that negated value — 0 — is what
  # `$?` reads inside the `then` block, so the wrapped command's own 1-vs-2 is
  # lost. Shipped that way once: it made every mismatch hard-fail immediately
  # and the re-arm below unreachable, which is the opposite of the intent.
  rc=0
  "$here/head-checks-verdict.sh" \
    "$expected_ref" "$current_ref" "$pr_head" "$total" "$registered" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -ne 1 ]; then
      die 3 "the check list for PR #$pr could not be attributed to the branch tip, so its status is unknown." \
        "Do not treat this as a pass. Inspect by hand: gh pr checks $pr"
    fi
    if [ "$sha_attempt" -lt "$sha_max_attempts" ]; then
      echo "wait-ci: re-arming in ${interval}s for the reason above — GitHub needs a moment to attach a push to the pull request."
      sha_attempt=$((sha_attempt + 1))
      expected_ref=$current_ref
      sleep "$interval"
      continue
    fi
    die 3 "the checks reported for PR #$pr still do not describe the branch tip after $sha_max_attempts attempts." \
      "CI has not run on the commit you would merge, so there is nothing green about it." \
      "Compare by hand: gh pr view $pr --json headRefOid and gh api repos/$head_owner/$head_repo/git/ref/heads/$head_ref_name"
  fi
  # From here the tip, the pull request's head and the check list all agree.
  head_sha=$current_ref

  # Still pending after the watch returned means the watch came back early — the
  # documented unreliability, caught here rather than believed.
  n_pending=$(printf '%s' "$checks" | jq '[.[] | select(.bucket == "pending")] | length')
  if [ "$n_pending" -gt 0 ] && [ "$attempt" -lt "$max_attempts" ]; then
    echo "wait-ci: the watch returned while $n_pending check(s) are still pending — re-arming."
    attempt=$((attempt + 1))
    continue
  fi
  break
done

n_fail=$(printf '%s' "$checks" | jq '[.[] | select(.bucket == "fail")] | length')
n_cancel=$(printf '%s' "$checks" | jq '[.[] | select(.bucket == "cancel")] | length')
n_pass=$(printf '%s' "$checks" | jq '[.[] | select(.bucket == "pass")] | length')
n_skip=$(printf '%s' "$checks" | jq '[.[] | select(.bucket == "skipping")] | length')

echo
printf '%s' "$checks" | jq -r '.[] | "  \(.bucket | ascii_upcase)\t\(.name)\t\(.link // "")"' | sort
echo
echo "wait-ci: PR #$pr — $total check(s): $n_pass pass, $n_fail fail, $n_cancel cancelled, $n_skip skipped, $n_pending pending"

if [ "$n_fail" -gt 0 ] || [ "$n_cancel" -gt 0 ]; then
  echo
  printf '%s' "$checks" | jq -r '.[] | select(.bucket == "fail" or .bucket == "cancel")
    | "FAILED  \(.name)  [\(.state)]\n        \(.link // "")"' >&2
  die 1 "CI is NOT green on PR #$pr." \
    "Inspect the failure with: gh run view --log-failed" \
    "Root-cause it, fix, commit and push — then re-run this script."
fi

# Pending here means the re-arm was already spent, so this is an honest unknown.
if [ "$n_pending" -gt 0 ]; then
  die 4 "$n_pending check(s) are still pending on PR #$pr after $max_attempts attempts." \
    "The status is unfinished, not green. Re-run this script."
fi

if [ "$n_pass" -eq 0 ]; then
  # Everything skipped. Determined, but nothing was actually verified, so say so
  # rather than letting a bare "all checks passed" imply coverage that never ran.
  echo "wait-ci: WARNING — all $total check(s) were skipped; no job actually ran on this commit."
  echo "wait-ci: verify the workflow path filters really do exclude this change before merging."
fi

echo "wait-ci: all checks passed on PR #$pr (commit ${head_sha:0:8})."

# Green means a review was RECORDED, not that it found nothing — so say which.
# The verdict logic lives in review-verdict.sh so its fixture test exercises the
# same file that runs here; see that script's header for why.
#
# $head_sha is the one the attribution guard above confirmed the CI verdict
# belongs to, so the review verdict is judged against the same commit. It used
# to be re-fetched here, which could disagree with the checks just reported if
# the head moved in between — the CI half and the review half then described
# different commits.
# grep the marker OUT of the body rather than taking the body's last line: these
# summaries end with a trailing newline, so `tail -1` yields an empty string and
# every PR would be reported unreviewed. Fail-closed, but wrong.
marker=$(gh api "repos/{owner}/{repo}/issues/$pr/comments" --paginate \
  --jq '.[].body | select(contains("<!-- claude-review v1"))' 2>/dev/null \
  | grep -o '<!-- claude-review v1[^>]*' | tail -1)

# Advisory only: a review verdict never changes this script's exit code, which
# reports CI status and nothing else.
"$here/review-verdict.sh" "$head_sha" "$marker" "$pr" || true
exit 0
