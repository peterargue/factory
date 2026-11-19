#!/usr/bin/env bash
# PostToolUse:Bash hook — after a command that puts a new head commit on a branch
# with an open PR, inject guidance on how to watch CI without polling, plus the
# PR's live review-thread state. The guidance is the event-driven cycle: ship,
# subscribe, `pr-cycle.sh status` on each event; never a poll.
#
# Fires on `gh pr create` unconditionally, and on `git push` only when the current
# branch actually has an open PR (otherwise no checks will run and the advice is
# noise).

# The plugin can be enabled at user scope, so this hook fires in every project.
# It acts only in a repository that has joined the factory.
[ -f "${CLAUDE_PROJECT_DIR:-.}/FACTORY.md" ] || exit 0

cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null)

case $cmd in
  *"gh pr create"*) ;;
  *"git push"*) gh pr view --json number >/dev/null 2>&1 || exit 0 ;;
  *) exit 0 ;;
esac

# The PR number is needed twice below, so resolve it once. Empty is tolerated: on
# the `gh pr create` path the PR may not be queryable yet, and the CI guidance is
# still worth injecting without it.
pr=$(gh pr view --json number --jq .number 2>/dev/null)

# Live thread state, so the reminder names a number instead of nagging in the
# abstract. Resolution state is GraphQL-only. A FAILED query must never read as
# "nothing open" — that is the exact false-clean this hook exists to prevent — so
# the unknown case says so out loud.
review_state="Review state for this PR could not be determined (no PR number resolved). Check it yourself before assuming the PR is clean."
if [ -n "$pr" ]; then
  nwo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
  counts=$(gh api graphql \
    -f owner="${nwo%%/*}" -f name="${nwo##*/}" -F pr="$pr" \
    -f query='
  query($owner:String!,$name:String!,$pr:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$pr){
        reviewThreads(first:100){ nodes{ isResolved comments{ totalCount } } }
      }
    }
  }' --jq '.data.repository.pullRequest.reviewThreads.nodes
           | [length, ([.[]|select(.isResolved==false)]|length),
                      ([.[]|select(.isResolved==false and .comments.totalCount==1)]|length)]
           | @tsv' 2>/dev/null)
  if [ -n "$counts" ]; then
    IFS=$'\t' read -r n_all n_open n_silent <<<"$counts"
    if [ "${n_open:-0}" -gt 0 ]; then
      review_state="OPEN REVIEW FEEDBACK: PR #$pr has $n_open unresolved review thread(s) of $n_all, and $n_silent of those carry no reply at all. These are from the round BEFORE this push. Work through them now — do not wait for the next review."
    elif [ "${n_all:-0}" -gt 0 ]; then
      review_state="All $n_all review thread(s) on PR #$pr are resolved. A fresh review will land on the commit you just pushed; check again once it does."
    else
      review_state="No review threads on PR #$pr yet. A review will land on the commit you just pushed."
    fi
  else
    review_state="Could not read review threads for PR #$pr (the GraphQL query failed). Do NOT read that as a clean PR — retry with ${CLAUDE_PLUGIN_ROOT:-<plugin>}/scripts/pr-review-comments.sh $pr."
  fi
fi

guidance=$(cat <<'EOF'
CI will run on the head commit you just pushed. Do NOT schedule a wake-up, CronCreate, sleep, or a poll loop to check it.

The factory is event-driven:
1. A PR is shipped once, after its last push: ${CLAUDE_PLUGIN_ROOT}/scripts/pr-cycle.sh ship <number>. It marks the PR ready (gated) and labels it factory:attended, then returns.
2. In a cloud session or project thread, subscribe to the PR's activity (subscribe_pr_activity) and END THE TURN. Each CI result and review arrives as an event. On each one run, once:
     ${CLAUDE_PLUGIN_ROOT}/scripts/pr-cycle.sh status <number>
   Its EXIT CODE IS THE VERDICT: 0 green (it then prints the review verdict), 1 red with a fix round left, 6 red past the cap (ask the user), 7 not settled yet (end the turn again), 3 unknown, 5 refused. None but 0 is green.
3. In a local CLI session, which has no event channel, run pr-cycle.sh ship <number> --wait once, backgrounded (run_in_background=true); the harness wakes you when it exits.
4. Leaving a PR you shipped? Run pr-cycle.sh handoff <number>: the next red CI or review finding labels it and the GitHub-triggered tender (factory:tend-pr) takes one fix round.
5. On a genuine failure, inspect with: gh run view <run-id> --log-failed (or the REST jobs/<id>/logs route in the cloud). Root-cause it, fix, unready, push, gate, ship again.

A green check does NOT mean the PR was reviewed, and this repo has merged a PR carrying a live finding. claude-review.yml has never put a body on its own review and every review it submits is COMMENTED, so none of "gh pr view --comments", reviewDecision, or a green check reflects open findings. Since around PR #324 the bot also posts a prose summary as a top-level comment, which is worse than silence: it reads like the whole review while carrying no file:line anchor, no thread id and no resolution state.

Read the real state, including which threads are still open:
  ${CLAUDE_PLUGIN_ROOT}/scripts/pr-review-comments.sh <number>
Then answer every thread with one of the factory's three replies (fixed with a commit pushed after the review, not needed with evidence, or a question), as factory:execute-issue describes. Two traps worth naming here: judge whether a finding is stale by reading the file at the PR HEAD commit (gh pr view <number> --json headRefOid), NEVER your working tree, which can be ahead of the PR and hide a live finding; and "[anchor outdated]" means the diff moved, not that anyone addressed it. Every thread needs a recorded outcome — reply in-thread, then resolve — even when the fix already landed or you are declining the finding.

If a note appears on the PR saying it has NO RECORDED REVIEW, take that literally: the PR is unreviewed and needs a human, and the note is not a verdict on the diff. One cause is structural - the reviewer refuses to run at all when a PR edits .github/workflows/claude-review.yml, because a PR must not be able to edit its own reviewer.

Also note: checks that are not required by the branch ruleset (FACTORY.md lists them under ci.advisory_checks) can be red on a PR GitHub still calls mergeable. pr-cycle.sh status counts them; read any red one yourself, the failure is real.
EOF
)
# The text above is quoted so nothing in it expands; the plugin path is the one
# substitution it needs, because the Bash tool's environment has no
# CLAUDE_PLUGIN_ROOT and the agent must be handed a path it can run.
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
guidance=${guidance//'${CLAUDE_PLUGIN_ROOT}'/$root}

# The live state goes last so it is the closest thing to the model's next action.
guidance="$guidance"$'\n\n'"$review_state"

jq -cn --arg ctx "$guidance" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'

exit 0
