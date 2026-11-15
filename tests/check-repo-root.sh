#!/usr/bin/env bash
# The plugin's scripts resolve the repository from the caller's cwd, not from
# their own location, and refuse one without FACTORY.md. Both halves matter:
# the first is what lets one installed copy serve every repo, the second is what
# stops it answering for whichever checkout an agent happens to be standing in.
set -euo pipefail
scripts=$(cd -- "$(dirname -- "$0")/../plugins/factory/scripts" && pwd -P)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
expect() { # <label> <want-exit> <want-substring> <dir> <script> [env...]
  local label=$1 want=$2 needle=$3 dir=$4 script=$5; shift 5
  local out rc=0
  local pr=7; for kv in "$@"; do [ "${kv%%=*}" = PR ] && pr=${kv#PR=}; done
  out=$(cd "$dir" && "$scripts/$script" "$pr" 2>&1) || rc=$?
  if [ "$rc" = "$want" ] && [[ $out == *"$needle"* ]]; then
    echo "ok   [$label] exit $rc"
  else
    echo "FAIL [$label] exit $rc, want $want containing '$needle': $out"; fail=1
  fi
}
git -C "$tmp" init -q plain
mkdir -p "$tmp/plain/sub"
expect "wait-ci, no FACTORY.md"            2 "not a factory repository" "$tmp/plain/sub" wait-ci.sh
expect "pr-review-comments, no FACTORY.md" 1 "not a factory repository" "$tmp/plain/sub" pr-review-comments.sh
expect "wait-ci, outside any repo"         2 "not a factory repository" "$tmp"            wait-ci.sh
# With FACTORY.md present the root check passes and the script moves on to its
# own argument check, which rejects the non-numeric PR given here.
touch "$tmp/plain/FACTORY.md"
expect "wait-ci, FACTORY.md found from a subdirectory" 2 "is not a pull request number" "$tmp/plain/sub" wait-ci.sh PR=x
[ "$fail" = 0 ] && echo "check-repo-root: all cases passed." || exit 1
