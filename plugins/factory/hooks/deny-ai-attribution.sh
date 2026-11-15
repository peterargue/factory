#!/usr/bin/env bash
# PreToolUse:Bash hook — blocks git commits, PRs, and issues that carry a
# Claude Code AI-attribution phrase ("Generated with Claude Code",
# "Co-Authored-By: Claude", "in collaboration with Claude", etc.).
# Reads the hook payload on stdin and, on a match, emits a PreToolUse deny.

# The plugin can be enabled at user scope, so this hook fires in every project.
# It acts only in a repository that has joined the factory.
[ -f "${CLAUDE_PROJECT_DIR:-.}/FACTORY.md" ] || exit 0
# Attribution is a per-repo choice: FACTORY.md opts in with `ai_attribution: deny`.
grep -qE '^[[:space:]]*ai_attribution:[[:space:]]*deny' "${CLAUDE_PROJECT_DIR:-.}/FACTORY.md" || exit 0

cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null)

# Only inspect commands that publish text: commits, PRs, issues (create/edit).
case $cmd in
  *"git commit"*|*"gh pr create"*|*"gh pr edit"*|*"gh issue create"*|*"gh issue edit"*) ;;
  *) exit 0 ;;
esac

# Bodies usually arrive by path, not inline: the repo's own skills prescribe
# `gh pr create --body-file`, and `git commit -F` is common. Scanning only the
# command string would miss all of them, so fold in the contents of any file
# passed via --body-file / --file / -F.
#
# Known residual gaps, not detectable from the command string alone:
# `git commit --amend --no-edit` (reuses a stored message), `gh pr create --fill`
# (derives the body from commits), and text piped in on stdin or via a heredoc.
scan=$cmd
for path in $(printf '%s' "$cmd" | grep -oE '(--body-file|--file|-F)[=[:space:]]+[^[:space:]"'"'"']+' | sed -E 's/^(--body-file|--file|-F)[=[:space:]]+//'); do
  [ -f "$path" ] && scan=$scan$(printf '\n%s' "$(< "$path")")
done

# Case-insensitive scan for known AI-attribution phrases.
if printf '%s' "$scan" | grep -qiE 'generated with claude|co-?authored-by:?[[:space:]]*claude|in collaboration with claude|claude\.com/claude-code|noreply@anthropic\.com'; then
  printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"This commit/PR/issue text contains a Claude Code AI-attribution phrase (e.g. Generated with Claude Code, Co-Authored-By: Claude, in collaboration with Claude). Remove the attribution line(s) and retry without any AI-generated/co-authored statement."}}'
fi

exit 0
