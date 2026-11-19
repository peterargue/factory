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

# Saved sessions, one file each. Every record holds the session's running totals, so a
# session's week is its last total in the window minus its last before it:
#   s1  list_events pages: r2 minus r0; a later total (r9) and a repeated result change
#       nothing; text around the JSON is ignored; one refused rate-limit event.
#   s2  started in the window: r3 counts whole.
#   s3  get_session only, created before the window: counts whole, and is flagged.
#   s4  get_session minus an earlier per-model result, compared over all models.
mkdir "$tmp/sessions"
cat > "$tmp/sessions/s1.txt" <<'EOF'
Another session's record (JSON):
    {"ccr":{"data":[{"created_at":"2026-11-13T10:00:00Z","result":{"uuid":"r1","internal_anthropic_catchall":{"session_id":"s1","modelUsage":{"claude-opus-5-5":{"inputTokens":150,"outputTokens":70,"cacheReadInputTokens":1200,"cacheCreationInputTokens":150,"costUSD":1.75}}}}}, {"created_at":"2026-11-13T11:00:00Z","result":{"uuid":"r2","internal_anthropic_catchall":{"session_id":"s1","modelUsage":{"claude-opus-5-5":{"inputTokens":150,"outputTokens":80,"cacheReadInputTokens":1300,"cacheCreationInputTokens":150,"costUSD":1.8},"claude-haiku-5-5":{"inputTokens":100,"outputTokens":5,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"costUSD":0.01}}}}}, {"created_at":"2026-11-13T12:00:00Z","rate_limit_event":{"uuid":"l1","internal_anthropic_catchall":{"rate_limit_info":{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":0.4}}}}}}, {"created_at":"2026-11-14T12:00:00Z","rate_limit_event":{"uuid":"l2","internal_anthropic_catchall":{"rate_limit_info":{"status":"rejected","unifiedWindows":{"seven_day":{"utilization":0.95}}}}}}, {"created_at":"2026-11-25T11:00:00Z","result":{"uuid":"r9","internal_anthropic_catchall":{"session_id":"s1","modelUsage":{"claude-opus-5-5":{"inputTokens":9999,"outputTokens":9999,"cacheReadInputTokens":9999,"cacheCreationInputTokens":9999,"costUSD":99},"claude-haiku-5-5":{"inputTokens":100,"outputTokens":5,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"costUSD":0.01}}}}}]}}
end of record
{"ccr":{"data":[{"created_at":"2026-11-11T09:00:00Z","result":{"uuid":"r0","internal_anthropic_catchall":{"session_id":"s1","modelUsage":{"claude-opus-5-5":{"inputTokens":50,"outputTokens":20,"cacheReadInputTokens":400,"cacheCreationInputTokens":50,"costUSD":0.5}}}}}, {"created_at":"2026-11-13T10:00:00Z","result":{"uuid":"r1","internal_anthropic_catchall":{"session_id":"s1","modelUsage":{"claude-opus-5-5":{"inputTokens":150,"outputTokens":70,"cacheReadInputTokens":1200,"cacheCreationInputTokens":150,"costUSD":1.75}}}}}]}}
EOF
cat > "$tmp/sessions/s2.json" <<'EOF'
{"ccr":{"data":[{"created_at":"2026-11-15T10:00:00Z","result":{"uuid":"r3","internal_anthropic_catchall":{"session_id":"s2","modelUsage":{"claude-opus-5-5":{"inputTokens":0,"outputTokens":40,"cacheReadInputTokens":100,"cacheCreationInputTokens":0,"costUSD":0.1}}}}}]}}
EOF
cat > "$tmp/sessions/s3.json" <<'EOF'
{"ccr":{"id":"session_s3","created_at":"2026-11-10T08:00:00Z","updated_at":"2026-11-14T08:00:00Z","external_metadata":{"usage":{"input_tokens":10,"output_tokens":20,"cache_read_tokens":300,"cache_write_tokens":30,"cost_usd":0.2}}}}
EOF
cat > "$tmp/sessions/s4.txt" <<'EOF'
{"ccr":{"data":[{"created_at":"2026-11-10T09:00:00Z","result":{"uuid":"r4","internal_anthropic_catchall":{"session_id":"u4","modelUsage":{"claude-opus-5-5":{"inputTokens":5,"outputTokens":5,"cacheReadInputTokens":50,"cacheCreationInputTokens":5,"costUSD":0.05},"claude-haiku-5-5":{"inputTokens":5,"outputTokens":0,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"costUSD":0.01}}}}}]}}
{"ccr":{"id":"session_s4","created_at":"2026-11-09T08:00:00Z","updated_at":"2026-11-15T08:00:00Z","external_metadata":{"usage":{"input_tokens":20,"output_tokens":15,"cache_read_tokens":150,"cache_write_tokens":10,"cost_usd":0.16}}}}
EOF

(cd "$tmp/repo" && SCORECARD_GH="$tmp/gh" "$script" --since 2026-11-12T00:00:00Z --until 2026-11-19T00:00:00Z \
   --logs --threads "$tmp/threads" --sessions "$tmp/sessions") > "$tmp/out.json"
check "window"                '[.since,.until]'                           '["2026-11-12T00:00:00Z","2026-11-19T00:00:00Z"]'
check "merged in window only" '[.prs[].number] | sort'                    '[1,2]'
check "into default branch"   '.metrics.into_default'                     '1'
check "first-pass CI"         '.metrics.first_pass_ci'                    '{"passed":1,"of":2,"rate":0.5}'
check "a rerun is not a pass" '.prs[] | select(.number==2) | .failed_first' '["CI"]'
check "review findings"       '.metrics.review_findings'                  '{"total":2,"per_pr":1,"prs_with_findings":1}'
check "rework pushes"         '.metrics.rework_pushes'                    '{"total":1,"per_pr":0.5,"prs_with_rework":1}'
check "asks of the owner"     '.metrics.asks_of_owner'                    '{"asks":2,"median_wait_hours":4,"threads_read":1}'
check "usage-window hits"     '.metrics.usage_window_hits'                '{"total":3,"threads":1,"review_runs":1,"sessions":1}'
check "tokens in the window"  '.metrics.tokens | [.sessions,.input,.output,.cache_read,.cache_write,.cost_usd_list]' '[4,220,135,1400,135,1.71]'
check "cache hit rate"        '.metrics.tokens.cache_hit_rate'            '0.798'
check "peak window use"       '.metrics.tokens.peak_window_utilization'   '0.95'
check "tokens by model"       '.metrics.tokens.by_model | keys'           '["all models","claude-haiku-5-5","claude-opus-5-5"]'
check "started before, whole" '.metrics.tokens.sessions_started_before'   '1'

# The dashboard's weekly rows carry the token numbers, and an older dataset file keeps
# the weeks no fresh run covers while a fresh run replaces its own week.
dataset=$(dirname "$script")/scorecard-dataset.sh
cp "$tmp/out.json" "$tmp/week.json"
echo '{"rows":[{"week":"2026-11-05","prs_merged":7},{"week":"2026-11-12","prs_merged":99}]}' > "$tmp/old.json"
"$dataset" weeks "$tmp/old.json" "$tmp/week.json" > "$tmp/out.json"
check "dataset keeps old weeks" '[.rows[] | [.week, .prs_merged]]'       '[["2026-11-05",7],["2026-11-12",2]]'
check "dataset tokens"        '.rows[1] | [.sessions,.tokens_cache_read,.cache_hit_rate,.cost_usd_list]' '[4,1400,0.798,1.71]'

# Without --threads or --logs those two are unknown, not zero.
(cd "$tmp/repo" && SCORECARD_GH="$tmp/gh" "$script" --since 2026-11-12T00:00:00Z --until 2026-11-19T00:00:00Z) > "$tmp/out.json"
check "asks unknown"          '.metrics.asks_of_owner'                    'null'
check "usage unknown"         '.metrics.usage_window_hits'                'null'
check "tokens unknown"        '.metrics.tokens'                           'null'

rc=0; (cd "$tmp" && SCORECARD_GH="$tmp/gh" "$script" >/dev/null 2>&1) || rc=$?
if [ "$rc" = 2 ]; then echo "ok   [no FACTORY.md] exit 2"; else echo "FAIL [no FACTORY.md] exit $rc, want 2"; fail=1; fi

[ "$fail" = 0 ] && echo "check-scorecard: all cases passed." || exit 1
