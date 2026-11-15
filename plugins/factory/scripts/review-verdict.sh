#!/usr/bin/env bash
# Turn a pull request's review marker into a plain-English verdict.
#
#   "${CLAUDE_PLUGIN_ROOT}"/scripts/review-verdict.sh <head-sha> <marker> [<pr>]
#
# WHY THIS IS ITS OWN SCRIPT. `wait-ci.sh` calls it, and its fixture test calls
# the same file — so the branch a test exercises is the branch that ships. The
# repository has already been bitten by the alternative: `check-review-queries.sh`
# exists because a filter was tested through a stub that ignored the very flag
# under test, and the real query had never run once.
#
# WHY IT EXISTS AT ALL. A green `Claude review` check means a review was
# RECORDED, not that it found nothing — findings are deliberately never a gate.
# So the colour says nothing about whether there is something to read. Three
# consecutive rounds on one pull request came back 7/7 green with real defects
# sitting in inline comments, which `gh pr view --comments` does not display.
#
# The marker is scoped to a SHA on purpose, so a review of an earlier push is
# reported as stale rather than mistaken for this commit's verdict.
#
# Every branch still points at pr-review-comments.sh: this summarises a verdict,
# it does not replace reading the findings.
#
# Exit codes are advisory, not a gate — the caller decides what to do:
#   0  a review of this exact commit reported clean
#   1  a review of this exact commit reported findings
#   2  no usable review for this commit (absent, stale, or no outcome named)

set -u

head_sha=${1-}
marker=${2-}
pr=${3-<pr>}
read_cmd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-review-comments.sh $pr"

if [ -z "$head_sha" ] || [ -z "$marker" ]; then
  echo "wait-ci: NO review marker found for this pull request — treat it as UNREVIEWED:"
  echo "         $read_cmd"
  exit 2
fi

# Substring test without a subshell; the marker is `<!-- claude-review v1 outcome=X sha=Y -->`.
if [ "${marker#*"sha=$head_sha"}" = "$marker" ]; then
  echo "wait-ci: the newest review marker is for an EARLIER commit, not $head_sha."
  echo "         THIS commit is unreviewed. Check with:"
  echo "         $read_cmd"
  exit 2
fi

case $marker in
  *"outcome=findings"*)
    echo "wait-ci: the review of THIS commit reported FINDINGS. Green did not mean clear —"
    echo "         findings are not a gate. Read them; they are inline comments, which"
    echo "         'gh pr view --comments' does not show:"
    echo "         $read_cmd"
    exit 1
    ;;
  *"outcome=clean"*)
    echo "wait-ci: the review of this commit reported clean. Skim it anyway:"
    echo "         $read_cmd"
    exit 0
    ;;
  *)
    echo "wait-ci: a review marker exists for this commit but names no outcome. Read it:"
    echo "         $read_cmd"
    exit 2
    ;;
esac
