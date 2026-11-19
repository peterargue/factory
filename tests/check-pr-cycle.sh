#!/usr/bin/env bash
# Fixture-test pr-cycle.sh's refusals and verdicts against a throwaway repo.
#
# gh is replaced by a stub that serves fixture JSON per REST path and runs every
# `--jq` filter through REAL jq, so the filters the script ships are the ones
# tested (the lesson of check-review-queries.sh). The stub also makes `gh pr
# ready` fail with the cloud's GraphQL 403, so the ccr fallback is exercised.
#
# What must hold, because each is a "no" that could quietly become a "yes":
#   - ready refuses with no gate stamp, and passes once `gate` is green
#   - a failing gate writes no stamp
#   - a re-run that passed supersedes the earlier failed run of the same check
#   - wait/status exit 1, 1, then 6 on distinct repeated failures, a red result
#     read twice counts once, and green resets the count
#   - status never sleeps: not-settled is exit 7, not a wait
#   - ship returns after marking ready and attended; ship --wait still blocks
#   - merge refuses a spec PR, a missing required check, and unanswered findings
#
#   tests/check-pr-cycle.sh

set -uo pipefail

here=$(cd -- "$(dirname -- "$0")/../plugins/factory/scripts" && pwd -P)
script="$here/pr-cycle.sh"
[ -x "$script" ] || { echo "check-pr-cycle: $script is missing or not executable" >&2; exit 2; }

work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
fix="$work/fix"; mkdir -p "$fix" "$work/bin"
fails=0

# --- stub gh ---------------------------------------------------------------
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
fix=$FIXDIR
if [ "$1" = pr ]; then echo "$*" >>"$fix/calls"; echo "HTTP 403: GitHub GraphQL is not available" >&2; exit 1; fi
[ "$1" = api ] || exit 2
shift
method=GET path='' jqf=''
while [ $# -gt 0 ]; do
  case $1 in
    -X) method=$2; shift 2 ;;
    -f|-F) shift 2 ;;
    --jq) jqf=$2; shift 2 ;;
    --paginate) shift ;;
    *) path=$1; shift ;;
  esac
done
key=$(printf '%s' "$path" | tr '/?&=:' '_____')
if [ "$method" != GET ]; then echo "$method $path" >>"$fix/calls"; fi
f="$fix/$method-$key.json"; [ -f "$f" ] || f="$fix/$key.json"
[ -f "$f" ] || { [ "$method" != GET ] && { echo '{}'; exit 0; }; echo "stub: no fixture $f" >&2; exit 1; }
if [ -n "$jqf" ]; then jq -r "$jqf" "$f"; else cat "$f"; fi
STUB
chmod +x "$work/bin/gh"
# Isolate from the caller's git config (push negotiation, hooks, signing).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export PR_CYCLE_GH="$work/bin/gh" FIXDIR="$fix" PR_CYCLE_INTERVAL=0 PR_CYCLE_TIMEOUT=5

# --- throwaway repo with an origin -------------------------------------------
git init -q --bare "$work/origin.git"
repo="$work/repo"
git init -q -b main "$repo"
cd "$repo" || exit 2
git config user.email t@example.com; git config user.name t
cat >FACTORY.md <<'EOF'
repo:
  github: acme/widget
  default_branch: main
  ai_attribution: deny
specs:
  spec_branch: spec/<change-name>
commands:
  cwd: .
  gate: test ! -e GATE_FAILS   # a comment the parser must drop
EOF
git add -A && git commit -qm init
git remote add origin "$work/origin.git" && git push -q origin main
git switch -qc work && echo x >x && git add x && git commit -qm x && git push -q -u origin work 2>/dev/null
sha=$(git rev-parse HEAD)

run() { "$script" "$@" >"$work/out" 2>&1; echo $?; }
expect() { # label want got
  if [ "$2" != "$3" ]; then echo "FAIL [$1] exit $3, want $2"; sed 's/^/    /' "$work/out"; fails=$((fails + 1)); else echo "ok   [$1]"; fi
}
pr_fixture() { # draft head_ref
  jq -n --arg s "$sha" --argjson d "$1" --arg h "$2" \
    '{number:7,state:"open",draft:$d,head:{sha:$s,ref:$h},base:{ref:"main"}}' >"$fix/repos_acme_widget_pulls_7.json"
}
runs() { printf '{"check_runs":%s}' "$1" >"$fix/repos_acme_widget_commits_${sha}_check-runs_per_page_100.json"; }
wfruns() { printf '{"workflow_runs":%s}' "$1" >"$fix/repos_acme_widget_actions_runs_head_sha_${sha}_per_page_100.json"; }
echo '{"statuses":[]}' >"$fix/repos_acme_widget_commits_${sha}_status_per_page_100.json"
echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Go"},{"context":"Claude review"}]}}]' \
  >"$fix/repos_acme_widget_rules_branches_main.json"
review() { printf '[{"body":"summary\\n<!-- claude-review v1 outcome=%s sha=%s -->\\n"}]' "$1" "$sha" \
  >"$fix/repos_acme_widget_issues_7_comments_per_page_100.json"; }

# --- ready / gate ------------------------------------------------------------
pr_fixture true work
expect "ready refuses without a gate stamp" 5 "$(run ready 7)"
touch GATE_FAILS
expect "gate refuses a dirty tree" 5 "$(run gate)"
git add GATE_FAILS && git commit -qm f && git push -q
sha=$(git rev-parse HEAD); pr_fixture true work
expect "a failing gate exits 1" 1 "$(run gate)"
expect "a failing gate leaves no stamp" 5 "$(run ready 7)"
git rm -q GATE_FAILS && git commit -qm g && git push -q
sha=$(git rev-parse HEAD); pr_fixture true work
echo '{"statuses":[]}' >"$fix/repos_acme_widget_commits_${sha}_status_per_page_100.json"
expect "gate green" 0 "$(run gate)"
expect "ready after a green gate" 0 "$(run ready 7)"
grep -q "POST repos/acme/widget/pulls/7/ccr/ready_for_review" "$fix/calls" \
  && echo "ok   [ready falls back to the ccr route]" || { echo "FAIL [ready falls back to the ccr route]"; fails=$((fails + 1)); }
echo y >y && git add y && git commit -qm y && git push -q
pr_fixture true work; sha_old=$sha; sha=$(git rev-parse HEAD); pr_fixture true work
expect "a new commit needs a new gate" 5 "$(run ready 7)"
git reset -q --hard "$sha_old"; sha=$sha_old; git push -qf origin work

# --- wait -----------------------------------------------------------------------
pr_fixture true work
expect "wait refuses a draft" 5 "$(run wait 7)"
pr_fixture false work
# The window right after ready: only the draft-time run exists, all skipped.
wfruns '[{"status":"completed","conclusion":"skipped"}]'
runs '[{"id":1,"name":"Go","status":"completed","conclusion":"skipped","html_url":"u"}]'
expect "draft-time skips alone are not green" 3 "$(run wait 7)"
wfruns '[{"status":"completed","conclusion":"skipped"},{"status":"in_progress","conclusion":null}]'
expect "a ready run still going is not green" 4 "$(PR_CYCLE_TIMEOUT=0 run wait 7)"
wfruns '[{"status":"completed","conclusion":"skipped"},{"status":"completed","conclusion":"success"}]'
runs '[{"id":1,"name":"Go","status":"completed","conclusion":"failure","html_url":"u"},
       {"id":2,"name":"Go","status":"completed","conclusion":"success","html_url":"u"},
       {"id":3,"name":"Claude review","status":"completed","conclusion":"success","html_url":"u"}]'
review clean
expect "a passing re-run supersedes the failed run" 0 "$(run wait 7)"
fail_run() { runs "[{\"id\":$1,\"name\":\"Go\",\"status\":\"completed\",\"conclusion\":\"failure\",\"html_url\":\"run/$1\"}]"; }
fail_run 4
expect "first CI failure: fix round allowed" 1 "$(run wait 7)"
expect "the same red result read again is the same round" 1 "$(run status 7)"
expect "...and again" 1 "$(run status 7)"
fail_run 40
: >"$fix/calls"
expect "second CI failure: fix round allowed" 1 "$(run status 7)"
grep -q "labels" "$fix/calls" && { echo "FAIL [no label before the cap]"; fails=$((fails + 1)); } || echo "ok   [no label before the cap]"
fail_run 41
expect "third CI failure: ask the user" 6 "$(run wait 7)"
grep -q "POST repos/acme/widget/issues/7/labels" "$fix/calls" \
  && echo "ok   [the cap labels the PR needs-human]" || { echo "FAIL [the cap labels the PR needs-human]"; fails=$((fails + 1)); }
runs '[{"id":5,"name":"Go","status":"completed","conclusion":"success","html_url":"u"}]'
expect "green resets the count" 0 "$(run wait 7)"
runs '[{"id":6,"name":"Go","status":"completed","conclusion":"failure","html_url":"u"}]'
expect "after a reset, a failure is round 1 again" 1 "$(run wait 7)"
runs '[{"id":7,"name":"Go","status":"in_progress","conclusion":null,"html_url":"u"}]'
expect "pending past the deadline times out" 4 "$(PR_CYCLE_TIMEOUT=0 run wait 7)"
runs '[]'
expect "no checks at all is not green" 3 "$(run wait 7)"

# --- status: one read per event, never a sleep -----------------------------------
runs '[{"id":7,"name":"Go","status":"in_progress","conclusion":null,"html_url":"u"}]'
expect "status while a check is pending says not yet" 7 "$(PR_CYCLE_INTERVAL=999 run status 7)"
wfruns '[{"status":"completed","conclusion":"skipped"},{"status":"in_progress","conclusion":null}]'
expect "status while a run is going says not yet" 7 "$(PR_CYCLE_INTERVAL=999 run status 7)"
wfruns '[{"status":"completed","conclusion":"skipped"}]'
expect "status before the ready run registers says not yet" 7 "$(PR_CYCLE_INTERVAL=999 run status 7)"
wfruns '[{"status":"completed","conclusion":"skipped"},{"status":"completed","conclusion":"success"}]'
runs '[{"id":10,"name":"Go","status":"completed","conclusion":"success","html_url":"u"}]'
expect "status on green" 0 "$(run status 7)"
pr_fixture true work
expect "status refuses a draft" 5 "$(run status 7)"
pr_fixture false work

# --- ship hands off to events; handoff gives the PR to the tender ------------------
pr_fixture true work
: >"$fix/calls"
expect "ship marks ready and returns at once" 0 "$(PR_CYCLE_INTERVAL=999 run ship 7)"
grep -q "POST repos/acme/widget/issues/7/labels" "$fix/calls" \
  && echo "ok   [ship marks the PR attended]" || { echo "FAIL [ship marks the PR attended]"; fails=$((fails + 1)); }
grep -q "subscribe_pr_activity" "$work/out" \
  && echo "ok   [ship says to subscribe and end the turn]" || { echo "FAIL [ship says to subscribe and end the turn]"; fails=$((fails + 1)); }
pr_fixture false work   # the stub cannot flip draft; ready on a ready PR is a no-op
expect "ship --wait still blocks to a verdict" 0 "$(run ship 7 --wait)"
expect "ship refuses an unknown flag" 2 "$(run ship 7 --poll)"
: >"$fix/calls"
expect "handoff" 0 "$(run handoff 7)"
grep -q "DELETE repos/acme/widget/issues/7/labels/factory%3Aattended" "$fix/calls" \
  && echo "ok   [handoff removes the attended label]" || { echo "FAIL [handoff removes the attended label]"; fails=$((fails + 1)); }

# --- merge ---------------------------------------------------------------------
runs '[{"id":8,"name":"Go","status":"completed","conclusion":"success","html_url":"u"},
       {"id":9,"name":"Claude review","status":"completed","conclusion":"success","html_url":"u"}]'
pr_fixture false spec/add-thing
expect "merge refuses a spec PR" 5 "$(run merge 7)"
pr_fixture true work
expect "merge refuses a draft" 5 "$(run merge 7)"
pr_fixture false work
runs '[{"id":8,"name":"Go","status":"completed","conclusion":"success","html_url":"u"}]'
expect "merge refuses a missing required check" 5 "$(run merge 7)"
runs '[{"id":8,"name":"Go","status":"completed","conclusion":"success","html_url":"u"},
       {"id":9,"name":"Claude review","status":"completed","conclusion":"success","html_url":"u"}]'
review findings
expect "merge refuses unanswered findings" 5 "$(run merge 7)"
printf '[{"body":"<!-- claude-review v1 outcome=clean sha=0000000000000000000000000000000000000000 -->"}]' \
  >"$fix/repos_acme_widget_issues_7_comments_per_page_100.json"
expect "merge refuses a stale review" 5 "$(run merge 7)"
review findings
: >"$fix/calls"
expect "merge with findings dispositioned" 0 "$(run merge 7 --dispositioned --delete-branch)"
grep -q "DELETE repos/acme/widget/git/refs/heads/work" "$fix/calls" \
  && echo "ok   [merge deletes the branch when asked]" || { echo "FAIL [merge deletes the branch when asked]"; fails=$((fails + 1)); }
grep -q "PUT repos/acme/widget/pulls/7/merge" "$fix/calls" \
  && echo "ok   [merge goes through REST]" || { echo "FAIL [merge goes through REST]"; fails=$((fails + 1)); }

# --- open ------------------------------------------------------------------------
echo body >"$work/body.md"
git switch -q main && echo m >m && git add m && git commit -qm m && git push -q origin main && git switch -q work
expect "open refuses a branch behind its base" 5 "$(run open --title t --body-file "$work/body.md")"
git merge -q --no-edit main
echo '[]' >"$fix/repos_acme_widget_pulls_head_acme_work_state_open.json"
echo '{"number":9,"html_url":"https://example.com/9"}' >"$fix/POST-repos_acme_widget_pulls.json"
: >"$fix/calls"
expect "open a draft once merged with its base" 0 "$(run open --title t --body-file "$work/body.md")"
[ "$(tail -1 "$work/out")" = 9 ] && grep -q "POST repos/acme/widget/pulls$" "$fix/calls" \
  && echo "ok   [open prints the new PR number]" || { echo "FAIL [open prints the new PR number]"; fails=$((fails + 1)); }
echo '[{"number":9}]' >"$fix/repos_acme_widget_pulls_head_acme_work_state_open.json"
expect "open reuses an existing PR" 0 "$(run open --title t --body-file "$work/body.md")"

if [ "$fails" -gt 0 ]; then echo "check-pr-cycle: $fails failure(s)" >&2; exit 1; fi
echo "check-pr-cycle: all checks passed"
