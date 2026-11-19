#!/usr/bin/env bash
# render-review-workflow.sh turns the reusable reviewer into a standalone one that
# GitHub will accept and doctor.sh recognises: no `inputs.` left, a pull_request
# trigger, the job still named `Claude review`, overrides applied.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
render="$here/plugins/factory/scripts/render-review-workflow.sh"
src="$here/.github/workflows/claude-review.yml"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   [$1]"; else echo "FAIL [$1]"; fail=1; fi; }

"$render" --source "$src" --branches 'trunk, "feat/**"' --input allowed_bots=renovate \
  --input 'review_notes=Check the migrations.' > "$tmp/out.yml"
python3 -c 'import sys,yaml,json; d=yaml.safe_load(open(sys.argv[1])); d["on"]=d.pop(True); print(json.dumps(d))' "$tmp/out.yml" > "$tmp/out.json"
j="$tmp/out.json"
check "parses as YAML with a pull_request trigger"   "jq -e '.on.pull_request.branches == [\"trunk\",\"feat/**\"]' '$j' >/dev/null"
check "no workflow_call left"                         "! grep -q workflow_call '$tmp/out.yml'"
check "no inputs. reference left"                     "! grep -qE '\binputs\.[a-z_]+' '$tmp/out.yml'"
check "job keeps its name"                            "jq -e '.jobs.review.name == \"Claude review\"' '$j' >/dev/null"
check "permissions the caller used to supply"         "jq -e '.permissions[\"id-token\"] == \"write\"' '$j' >/dev/null"
check "override applied"                              "grep -q 'allowed_bots: renovate' '$tmp/out.yml'"
check "review notes inlined"                          "grep -q 'Check the migrations.' '$tmp/out.yml'"
check "default applied"                               "grep -q 'SMALL_MODEL: claude-' '$tmp/out.yml'"
check "marker doctor reads"                           "head -1 '$tmp/out.yml' | grep -qE '^# factory: rendered from claude-review\.yml v[0-9.]+'"
rc=0; "$render" --source "$src" --input nope=1 >/dev/null 2>&1 || rc=$?
check "unknown input refused"                         "[ $rc = 2 ]"
rc=0; "$render" --source "$here/.github/workflows/ci.yml" >/dev/null 2>&1 || rc=$?
check "a non-reusable source refused"                 "[ $rc = 2 ]"

[ "$fail" = 0 ] && echo "check-render-review-workflow: all cases passed." || exit 1
