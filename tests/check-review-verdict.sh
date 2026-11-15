#!/usr/bin/env bash
# Exercise review-verdict.sh's four branches against fixtures.
#
# It calls the REAL script rather than reimplementing its `case` — the same rule
# check-review-queries.sh was written to enforce after a filter shipped broken
# because its test had stubbed away the thing under test.
#
# The branch that matters most is `findings`: a pull request can be 7/7 green
# with real defects in inline comments, and that branch is the only thing that
# says so. There is usually no live pull request in that state to test against,
# which is exactly why it needs a fixture.
#
#   tests/check-review-verdict.sh

set -euo pipefail

here=$(cd -- "$(dirname -- "$0")/../plugins/factory/scripts" && pwd -P)
verdict="$here/review-verdict.sh"
[ -x "$verdict" ] || { echo "check-review-verdict: $verdict is missing or not executable" >&2; exit 2; }

sha=baf54822859d85f9eee3abbb431cd5a1d2cd147b
other=447db81e436a5ce8284dbe6cd5617ba6ee1bf33e
fails=0

# want_code, want_substring, head, marker, label
check() {
  want_code=$1; want_text=$2; head=$3; mark=$4; label=$5
  out=$("$verdict" "$head" "$mark" 42 2>&1) && code=0 || code=$?
  if [ "$code" != "$want_code" ]; then
    echo "FAIL [$label] exit $code, want $want_code" >&2
    printf '  output: %s\n' "$out" >&2
    fails=$((fails + 1))
    return
  fi
  case $out in
    *"$want_text"*) echo "ok   [$label] exit $code" ;;
    *)
      echo "FAIL [$label] exit code right but message wrong; want substring: $want_text" >&2
      printf '  output: %s\n' "$out" >&2
      fails=$((fails + 1))
      ;;
  esac
}

check 1 "reported FINDINGS" "$sha" "<!-- claude-review v1 outcome=findings sha=$sha -->" "findings on this commit"
check 0 "reported clean"    "$sha" "<!-- claude-review v1 outcome=clean sha=$sha -->"    "clean on this commit"
check 2 "EARLIER commit"    "$sha" "<!-- claude-review v1 outcome=clean sha=$other -->"  "stale marker"
check 2 "UNREVIEWED"        "$sha" ""                                                    "no marker"
check 2 "UNREVIEWED"        ""     "<!-- claude-review v1 outcome=clean sha=$sha -->"    "head sha unavailable"
check 2 "names no outcome"  "$sha" "<!-- claude-review v1 sha=$sha -->"                  "marker without an outcome"

# A findings marker for an EARLIER commit must report stale, not findings: the
# stale check has to win, or a fixed defect would keep being reported forever.
check 2 "EARLIER commit" "$sha" "<!-- claude-review v1 outcome=findings sha=$other -->" "stale beats findings"

if [ "$fails" -gt 0 ]; then
  echo "check-review-verdict: $fails case(s) failed." >&2
  exit 1
fi
echo "check-review-verdict: all cases passed."
