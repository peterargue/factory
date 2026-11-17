#!/usr/bin/env bash
# PreToolUse hook: refuses to mark a pull request ready for review unless the
# repo gate passed on exactly the tree being marked, and the scope judge passed it.
#
# Marking ready is the factory's commit point: it starts CI and the Claude review
# (both skip drafts), so it is the last moment a cheap local check can stop an
# expensive remote one. The gate ran "by instruction" before this hook; now it is
# enforced. It matches every way the repo's sessions mark a PR ready:
#
#   gh pr ready [<n>]                          (not --undo)
#   gh api … pulls/<n>/ccr/ready_for_review    (the cloud route; GraphQL is refused there)
#   gh api graphql … markPullRequestReadyForReview
#   ${CLAUDE_PLUGIN_ROOT}/scripts/pr-cycle.sh ready|ship …   (it marks ready inside its own process,
#                                               where no hook can see the inner gh call)
#   the GitHub MCP connector's update_pull_request with draft: false
#
# Two checks, cheap first:
#
#   1. Gate stamp. `$scripts/gate-stamp.sh --check` must pass in the working
#      copy the command runs in: a green FACTORY.md gate recorded for HEAD's tree,
#      with tracked files clean. Remedy: run `$scripts/gate-stamp.sh`.
#   2. Scope judge. `$scripts/scope-judge.sh` compares the diff with the PR
#      and its OpenSpec change and flags disabled tests and scope creep. A pass is
#      cached per tree, so only the first ready of a tree pays for a judgement.
#
# Like the repo's other guards it fails closed: no jq, no git working copy, a judge
# that cannot run, all deny with the remedy. It exits 0 on every path, since a
# non-zero PreToolUse exit is reported as a hook error even when it allows.
#
# Test by piping a payload, as check-deny-unverified-ready.sh does:
#   printf '%s' '{"cwd":"/path","tool_input":{"command":"gh pr ready 12"}}' | ${CLAUDE_PLUGIN_ROOT}/hooks/deny-unverified-ready.sh

payload=$(cat)

# Only in a repo that has joined the factory.
[ -f "${CLAUDE_PROJECT_DIR:-.}/FACTORY.md" ] || exit 0

deny() {
  jq -cn --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  case $payload in
    *"gh pr ready"*|*ready_for_review*|*markPullRequestReadyForReview*|*pr-cycle.sh*|*update_pull_request*)
      printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"deny-unverified-ready.sh needs jq on PATH to check the gate stamp before a PR is marked ready. Install jq."}}'
      ;;
  esac
  exit 0
fi

tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null)
cmd=$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null)
dir=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)
pr=""

case $tool in
  mcp__*github*__update_pull_request)
    # Only a call that takes the PR out of draft. Any other field update passes.
    [ "$(jq -r '.tool_input.draft | if . == false then "ready" else "" end' <<<"$payload" 2>/dev/null)" = ready ] || exit 0
    pr=$(jq -r '.tool_input.pullNumber // .tool_input.pull_number // empty' <<<"$payload")
    how="update_pull_request draft:false"
    ;;
  *)
    [ -n "$cmd" ] || exit 0
    # Each pattern stands on its own line of the command so that a mention inside
    # a longer string (a commit message quoting `gh pr ready`) still trips it: the
    # repo's hooks match generously and say so, rather than miss a real call.
    how=""
    if grep -qE '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+ready([[:space:]]|$)' <<<"$cmd" \
       && ! grep -qE 'gh[[:space:]]+pr[[:space:]]+ready[^;&|]*--undo' <<<"$cmd"; then
      how="gh pr ready"
      pr=$(grep -oE 'gh[[:space:]]+pr[[:space:]]+ready[[:space:]]+#?[0-9]+' <<<"$cmd" | grep -oE '[0-9]+$' | head -1)
    elif grep -qE 'pulls/[0-9]+/ccr/ready_for_review' <<<"$cmd"; then
      how="ccr/ready_for_review"
      pr=$(grep -oE 'pulls/[0-9]+/ccr/ready_for_review' <<<"$cmd" | grep -oE '[0-9]+' | head -1)
    elif grep -q 'markPullRequestReadyForReview' <<<"$cmd"; then
      how="markPullRequestReadyForReview"
    elif grep -qE 'pr-cycle\.sh[[:space:]]+(ready|ship)([[:space:]]|$)' <<<"$cmd"; then
      how="pr-cycle.sh $(grep -oE 'pr-cycle\.sh[[:space:]]+(ready|ship)' <<<"$cmd" | awk '{print $2}' | head -1)"
      pr=$(grep -oE 'pr-cycle\.sh[[:space:]]+(ready|ship)[[:space:]]+#?[0-9]+' <<<"$cmd" | grep -oE '[0-9]+$' | head -1)
    fi
    [ -n "$how" ] || exit 0
    # A leading `cd <dir> &&` moves where gh runs; honour the simple form.
    lead=$(sed -nE 's/^[[:space:]]*cd[[:space:]]+("([^"]+)"|'"'"'([^'"'"']+)'"'"'|([^[:space:];&|]+))[[:space:]]*&&.*/\2\3\4/p' <<<"$cmd" | head -1)
    if [ -n "$lead" ]; then
      case $lead in
        /*) dir=$lead ;;
        *) dir="${dir:-$PWD}/$lead" ;;
      esac
    fi
    ;;
esac

[ -n "$dir" ] && [ -d "$dir" ] || dir=${CLAUDE_PROJECT_DIR:-$PWD}
top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) \
  || deny "Cannot check the gate before marking a PR ready ($how): $dir is not a git working copy. Run the command from the checkout whose branch the PR is for."

# The stamp and judge are this plugin's own scripts, beside its hooks.
scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)
[ -n "$scripts" ] && [ -x "$scripts/gate-stamp.sh" ] && [ -x "$scripts/scope-judge.sh" ] \
  || deny "Cannot check the gate before marking a PR ready ($how): the factory plugin's gate-stamp.sh and scope-judge.sh are missing or not executable. Reinstall the plugin."

# --- 1. gate stamp --------------------------------------------------------------
if ! why=$("$scripts/gate-stamp.sh" --check --dir "$top" 2>&1); then
  deny "Not marking this PR ready ($how): the repo gate has not passed on this exact commit.

$why

Run the gate from the branch's checkout, then mark ready again:

  $scripts/gate-stamp.sh --dir $top

It runs FACTORY.md's commands.gate and stamps HEAD's tree on green. If you already ran the gate on this commit and it was green, record that with --record instead of running it twice."
fi

# --- 2. scope judge -------------------------------------------------------------
args=(--dir "$top")
[ -n "$pr" ] && args+=(--pr "$pr")
errf=$(mktemp) || deny "Cannot run the scope judge: mktemp failed."
out=$("$scripts/scope-judge.sh" "${args[@]}" 2>"$errf")
rc=$?
err=$(cat "$errf" 2>/dev/null); rm -f "$errf"

case $rc in
  0) exit 0 ;;
  1)
    list=$(jq -r '.findings[] | "- [\(.kind)] \(.file): \(.why)"' <<<"$out" 2>/dev/null)
    summary=$(jq -r '.summary // empty' <<<"$out" 2>/dev/null)
    deny "Not marking this PR ready ($how): the scope judge flagged the diff against what the PR asked for.

$list
${summary:+
$summary
}
Fix it: drop the out-of-scope change into its own PR, restore the test, or do the missing part. Commit, re-run $scripts/gate-stamp.sh, and mark ready again.

If a finding is wrong, or the PR or its issue asked for that change, record why and retry:

  $scripts/scope-judge.sh --dir $top --accept \"<one sentence>\"

and put the same sentence in the PR body under \"Scope judge\". A disabled or deleted test needs the repo owner's say-so (FACTORY.md repo.owner) before you accept it."
    ;;
  *)
    deny "Not marking this PR ready ($how): the scope judge could not run.

${err:-scope-judge.sh exited $rc with no message.}

Fix the cause and retry. If the judge itself is broken, record why the PR is in scope with $scripts/scope-judge.sh --dir $top --accept \"<one sentence>\" and say so in the PR body."
    ;;
esac
