#!/usr/bin/env bash
# Exercise head-checks-verdict.sh's branches against fixtures.
#
# It calls the REAL script rather than reimplementing its comparisons — the same
# rule check-review-queries.sh was written to enforce after a filter shipped
# broken because its test had stubbed away the thing under test.
#
# The case that matters most is "PR #416 reproduction" below: the pull request
# object lagging behind the branch tip after a push, which is the state that
# turns a push into a false green. That window lasted about 25 seconds and cannot
# be reproduced on demand, which is exactly why it needs a fixture.
#
#   tests/check-head-checks-verdict.sh

set -euo pipefail

here=$(cd -- "$(dirname -- "$0")/../plugins/factory/scripts" && pwd -P)
verdict="$here/head-checks-verdict.sh"
[ -x "$verdict" ] || { echo "check-head-checks: $verdict is missing or not executable" >&2; exit 2; }

# The two real commits from the incident: b is what the pull request kept
# reporting, a is what the branch tip had already become.
a=64bc0298ef573fb03a47fc1dea004cdb68f6a458
b=83b44602311175d6995b1a356a6eb3ea8cbeeb7c
c=ad8825cedbfed0aa24f408bd054acd4c6d5e0c3d
fails=0

# want_code, want_substring, label, then: expected-ref current-ref pr-head n-reported n-registered
check() {
  local want_code=$1 want_text=$2 label=$3; shift 3
  local out code
  out=$("$verdict" "$@" 2>&1) && code=0 || code=$?
  if [ "$code" != "$want_code" ]; then
    echo "FAIL [$label] exit $code, want $want_code" >&2
    echo "     output: $out" >&2
    fails=$((fails + 1))
    return
  fi
  if [ -n "$want_text" ] && case $out in *"$want_text"*) false ;; *) true ;; esac; then
    echo "FAIL [$label] output did not mention '$want_text'" >&2
    echo "     output: $out" >&2
    fails=$((fails + 1))
    return
  fi
  echo "ok   [$label] exit $code"
}

# PR #416 REPRODUCTION. The ref had already advanced to a; the pull request
# object still said b; b genuinely had 7 checks registered, all passing. The
# first version of this guard compared the pull request's head against itself and
# passed this. It must fail.
check 1 "still reports head" "PR #416 reproduction: pull request lags the ref" "$a" "$a" "$b" 7 7

# A push landed while the checks were being watched.
check 1 "moved from" "branch tip moved mid-watch" "$b" "$a" "$a" 7 7

# The tip has no checks at all, yet gh reported some — they are another commit's.
check 1 "belong to a different commit" "reported checks, none registered on the tip" "$a" "$a" "$a" 7 0

# The healthy case: ref, pull request and checks all agree.
check 0 "" "tip, pull request and checks agree" "$c" "$c" "$c" 7 7

# Nothing registered anywhere is not a mismatch; wait-ci.sh owns that case.
check 0 "" "no checks reported and none registered" "$a" "$a" "$a" 0 0

# Ground truth missing must never pass — it is the only thing the pull request's
# own claims get checked against.
check 2 "could not be read from the git ref" "expected ref unknown" unknown "$a" "$a" 7 7
check 2 "could not be read from the git ref" "current ref unknown" "$a" unknown "$a" 7 7
check 2 "could not be read from the git ref" "current ref empty" "$a" "" "$a" 7 7
check 2 "could not be read from the git ref" "current ref not a sha" "$a" "not-a-sha" "$a" 7 7

# The pull request's own head unreadable.
check 2 "pull request's own head" "pr head unknown" "$a" "$a" unknown 7 7
check 2 "pull request's own head" "pr head empty" "$a" "$a" "" 7 7

# Undeterminable count must say so rather than guess either way.
check 2 "unknown" "registered count unknown" "$a" "$a" "$a" 7 unknown

# Malformed numbers and arity.
check 2 "is not a number" "non-numeric reported" "$a" "$a" "$a" many 7
check 2 "neither a number" "garbage registered" "$a" "$a" "$a" 7 lots
check 2 "usage" "too few arguments" "$a" "$a" "$a" 7

# THE CALL SITE. The cases above call head-checks-verdict.sh directly, which is
# the point — but it also means they cannot see how wait-ci.sh reads the exit
# code, and that is where this shipped broken. The first version wrote
# `if ! head-checks-verdict.sh ...; then rc=$?`, and in bash `!` negates the
# status to a plain boolean, so `$?` inside the block is that 0 and the script's
# own 1-vs-2 distinction is destroyed. Every mismatch hard-failed instead of
# re-arming, making the retry this whole change exists for unreachable. Caught in
# review, not by these fixtures — hence these assertions.
#
# All of them read wait-ci.sh with comments STRIPPED. The first draft of the
# `|| rc=$?` assertion matched the explanatory comment beside the call rather
# than the call itself, so it stayed green against a deliberately re-broken copy.
# A test that cannot go red is not a test.
waitci="$here/wait-ci.sh"
if [ -r "$waitci" ]; then
  code=$(sed 's/#.*//' "$waitci")
  # Here-strings, not `printf | grep -q`: grep -q exits on its first match, printf
  # then dies of SIGPIPE, and pipefail turns that into a false FAIL (main CI, 2026-11-12).

  if grep -qE 'if[[:space:]]+!.*head-checks-verdict\.sh' <<<"$code"; then
    echo "FAIL [call site] wait-ci.sh wraps head-checks-verdict.sh in 'if !', which discards its exit code" >&2
    fails=$((fails + 1))
  else
    echo "ok   [call site] the verdict is not invoked through a negation"
  fi

  if ! grep -qE 'head-checks-verdict\.sh' <<<"$code"; then
    echo "FAIL [call site] wait-ci.sh no longer invokes head-checks-verdict.sh at all" >&2
    fails=$((fails + 1))
  elif grep -qE '\|\|[[:space:]]+rc=\$\?' <<<"$code"; then
    echo "ok   [call site] exit code captured in code with '|| rc=\$?'"
  else
    echo "FAIL [call site] wait-ci.sh no longer captures the verdict's exit code with '|| rc=\$?'" >&2
    fails=$((fails + 1))
  fi

  # Ground truth must come from the git ref, not from a second read of the pull
  # request object. Without this, the guard reverts to validating one gh field
  # against itself, which is the defect the #416 reproduction above pins down.
  if grep -qE 'git/ref/heads' <<<"$code"; then
    echo "ok   [call site] the branch tip is read from the git ref"
  else
    echo "FAIL [call site] wait-ci.sh no longer reads the branch tip from the git ref — the guard would be comparing gh's claim against itself" >&2
    fails=$((fails + 1))
  fi
else
  echo "FAIL [call site] cannot read $waitci to check how the verdict is invoked" >&2
  fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then
  echo "check-head-checks: $fails branch(es) behaved wrongly." >&2
  exit 1
fi
echo "check-head-checks: all branches behaved as documented."
