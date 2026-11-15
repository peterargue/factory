#!/usr/bin/env bash
# Print every review on a pull request, from all four places GitHub keeps them.
#
# Why this exists: `gh pr view --comments` shows only TOP-LEVEL comments, and the
# automated reviewer on this repo has NEVER put a body on its own review — that
# has held on every PR checked, #245 through #397. Its findings are file-anchored
# comments on a different endpoint, so the obvious command cannot show them.
#
# That is not hypothetical. On PR #270, observed 2026-07-26:
#
#   gh pr view 270 --comments        -> no output whatsoever
#   this script                      -> 5 inline findings from claude[bot],
#                                       including a bug in a hook and a
#                                       security gap in another
#
# The reviewer's behaviour CHANGED around PR #324: it now also posts a per-round
# prose summary as a top-level comment (0 on #245 and #270; 1 on #324 and #343;
# 3, 4 and 5 on #391, #396 and #397). So on a recent PR the obvious command is no
# longer silent — which is worse, because it prints prose that looks like the
# whole story while carrying no file:line anchor, no thread id, and no resolution
# state. Do not treat it as the review.
#
# GitHub splits a pull request's discussion across four endpoints, and a reader
# needs all four:
#
#   issues/<pr>/comments   top-level conversation      (what `gh pr view` reads)
#   pulls/<pr>/reviews     review summaries + verdict  (APPROVED, etc.)
#   pulls/<pr>/comments    inline, file-anchored       (where the findings are)
#   reviewThreads (GraphQL) isResolved + thread ids    (what is still OPEN)
#
# Only the fourth answers "what is left to do": REST exposes no resolution state
# and no thread id at all. Note also that `reviewDecision` stays EMPTY while every
# review is COMMENTED, which is the case on every PR here — so neither it nor a
# green check reflects open findings.
#
# Exit status is about RETRIEVAL, not about findings: 0 means the review state was
# successfully determined, whether or not anything was found. A PR with no
# comments is a legitimate answer and exits 0. Anything that leaves the answer
# unknown — no gh, no jq, a PR that does not exist, an API error — exits non-zero
# and says what to do, because "no output" is precisely the failure mode this
# script exists to eliminate and it must not reintroduce it.
#
# Read-only: every call is a GET or a GraphQL query. It never comments, merges,
# resolves or closes.
#
# Usage:
#   "${CLAUDE_PLUGIN_ROOT}"/scripts/pr-review-comments.sh 270

set -uo pipefail

# The repository is the one the caller is standing in: its git toplevel, or
# FACTORY_REPO_ROOT when set. This script ships in the factory plugin, so its own
# location says nothing about which repository to query. `gh api
# repos/{owner}/{repo}/…` expands that placeholder from the current directory's
# git remote, so the script enters the resolved root before any query, and it
# refuses a root with no FACTORY.md: a repository that has not joined the factory
# is not one this script should be answering for.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || {
  echo "pr-review-comments: cannot resolve this script's own directory." >&2
  exit 1
}
repo_root=${FACTORY_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)} || repo_root=""
if [ -z "$repo_root" ] || [ ! -f "$repo_root/FACTORY.md" ]; then
  echo "pr-review-comments: '${repo_root:-$PWD}' is not a factory repository (no FACTORY.md at its git root) — refusing to query an unknown repository. Run this from inside the repository, or set FACTORY_REPO_ROOT." >&2
  exit 1
fi

die() {
  echo "pr-review-comments: $1" >&2
  exit 1
}

pr=${1-}

case $pr in
  '')       die "usage: pr-review-comments.sh <pr-number>" ;;
  *[!0-9]*) die "'$pr' is not a pull request number. usage: pr-review-comments.sh <pr-number>" ;;
esac

command -v gh >/dev/null 2>&1 || die "gh is not on PATH. Install the GitHub CLI, or read the review at the PR's Files changed tab."
command -v jq >/dev/null 2>&1 || die "jq is not on PATH, so the API response cannot be parsed. Install jq."

cd "$repo_root" || die "cannot enter $repo_root"

# fetch <endpoint> <label> — GET and echo the JSON, or abort naming the failure.
# The response is captured before use so that an API error (bad credentials, a PR
# that does not exist, rate limiting) becomes a loud abort rather than an empty
# body that jq would happily report as "no comments".
fetch() {
  local endpoint=$1 label=$2 body status
  body=$(gh api "repos/{owner}/{repo}/$endpoint" --paginate 2>&1)
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "pr-review-comments: failed to read $label for PR #$pr (gh exited $status)." >&2
    echo "$body" | sed 's/^/  /' >&2
    echo "  Check the PR number exists and that gh is authenticated: gh auth status" >&2
    exit 1
  fi
  # --paginate concatenates one JSON array per page; -s . re-joins them into one.
  if ! printf '%s' "$body" | jq -s 'add // []' 2>/dev/null; then
    echo "pr-review-comments: could not parse the $label response for PR #$pr as JSON." >&2
    printf '%s\n' "$body" | head -5 | sed 's/^/  /' >&2
    exit 1
  fi
}

# Confirm the PR exists before reporting emptiness as a finding.
title=$(gh pr view "$pr" --json number,title,state \
  -q '"#\(.number) [\(.state)] \(.title)"' 2>&1)
# shellcheck disable=SC2181
if [ $? -ne 0 ]; then
  echo "pr-review-comments: cannot read PR #$pr." >&2
  printf '%s\n' "$title" | sed 's/^/  /' >&2
  exit 1
fi

inline=$(fetch "pulls/$pr/comments" "inline review comments") || exit 1
reviews=$(fetch "pulls/$pr/reviews" "review summaries") || exit 1
toplevel=$(fetch "issues/$pr/comments" "top-level comments") || exit 1

# Resolution state and thread ids are GraphQL-only, so this cannot reuse fetch().
# Same contract though: a failed query aborts loudly rather than reporting "no open
# threads", which is the one wrong answer this script must never give.
#
# Two field notes, both verified against live PRs on this repo:
#   * `line` is null whenever isOutdated is true, so the anchor comes from
#     `originalLine` — same fallback the inline section already makes.
#   * GraphQL reports a bot author WITHOUT the `[bot]` suffix that REST keeps
#     (`claude` here, `claude[bot]` above). Never filter GraphQL on `claude[bot]`.
nwo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
  || die "cannot determine owner/repo for the GraphQL thread query."
threads=$(gh api graphql \
  -f owner="${nwo%%/*}" -f name="${nwo##*/}" -F pr="$pr" \
  -f query='
query($owner:String!,$name:String!,$pr:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$pr){
      reviewThreads(first:100){
        nodes{
          id isResolved isOutdated viewerCanResolve path line originalLine
          comments(first:100){ totalCount nodes{ author{login} } }
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes' 2>&1) || {
  echo "pr-review-comments: failed to read review threads for PR #$pr." >&2
  printf '%s\n' "$threads" | head -5 | sed 's/^/  /' >&2
  echo "  Resolution state is GraphQL-only; without it 'what is still open' is unknown." >&2
  exit 1
}

count() { printf '%s' "$1" | jq 'length'; }

n_inline=$(count "$inline")
n_reviews=$(count "$reviews")
n_top=$(count "$toplevel")
n_bodied=$(printf '%s' "$reviews" | jq '[.[] | select((.body // "") != "")] | length')
n_threads=$(count "$threads")
n_open=$(printf '%s' "$threads" | jq '[.[] | select(.isResolved == false)] | length')
n_silent=$(printf '%s' "$threads" | jq '[.[] | select(.isResolved == false and .comments.totalCount == 1)] | length')

echo "$title"
echo "$n_inline inline comment(s), $n_reviews review record(s) ($n_bodied with a summary body), $n_top top-level comment(s)"
echo "$n_open of $n_threads review thread(s) UNRESOLVED, $n_silent of those with no reply at all"

section() { echo; echo "=== $1 ==="; }

section "Unresolved threads ($n_open of $n_threads)"
if [ "$n_threads" -eq 0 ]; then
  echo "(no review threads at all — nothing has been raised on the diff)"
elif [ "$n_open" -eq 0 ]; then
  echo "(every thread is resolved — nothing is awaiting a response)"
else
  # Thread ids are printed because they are the only handle for replying to or
  # resolving a thread, and they exist nowhere in REST output.
  printf '%s' "$threads" | jq -r '
    .[] | select(.isResolved == false)
    | "- \(.path // "?"):\(.line // .originalLine // "?")  [\(.comments.nodes[0].author.login // "?")]"
      + (if .comments.totalCount == 1 then "  NO REPLY" else "  \(.comments.totalCount - 1) repl(y/ies)" end)
      + (if .isOutdated then "  [anchor outdated]" else "" end)
      + (if .viewerCanResolve then "" else "  [you cannot resolve this]" end)
      + "\n    thread: \(.id)"'
  echo
  echo "An unresolved thread is not the same as an unaddressed finding, in either"
  echo "direction. Most open threads on a multi-round PR were already fixed by a"
  echo "later commit and simply never closed out, and 'anchor outdated' does NOT"
  echo "mean addressed — it only means the diff moved. Decide each one by reading the"
  echo "file at the PR HEAD commit (gh pr view <pr> --json headRefOid), never from"
  echo "your working tree, which can be ahead of the PR and hide a live finding."
  echo "Procedure for working through these: skill://addressing-pr-feedback"
fi

section "Review verdicts ($n_reviews)"
if [ "$n_reviews" -eq 0 ]; then
  echo "(none — no automated or human review has been submitted)"
else
  printf '%s' "$reviews" | jq -r '
    .[] | "- \(.user.login // "?") [\(.state // "?")] \(.submitted_at // "")"
      + (if (.body // "") == "" then "\n    (no summary body — findings, if any, are inline below)"
         else "\n" + ((.body | rtrimstr("\n")) | split("\n") | map("    " + .) | join("\n")) end)'
fi

section "Inline comments ($n_inline)"
if [ "$n_inline" -eq 0 ]; then
  echo "(none)"
else
  # .line is null on an outdated comment (the diff moved under it), so fall back
  # to original_line rather than printing "null" — an outdated finding is still a
  # finding and often the most important one on a branch that has been rebased.
  printf '%s' "$inline" | jq -r '
    .[] | "- \(.user.login // "?")  \(.path // "?"):\(.line // .original_line // "?")"
      + (if .in_reply_to_id then "  (reply)" else "" end)
      + (if .line == null then "  [outdated]" else "" end)
      + "\n  \(.html_url // "")"
      + "\n" + ((.body // "" | rtrimstr("\n")) | split("\n") | map("    " + .) | join("\n"))'
fi

section "Top-level comments ($n_top)"
if [ "$n_top" -eq 0 ]; then
  echo "(none — this is the view 'gh pr view --comments' gives you, which is why"
  echo " a review can look absent when it is not)"
else
  printf '%s' "$toplevel" | jq -r '
    .[] | "- \(.user.login // "?") \(.created_at // "")"
      + "\n" + ((.body // "" | rtrimstr("\n")) | split("\n") | map("    " + .) | join("\n"))'
fi

if [ "$n_open" -gt 0 ]; then
  echo
  echo "NOTE: $n_open thread(s) still await a response and $n_silent of those have no"
  echo "      reply at all. A green PR is not a reviewed PR, and a merged PR is not a"
  echo "      resolved one — this repo has shipped a live finding that way."
elif [ "$n_inline" -gt 0 ] && [ "$n_top" -eq 0 ] && [ "$n_bodied" -eq 0 ]; then
  echo
  echo "NOTE: every finding here is inline-only. 'gh pr view --comments' shows"
  echo "      nothing for this PR. A green PR is not a reviewed PR — read the above."
fi

exit 0
