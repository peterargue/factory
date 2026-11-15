#!/usr/bin/env bash
# CI check — replay the review backstop against fixture data, running its REAL
# queries.
#
# This exists because of a specific outage. The backstop detects a completed
# review with a `gh api --jq` filter referencing `$ENV.marker`, and `marker` was
# assigned as a plain shell variable. jq's `$ENV` reads the process environment,
# so an unexported variable arrives as null, `contains(null)` aborts the query,
# and under `set -euo pipefail` the whole step exits 1. Every pull request check
# in the repository went red at once — and because the step had just been made to
# FAIL when no review is recorded, that blocked merges.
#
# It survived testing because the tests stubbed `gh` with a script that ignored
# `--jq` entirely, so the filter never ran. **A stub that replaces the command
# also replaces the thing you are trying to test.**
#
# So the fake `gh` here does the opposite: it serves fixture JSON and passes
# `--jq` through to real jq. The step's own script is extracted from the
# workflow rather than copied, so the filters under test cannot drift from the
# filters that ship.
#
# Run it by hand the same way CI does:
#   tests/check-review-queries.sh

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
workflow="$repo_root/.github/workflows/claude-review.yml"
step="Make an unrecorded review visible"

command -v jq >/dev/null 2>&1 || { echo "check-review-queries: needs jq on PATH" >&2; exit 2; }
[ -f "$workflow" ] || { echo "check-review-queries: $workflow not found" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- extract the step's script from the workflow ------------------------------
# The block is `        run: |` under the named step, and its body is indented a
# further two. Taking it from the file is the point: a copy would let the tested
# filter and the shipped filter drift apart, which is the whole failure mode.
awk -v name="$step" '
  index($0, "- name: " name) { found = 1 }
  found && /^ *run: \|/       { collecting = 1; next }
  collecting {
    if ($0 !~ /^ *$/ && $0 !~ /^          /) exit
    sub(/^          /, ""); print
  }
' "$workflow" > "$work/step.sh"

[ -s "$work/step.sh" ] || { echo "check-review-queries: could not extract the '$step' step" >&2; exit 2; }
bash -n "$work/step.sh" || { echo "check-review-queries: extracted step is not valid bash" >&2; exit 2; }

# --- fixtures -----------------------------------------------------------------
SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222

reviewed_json() {
  jq -n --arg sha "$1" '[
    {body: "<!-- linear-linkback -->", user: {login: "linear-code[bot]"}},
    {body: ("## Code review\n\nNo issues found.\n\n<!-- claude-review v1 outcome=clean sha=" + $sha + " -->"),
     user: {login: "claude[bot]"}}
  ]'
}
jq -n '[{body: "<!-- linear-linkback -->", user: {login: "linear-code[bot]"}}]' > "$work/none.json"
reviewed_json "$SHA"   > "$work/this.json"
reviewed_json "$OTHER" > "$work/other.json"
jq -n '[{type:"result",subtype:"success",permission_denials:[]}]' > "$work/exec.json"

# A `gh` that honours --jq with REAL jq. `gh pr comment` is recorded, not sent.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-} ${2:-}" = "pr comment" ]; then echo posted >> "$FIXTURE_DIR/posted"; exit 0; fi
filter=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && filter=$a; prev=$a; done
case "${2:-}" in
  *"/issues/"*|*"/pulls/"*) src="$FIXTURE_COMMENTS" ;;
  *) src="$FIXTURE_DIR/empty.json" ;;
esac
# Propagate jq's exit status. `jq … || cat` would swallow a failing filter and
# fall back to dumping the file — which is exactly the fail-open this check
# exists to catch, and it made a broken filter look like a passing review here.
if [ -n "$filter" ]; then jq -r "$filter" "$src"; else cat "$src"; fi
FAKE
chmod +x "$work/bin/gh"
jq -n '[]' > "$work/empty.json"

# --- run one scenario ---------------------------------------------------------
fails=0
scenario() { # name comments_fixture review_ran expected_exit expect_posted
  local name=$1 fixture=$2 ran=$3 want_exit=$4 want_posted=$5 got_exit out
  rm -f "$work/posted"
  set +e
  out=$(
    cd "$work" && PATH="$work/bin:$PATH" \
    FIXTURE_DIR="$work" FIXTURE_COMMENTS="$work/$fixture" \
    GH_TOKEN=x REPO=owner/repo PR=1 RUN_URL=http://run \
    HEAD_SHA="$SHA" SUMMARY_FILE=claude-review-summary.md \
    MARKER="<!-- claude-review-visibility run 1.1 -->" \
    EXEC_FILE="$work/exec.json" REVIEW_RAN="$ran" REVIEW_OUTCOME=success \
    bash "$work/step.sh" 2>&1
  )
  got_exit=$?
  set -e
  local posted=no; [ -f "$work/posted" ] && posted=yes
  if [ "$got_exit" = "$want_exit" ] && [ "$posted" = "$want_posted" ]; then
    printf '  ok   %-46s exit=%s posted=%s\n' "$name" "$got_exit" "$posted"
  else
    printf '  FAIL %-46s exit=%s (want %s) posted=%s (want %s)\n' \
      "$name" "$got_exit" "$want_exit" "$posted" "$want_posted"
    printf '%s\n' "$out" | sed 's/^/       | /'
    fails=$((fails + 1))
  fi
}

echo "check-review-queries: replaying '$step' against fixtures"

# The regression this file exists for: a broken filter aborts the step, so the
# marker-present case is the one that catches it.
scenario "marker for this commit -> pass, stay quiet" this.json  true  0 no
scenario "marker for a DIFFERENT commit -> not a review" other.json true 1 yes
scenario "no marker at all -> fail and report"          none.json  true  1 yes
scenario "reviewer never ran -> report, do not fail"    none.json  false 0 yes

if [ "$fails" -gt 0 ]; then
  echo "check-review-queries: $fails scenario(s) failed" >&2
  exit 1
fi
echo "check-review-queries: all scenarios passed"
