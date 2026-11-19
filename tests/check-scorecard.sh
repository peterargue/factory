#!/usr/bin/env bash
# scorecard.sh counts what the scorecard says it counts. A stub gh serves one
# week's fixture: two PRs merged in the window (one passed CI first time and was
# pushed again after ready; one went green only on a rerun), one merged before the
# window, one closed unmerged, a failed review run that hit the usage limit, and one
# saved project thread with a message ask, a decision card and a usage-limit note.
set -euo pipefail
script=$(cd -- "$(dirname -- "$0")/../plugins/factory/scripts" && pwd -P)/scorecard.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # <label> <jq-expr> <want>
  local got; got=$(jq -c "$2" "$tmp/out.json")
  if [ "$got" = "$3" ]; then echo "ok   [$1] $got"; else echo "FAIL [$1] got $got, want $3"; fail=1; fi
}

git -C "$tmp" init -q repo
cat > "$tmp/repo/FACTORY.md" <<'EOF'
repo:
  github: acme/widgets
  default_branch: main
ci:
  review_workflow: .github/workflows/claude-review.yml   # the thin caller
EOF

mkdir "$tmp/fx"
cat > "$tmp/fx/pulls.json" <<'EOF'
[{"number":1,"title":"one","base":{"ref":"main"},"head":{"ref":"b1"},"created_at":"2026-11-13T10:00:00Z","merged_at":"2026-11-14T10:00:00Z","updated_at":"2026-11-14T10:00:00Z"},
 {"number":2,"title":"two","base":{"ref":"feature/x"},"head":{"ref":"b2"},"created_at":"2026-11-15T10:00:00Z","merged_at":"2026-11-15T12:00:00Z","updated_at":"2026-11-15T12:00:00Z"},
 {"number":3,"title":"old","base":{"ref":"main"},"head":{"ref":"b3"},"created_at":"2026-11-01T10:00:00Z","merged_at":"2026-11-02T10:00:00Z","updated_at":"2026-11-13T00:00:00Z"},
 {"number":4,"title":"closed","base":{"ref":"main"},"head":{"ref":"b4"},"created_at":"2026-11-13T10:00:00Z","merged_at":null,"updated_at":"2026-11-13T11:00:00Z"}]
EOF
cat > "$tmp/fx/runs-b1.json" <<'EOF'
{"workflow_runs":[
 {"head_sha":"a","path":".github/workflows/ci.yml","name":"CI","conclusion":"skipped","run_attempt":1,"created_at":"2026-11-13T10:01:00Z"},
 {"head_sha":"a","path":".github/workflows/ci.yml","name":"CI","conclusion":"success","run_attempt":1,"created_at":"2026-11-13T11:00:00Z"},
 {"head_sha":"a","path":".github/workflows/claude-review.yml","name":"Claude PR Review","conclusion":"success","run_attempt":1,"created_at":"2026-11-13T11:00:00Z"},
 {"head_sha":"b","path":".github/workflows/ci.yml","name":"CI","conclusion":"success","run_attempt":1,"created_at":"2026-11-14T09:00:00Z"}]}
EOF
cat > "$tmp/fx/runs-b2.json" <<'EOF'
{"workflow_runs":[
 {"head_sha":"c","path":".github/workflows/ci.yml","name":"CI","conclusion":"success","run_attempt":2,"created_at":"2026-11-15T10:05:00Z"},
 {"head_sha":"c","path":".github/workflows/lint.yml","name":"Lint","conclusion":"success","run_attempt":1,"created_at":"2026-11-15T10:05:00Z"}]}
EOF
cat > "$tmp/fx/pr1-comments.json" <<'EOF'
[{"user":{"login":"claude[bot]"},"in_reply_to_id":null},{"user":{"login":"claude[bot]"},"in_reply_to_id":null},
 {"user":{"login":"claude[bot]"},"in_reply_to_id":5},{"user":{"login":"someone"},"in_reply_to_id":null}]
EOF
echo '[{"body":"<!-- claude-review v1 outcome=findings sha=a -->"},{"body":"<!-- claude-review v1 outcome=clean sha=b -->"}]' > "$tmp/fx/pr1-issue.json"

# The stub answers by URL shape, and fails loudly on anything it was not given.
cat > "$tmp/gh" <<EOF
#!/usr/bin/env bash
fx=$tmp/fx
[ "\$1" = api ] || exit 1
case \$2 in
  repos/acme/widgets/pulls\?state=closed*) cat "\$fx/pulls.json" ;;
  repos/acme/widgets/actions/runs\?*branch=b1*) cat "\$fx/runs-b1.json" ;;
  repos/acme/widgets/actions/runs\?*branch=b2*) cat "\$fx/runs-b2.json" ;;
  repos/acme/widgets/pulls/1/comments*) cat "\$fx/pr1-comments.json" ;;
  repos/acme/widgets/issues/1/comments*) cat "\$fx/pr1-issue.json" ;;
  repos/acme/widgets/pulls/2/comments*|repos/acme/widgets/issues/2/comments*) echo '[]' ;;
  repos/acme/widgets/actions/workflows/claude-review.yml/runs*) echo '{"workflow_runs":[{"id":9}]}' ;;
  repos/acme/widgets/actions/runs/9/jobs) echo '{"jobs":[{"id":99,"conclusion":"failure"},{"id":98,"conclusion":"success"}]}' ;;
  repos/acme/widgets/actions/jobs/99/logs) printf 'step\nClaude AI usage limit reached|1763380800\n' ;;
  *) echo "stub gh: unexpected \$2" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/gh"

mkdir "$tmp/threads"
cat > "$tmp/threads/t1.json" <<'EOF'
{"thread_id":"root","messages":[
 {"id":"root","author":"agent","created_at":"2026-11-13T09:00:00Z","body":"Thread title"},
 {"id":"m1","author":"agent","created_at":"2026-11-13T10:00:00Z","body":"{\"kind\":\"status\",\"text\":\"x\"}"},
 {"id":"m2","author":"agent","created_at":"2026-11-13T10:01:00Z","body":"Please reply 'merge #1'."},
 {"id":"m3","author":"agent","created_at":"2026-11-13T11:00:00Z","body":"{\"kind\":\"status\",\"text\":\"y\"}"},
 {"id":"m4","author":"user","created_at":"2026-11-13T12:01:00Z","body":"merge #1"},
 {"id":"m5","author":"user","created_at":"2026-11-13T12:02:00Z","body":"and thanks"},
 {"id":"card","author":"agent","created_at":"2026-11-14T10:00:00Z","body":"{\"kind\":\"activity\",\"tool\":\"ask_decision\"}"},
 {"id":"m6","author":"agent","created_at":"2026-11-14T10:00:05Z","body":"Waiting on the card."},
 {"id":"m7","author":"agent","created_at":"2026-11-14T14:00:00Z","body":"{\"kind\":\"activity\",\"tool\":\"decide\",\"decision_id\":\"card\",\"chosen_by\":\"user_1\"}"},
 {"id":"m8","author":"agent","created_at":"2026-11-15T10:00:00Z","body":"Paused: Claude usage limit reached, resumes at 3pm."},
 {"id":"m9","author":"agent","created_at":"2026-11-25T10:00:00Z","body":"Outside the window."},
 {"id":"m10","author":"user","created_at":"2026-11-25T11:00:00Z","body":"ok"}]}
EOF

(cd "$tmp/repo" && SCORECARD_GH="$tmp/gh" "$script" --since 2026-11-12T00:00:00Z --until 2026-11-19T00:00:00Z \
   --logs --threads "$tmp/threads") > "$tmp/out.json"
check "window"                '[.since,.until]'                           '["2026-11-12T00:00:00Z","2026-11-19T00:00:00Z"]'
check "merged in window only" '[.prs[].number] | sort'                    '[1,2]'
check "into default branch"   '.metrics.into_default'                     '1'
check "first-pass CI"         '.metrics.first_pass_ci'                    '{"passed":1,"of":2,"rate":0.5}'
check "a rerun is not a pass" '.prs[] | select(.number==2) | .failed_first' '["CI"]'
check "review findings"       '.metrics.review_findings'                  '{"total":2,"per_pr":1,"prs_with_findings":1}'
check "rework pushes"         '.metrics.rework_pushes'                    '{"total":1,"per_pr":0.5,"prs_with_rework":1}'
check "asks of the owner"     '.metrics.asks_of_owner'                    '{"asks":2,"median_wait_hours":4,"threads_read":1}'
check "usage-window hits"     '.metrics.usage_window_hits'                '{"total":2,"threads":1,"review_runs":1}'

# Without --threads or --logs those two are unknown, not zero.
(cd "$tmp/repo" && SCORECARD_GH="$tmp/gh" "$script" --since 2026-11-12T00:00:00Z --until 2026-11-19T00:00:00Z) > "$tmp/out.json"
check "asks unknown"          '.metrics.asks_of_owner'                    'null'
check "usage unknown"         '.metrics.usage_window_hits'                'null'

rc=0; (cd "$tmp" && SCORECARD_GH="$tmp/gh" "$script" >/dev/null 2>&1) || rc=$?
if [ "$rc" = 2 ]; then echo "ok   [no FACTORY.md] exit 2"; else echo "FAIL [no FACTORY.md] exit $rc, want 2"; fail=1; fi

[ "$fail" = 0 ] && echo "check-scorecard: all cases passed." || exit 1
