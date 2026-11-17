#!/usr/bin/env bash
# Fixture-test the ready gate: the plugin's hooks/deny-unverified-ready.sh with the real
# gate-stamp.sh and scope-judge.sh, in a throwaway repo with its own origin. Real
# git and jq. Two stubs, both outside the logic under test: `gh` (no network; it
# reports no PR) and the model judge (SCOPE_JUDGE_LLM), whose verdict each case sets.
#
#   tests/check-deny-unverified-ready.sh

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../plugins/factory" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0 failed=0

# --- fixture repo -----------------------------------------------------------------
mkdir -p "$work/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$work/bin/gh"; chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

git init -q --bare "$work/origin.git"
git init -q -b main "$work/repo"
repo="$work/repo"
# The hook finds its scripts beside it, as in the installed plugin.
plugin="$work/plugin"
mkdir -p "$plugin/hooks" "$plugin/scripts" "$repo/src"
cp "$here/hooks/deny-unverified-ready.sh" "$plugin/hooks/"
cp "$here/scripts/gate-stamp.sh" "$here/scripts/scope-judge.sh" "$plugin/scripts/"
export CLAUDE_PROJECT_DIR="$repo"
cat > "$repo/FACTORY.md" <<'EOF'
```yaml
repo:
  default_branch: main
commands:
  cwd: src/
  gate: test ! -e ../GATE_FAILS   # fixture gate
ci:
  judge_model: haiku
```
EOF
printf 'package app\n\nfunc TestKeep(t *testing.T) {}\nfunc TestGone(t *testing.T) {}\n' > "$repo/src/app_test.go"
git -C "$repo" add -A && git -C "$repo" commit -qm init
git -C "$repo" remote add origin "$work/origin.git"
git -C "$repo" push -q origin main 2>/dev/null
git -C "$repo" checkout -q -b work
echo 'feature' > "$repo/src/feature.txt"
git -C "$repo" add -A && git -C "$repo" commit -qm 'feat: the asked-for change'

hook="$plugin/hooks/deny-unverified-ready.sh"
pass_llm='cat >/dev/null; echo "{\"verdict\":\"pass\",\"findings\":[],\"summary\":\"in scope\"}"'
flag_llm='cat >/dev/null; echo "{\"verdict\":\"flag\",\"findings\":[{\"kind\":\"scope_creep\",\"file\":\"x\",\"why\":\"unrelated\"}],\"summary\":\"creep\"}"'
export SCOPE_JUDGE_LLM=$pass_llm

bash_call() { jq -cn --arg cwd "$repo" --arg c "$1" '{cwd: $cwd, tool_name: "Bash", tool_input: {command: $c}}'; }
mcp_call() { jq -cn --arg cwd "$repo" --argjson d "$1" '{cwd: $cwd, tool_name: "mcp__github__update_pull_request", tool_input: {owner: "o", repo: "r", pullNumber: 5, draft: $d}}'; }
clear_stamps() { rm -rf "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/factory"; }

# expect <name> deny|allow <payload> [reason substring]
expect() {
  local name=$1 want=$2 out got
  out=$(printf '%s' "$3" | "$hook" 2>&1)
  if grep -q '"permissionDecision":"deny"' <<<"$out"; then got=deny; else got=allow; fi
  if [ "$got" = "$want" ] && { [ -z "$out" ] || jq -e . >/dev/null 2>&1 <<<"$out"; } \
     && { [ -z "${4:-}" ] || grep -qF -- "$4" <<<"$out"; }; then
    echo "ok   $name"; passed=$((passed + 1))
  else
    echo "FAIL $name: got $got, want $want${4:+ (with \"$4\")}"; sed 's/^/    /' <<<"$out"; failed=$((failed + 1))
  fi
}
# expect_rc <name> <want rc> <cmd…>
expect_rc() {
  local name=$1 want=$2 rc; shift 2
  "$@" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "$want" ]; then echo "ok   $name"; passed=$((passed + 1))
  else echo "FAIL $name: exit $rc, want $want"; failed=$((failed + 1)); fi
}

# --- commands it ignores ----------------------------------------------------------
expect "an unrelated command passes" allow "$(bash_call 'git status')"
mkdir -p "$work/elsewhere"
CLAUDE_PROJECT_DIR="$work/elsewhere" expect "a repo that has not joined the factory is left alone" allow "$(bash_call 'gh pr ready 12')"
expect "gh pr ready --undo passes" allow "$(bash_call 'gh pr ready 12 --undo')"
expect "convert_to_draft passes" allow "$(bash_call 'gh api -X POST repos/o/r/pulls/12/ccr/convert_to_draft')"
expect "update_pull_request without draft passes" allow "$(jq -cn --arg cwd "$repo" '{cwd: $cwd, tool_name: "mcp__github__update_pull_request", tool_input: {pullNumber: 5, title: "x"}}')"
expect "update_pull_request draft:true passes" allow "$(mcp_call true)"
expect "pr-cycle.sh open passes" allow "$(bash_call '"$CLAUDE_PLUGIN_ROOT"/scripts/pr-cycle.sh open')"

# --- no stamp: every ready route is refused ---------------------------------------
clear_stamps
expect "gh pr ready without a stamp is refused" deny "$(bash_call 'gh pr ready 12')" "gate-stamp.sh"
expect "ccr/ready_for_review without a stamp is refused" deny "$(bash_call 'gh api -X POST repos/o/r/pulls/12/ccr/ready_for_review')"
expect "graphql markPullRequestReadyForReview is refused" deny "$(bash_call "gh api graphql -f query='mutation { markPullRequestReadyForReview(input:{}) { clientMutationId } }'")"
expect "pr-cycle.sh ready is refused" deny "$(bash_call '"$CLAUDE_PLUGIN_ROOT"/scripts/pr-cycle.sh ready 12')"
expect "pr-cycle.sh ship is refused" deny "$(bash_call '"$CLAUDE_PLUGIN_ROOT"/scripts/pr-cycle.sh ship')"
expect "update_pull_request draft:false is refused" deny "$(mcp_call false)"
expect "a directory that is not a repo is refused" deny "$(jq -cn --arg c 'gh pr ready' --arg cwd "$work/bin" '{cwd: $cwd, tool_input: {command: $c}}')" "not a git working copy"

# --- the gate ---------------------------------------------------------------------
touch "$repo/GATE_FAILS"
expect_rc "a red gate exits non-zero" 1 "$plugin/scripts/gate-stamp.sh" --dir "$repo"
expect_rc "and writes no stamp" 1 "$plugin/scripts/gate-stamp.sh" --check --dir "$repo"
rm "$repo/GATE_FAILS"
expect_rc "a green gate exits 0" 0 "$plugin/scripts/gate-stamp.sh" --dir "$repo"
expect_rc "and --check then passes" 0 "$plugin/scripts/gate-stamp.sh" --check --dir "$repo"
expect "gh pr ready with a stamp and a passing judge is allowed" allow "$(bash_call 'gh pr ready 12')"
expect "a leading cd into the repo is honoured" allow "$(jq -cn --arg c "cd $repo && gh pr ready" --arg cwd "$work/bin" '{cwd: $cwd, tool_input: {command: $c}}')"

echo dirty >> "$repo/src/feature.txt"
expect "uncommitted tracked edits are refused" deny "$(bash_call 'gh pr ready')" "uncommitted"
expect_rc "and the gate will not stamp over them" 1 "$plugin/scripts/gate-stamp.sh" --record --dir "$repo"
git -C "$repo" checkout -q -- src/feature.txt

echo more > "$repo/src/more.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm 'feat: more'
expect "a new commit needs a new gate" deny "$(bash_call 'gh pr ready')" "has not passed on this exact commit"
expect_rc "--record stamps without running the gate" 0 "$plugin/scripts/gate-stamp.sh" --record --dir "$repo"

# A worktree whose HEAD has the same tree shares the stamp.
git -C "$repo" worktree add -q "$work/wt" HEAD 2>/dev/null
expect_rc "a stamp counts in another worktree at the same tree" 0 "$plugin/scripts/gate-stamp.sh" --check --dir "$work/wt"

# --- the scope judge --------------------------------------------------------------
clear_stamps; "$plugin/scripts/gate-stamp.sh" --record --dir "$repo" 2>/dev/null
export SCOPE_JUDGE_LLM=$flag_llm
expect "a judge flag is refused with its finding" deny "$(bash_call 'gh pr ready')" "[scope_creep] x: unrelated"
export SCOPE_JUDGE_LLM='cat >/dev/null; echo not-json'
expect "a judge that returns garbage is refused" deny "$(bash_call 'gh pr ready')" "could not run"
export SCOPE_JUDGE_LLM=$flag_llm
"$plugin/scripts/scope-judge.sh" --dir "$repo" --accept "the issue asks for x" >/dev/null 2>&1
expect "an accepted flag is allowed" allow "$(bash_call 'gh pr ready')"

export SCOPE_JUDGE_LLM=$pass_llm
add_case() { # name file content
  clear_stamps
  mkdir -p "$repo/$(dirname "$2")"; printf '%s\n' "$3" > "$repo/$2"
  git -C "$repo" add -A; git -C "$repo" commit -qm "case: $1"
  "$plugin/scripts/gate-stamp.sh" --record --dir "$repo" 2>/dev/null
  expect "$1 is flagged even when the model passes" deny "$(bash_call 'gh pr ready')" "[disabled_test]"
  git -C "$repo" reset -q --hard HEAD~1
}
add_case "a Go t.Skip" src/skip_test.go $'package app\nfunc TestX(t *testing.T) { t.Skip("later") }'
add_case "an it.skip" src/web/a.test.ts "it.skip('works', () => {})"
add_case "a describe.only" src/web/b.test.ts "describe.only('suite', () => {})"
add_case "a workflow continue-on-error" .github/workflows/ci.yml $'jobs:\n  t:\n    continue-on-error: true'

clear_stamps
printf 'package app\n\nfunc TestKeep(t *testing.T) {}\n' > "$repo/src/app_test.go"
git -C "$repo" commit -qam 'drop a test'; "$plugin/scripts/gate-stamp.sh" --record --dir "$repo" 2>/dev/null
expect "a removed Go test function is flagged" deny "$(bash_call 'gh pr ready')" "removes test function TestGone"
git -C "$repo" reset -q --hard HEAD~1

clear_stamps
git -C "$repo" rm -q src/app_test.go; git -C "$repo" commit -qm 'drop file'
"$plugin/scripts/gate-stamp.sh" --record --dir "$repo" 2>/dev/null
expect "a deleted test file is flagged" deny "$(bash_call 'gh pr ready')" "deletes a test file"
git -C "$repo" reset -q --hard HEAD~1

clear_stamps
printf '# notes\nit.skip( is how you skip a vitest\n' > "$repo/NOTES.md"
git -C "$repo" add -A; git -C "$repo" commit -qm 'docs'
"$plugin/scripts/gate-stamp.sh" --record --dir "$repo" 2>/dev/null
expect "a skip pattern in prose is not a finding" allow "$(bash_call 'gh pr ready')"

echo "check-deny-unverified-ready: $passed passed, $failed failed."
[ "$failed" -eq 0 ]
