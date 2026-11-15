#!/usr/bin/env bash
# Decide whether a check list read from `gh pr checks` can honestly be attributed
# to the commit a pull request would actually be merged at.
#
#   "${CLAUDE_PLUGIN_ROOT}"/scripts/head-checks-verdict.sh <expected-ref> <current-ref> <pr-head> <n-reported> <n-registered>
#
#   expected-ref   the head branch's tip, read from the git ref BEFORE the watch
#   current-ref    the head branch's tip, read from the git ref again after it
#   pr-head        headRefOid, what the pull request OBJECT claims its head is
#   n-reported     how many checks `gh pr checks` returned
#   n-registered   how many checks GitHub has registered against current-ref,
#                  or 'unknown' if that could not be read
#
# WHY THIS EXISTS. `gh pr checks <pr>` is addressed by PULL REQUEST, not by
# commit, and `--json` offers no field naming the commit it reported on. So the
# check list alone cannot tell you which commit produced it.
#
# Observed on PR #416 on 2026-09-01: a push moved the branch tip to 64bc0298, but
# GitHub's pull request OBJECT still reported headRefOid 83b44602 and Actions had
# created no runs for the new commit. `gh pr checks` therefore returned the
# PREVIOUS commit's seven completed, passing checks. wait-ci.sh had nothing left
# to wait for and reported "all checks passed" in 5.5 seconds, against a commit
# that was no longer the tip.
#
# WHY THERE ARE THREE SHAS, and this is the part a first version got wrong. The
# first attempt compared headRefOid against headRefOid a few seconds later and
# asked whether that commit had checks. Both reads returned the SAME STALE VALUE
# during the incident window, and the stale commit genuinely had 7 checks
# registered — measured, not assumed — so the guard passed and would not have
# caught the very incident it was written for. It validated one gh field against
# itself. A guard needs a source of truth OUTSIDE the thing it is checking.
#
# The git ref is that source: it is the branch tip itself, not a derived record
# of it, and it is what `git ls-remote` reads. wait-ci.sh reads it through
# `gh api repos/<head-owner>/<head-repo>/git/ref/heads/<head-branch>`, with the
# owner and repo taken from the pull request's headRepositoryOwner and
# headRepository. Note this is NOT gh's `{owner}/{repo}` placeholder, which
# auto-substitutes the CURRENT repository — that form is used elsewhere in
# wait-ci.sh (registered_for, the comments lookup) and would be wrong here,
# because a fork PR's branch does not exist in the base repository at all. The
# asymmetry is deliberate: the ref lives in the head repository, while the check
# runs for a pull request are registered against the base repository.
#
# Reading the ref over HTTPS rather than with `git ls-remote` is also
# deliberate — ls-remote goes over SSH, which in this environment depends on a
# 1Password agent that locks itself and failed repeatedly while this was being
# written. A merge gate must not inherit that. The gh path uses the same HTTPS
# token as every other call in the script, and an unreadable ref exits 2 rather
# than passing.
#
# This script is pure: no network, no file reads, so every branch is exercised
# deterministically by check-head-checks-verdict.sh. The lookups stay in
# wait-ci.sh, exactly as review-verdict.sh takes values its caller fetched.
#
# Exit codes:
#   0  the reported checks can be attributed to the branch tip — trust them
#   1  they cannot — re-arm and read again, and never report green on them
#   2  usage, or the inputs do not determine an answer
#
# Following this repo's rule for anything whose job is to say no: an input it
# cannot interpret exits 2 rather than passing by default.

set -euo pipefail

usage() {
  echo "usage: head-checks-verdict.sh <expected-ref> <current-ref> <pr-head> <n-reported> <n-registered>" >&2
  echo "       any sha may be 'unknown' when it could not be read; n-registered likewise" >&2
  exit 2
}

[ $# -eq 5 ] || usage

expected_ref=$1
current_ref=$2
pr_head=$3
reported=$4
registered=$5

is_sha() { case $1 in [0-9a-f]*) [ ${#1} -ge 7 ] && [ -z "${1//[0-9a-f]/}" ] ;; *) false ;; esac; }
is_num() { case $1 in ''|*[!0-9]*) false ;; *) true ;; esac; }

is_num "$reported" || { echo "head-checks: n-reported '$reported' is not a number." >&2; exit 2; }

# Ground truth first. Without the ref there is nothing to check gh's claims
# against, and the honest answer is "undetermined" — never a pass.
for pair in "expected-ref:$expected_ref" "current-ref:$current_ref"; do
  name=${pair%%:*}; val=${pair#*:}
  if [ -z "$val" ] || [ "$val" = unknown ] || ! is_sha "$val"; then
    echo "head-checks: $name could not be read from the git ref, so no check result can be attributed to the branch tip." >&2
    exit 2
  fi
done

if [ -z "$pr_head" ] || [ "$pr_head" = unknown ] || ! is_sha "$pr_head"; then
  echo "head-checks: the pull request's own head commit could not be read, so the check list cannot be attributed to it." >&2
  exit 2
fi

# Somebody pushed while the checks were being watched: the list just read may
# describe either tip.
if [ "$expected_ref" != "$current_ref" ]; then
  echo "head-checks: the branch tip moved from ${expected_ref:0:8} to ${current_ref:0:8} while the checks were being watched — the list just read may describe either one." >&2
  exit 1
fi

# THE #416 CASE. The pull request object lags the ref after a push, so the checks
# gh reports for the pull request are the PREVIOUS commit's — complete, passing,
# and about code that is no longer there.
if [ "$pr_head" != "$current_ref" ]; then
  echo "head-checks: the pull request still reports head ${pr_head:0:8} while the branch tip is ${current_ref:0:8} — the checks just read describe ${pr_head:0:8}, not the commit that would be merged." >&2
  exit 1
fi

if [ "$registered" = unknown ]; then
  echo "head-checks: could not count the checks registered against ${current_ref:0:8}, so whether the reported list belongs to it is unknown." >&2
  exit 2
fi
is_num "$registered" || { echo "head-checks: n-registered '$registered' is neither a number nor 'unknown'." >&2; exit 2; }

if [ "$reported" -gt 0 ] && [ "$registered" -eq 0 ]; then
  echo "head-checks: gh reported $reported check(s) for this pull request, but commit ${current_ref:0:8} has no check runs and no statuses registered — those checks belong to a different commit." >&2
  exit 1
fi

# reported == 0 is not a mismatch. It is "nothing registered yet", which
# wait-ci.sh already handles with its own re-arm and its own non-zero exit.
exit 0
