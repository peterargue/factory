#!/usr/bin/env bash
# Fixture-test the signal workflow's script: the one that turns red CI and review
# findings into the labels that start the GitHub-triggered tender.
#
# The script is cut out of templates/factory-signal.yml between its markers, so
# the text tested is the text a repo copies. gh is a stub that serves fixture JSON
# per REST path, runs `--jq` through real jq, and records every write.
#
# What must hold, because each is a label that would start a session for nothing,
# or a missing one that would leave a red PR unattended:
#   - red CI on a PR's current head labels it factory:ci-red
#   - a cancelled run, a stale head, a draft, a fork, an attended PR and a
#     needs-human PR are all left alone
#   - review findings for the head label factory:review-findings; a clean review
#     or findings for an older commit do not
#   - a person's changes_requested labels it; a bot's review event does not
#
#   tests/check-factory-signal.sh

set -uo pipefail

tpl=$(cd -- "$(dirname -- "$0")/../plugins/factory/templates" && pwd -P)/factory-signal.yml
[ -f "$tpl" ] || { echo "check-factory-signal: $tpl is missing" >&2; exit 2; }

work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
fix="$work/fix"; mkdir -p "$fix" "$work/bin"
fails=0

awk '/# --- factory-signal script start ---/{on=1} on{print} /# --- factory-signal script end ---/{on=0}' "$tpl" \
  | sed 's/^          //' >"$work/signal.sh"
grep -q 'factory-signal script end' "$work/signal.sh" || { echo "check-factory-signal: markers not found in $tpl" >&2; exit 2; }

cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = api ] || exit 2
shift
method=GET path='' jqf=''
while [ $# -gt 0 ]; do
  case $1 in
    -X) method=$2; shift 2 ;;
    -f|-F) echo "  $2" >>"$FIXDIR/calls"; shift 2 ;;
    --jq) jqf=$2; shift 2 ;;
    --paginate) shift ;;
    *) path=$1; shift ;;
  esac
done
[ "$method" != GET ] && { echo "$method $path" >>"$FIXDIR/calls"; echo '{}'; exit 0; }
f="$FIXDIR/$(printf '%s' "$path" | tr '/?&=:' '_____').json"
[ -f "$f" ] || { echo "stub: no fixture $f" >&2; exit 1; }
if [ -n "$jqf" ]; then jq -r "$jqf" "$f"; else cat "$f"; fi
STUB
chmod +x "$work/bin/gh"

export PATH="$work/bin:$PATH" FIXDIR="$fix" REPO=acme/widget CI_WORKFLOW=CI REVIEW_WORKFLOW="Claude PR Review"
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
old=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

pr() { # draft head_sha labels-json [fork]
  jq -n --argjson d "$1" --arg s "$2" --argjson l "$3" --arg r "${4:-acme/widget}" \
    '{number:7,state:"open",draft:$d,head:{sha:$s,repo:{full_name:$r}},labels:[$l[] | {name:.}]}' \
    >"$fix/repos_acme_widget_pulls_7.json"
}
run_event() { # name conclusion sha [prs-json]
  local prs='[{"number":7}]'
  [ $# -ge 4 ] && prs=$4
  jq -n --arg n "$1" --arg c "$2" --arg s "$3" --argjson p "$prs" \
    '{workflow_run:{name:$n,conclusion:$c,head_sha:$s,event:"pull_request",pull_requests:$p}}' >"$work/event.json"
}
review_event() { # state user-type
  jq -n --arg s "$1" --arg t "$2" --arg h "$head" \
    '{review:{state:$s,user:{type:$t}},pull_request:{number:7,head:{sha:$h}}}' >"$work/event.json"
}
marker() { # outcome sha
  printf '[{"body":"x\\n<!-- claude-review v1 outcome=%s sha=%s -->"}]' "$1" "$2" \
    >"$fix/repos_acme_widget_issues_7_comments_per_page_100.json"
}
check() { # label event want-label-or-none
  : >"$fix/calls"
  EVENT=$2 EVENT_PATH="$work/event.json" bash "$work/signal.sh" >"$work/out" 2>&1
  local got=none
  grep -q "^POST repos/acme/widget/issues/7/labels" "$fix/calls" && got=$(sed -n 's/^  labels\[\]=//p' "$fix/calls" | head -1)
  if [ "$got" = "$3" ]; then echo "ok   [$1]"; else
    echo "FAIL [$1] labelled '$got', want '$3'"; sed 's/^/    /' "$work/out"; fails=$((fails + 1)); fi
}

pr false "$head" '[]'
run_event CI failure "$head";               check "red CI on the head" workflow_run factory:ci-red
run_event CI timed_out "$head";             check "timed-out CI on the head" workflow_run factory:ci-red
run_event CI cancelled "$head";             check "a cancelled run is superseded, not red" workflow_run none
run_event CI success "$head";               check "green CI" workflow_run none
run_event CI failure "$old";                check "red CI for an older commit" workflow_run none
run_event Deploy failure "$head";           check "a workflow it does not watch" workflow_run none
echo '[{"number":7,"state":"open"}]' >"$fix/repos_acme_widget_commits_${head}_pulls.json"
run_event CI failure "$head" '[]';          check "finds the PR from the commit when the run lists none" workflow_run factory:ci-red
run_event CI failure "$head"
pr true "$head" '[]';                       check "a draft" workflow_run none
pr false "$head" '["factory:attended"]';    check "an attended PR" workflow_run none
pr false "$head" '["factory:needs-human"]'; check "a PR past its cap" workflow_run none
pr false "$head" '[]' someone/fork;         check "a fork" workflow_run none

pr false "$head" '["bug"]'
run_event "Claude PR Review" success "$head"
marker findings "$head";                    check "review findings on the head" workflow_run factory:review-findings
marker clean "$head";                       check "a clean review" workflow_run none
marker findings "$old";                     check "findings for an older commit" workflow_run none

review_event changes_requested User;        check "a person requests changes" pull_request_review factory:review-findings
review_event changes_requested Bot;         check "a bot's review event" pull_request_review none
review_event commented User;                check "a person's comment-only review" pull_request_review none

if [ "$fails" -gt 0 ]; then echo "check-factory-signal: $fails failure(s)" >&2; exit 1; fi
echo "check-factory-signal: all checks passed"
