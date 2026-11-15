#!/usr/bin/env bash
# PreToolUse hook — denies `gh pr create` when the branch the pull request is
# actually for is behind the branch it actually targets. It also runs on the
# GitHub MCP connector's create_pull_request tool, which opens a PR without any
# Bash command: matching Bash alone let a stale PR through that way. For that
# tool the head and base come from the tool's own arguments, and since the
# connector pushes nothing, origin/<head> is always the ref judged.
#
# Four deliberate properties, all load-bearing:
#
#   * Base-aware. It compares the head branch against `origin/<base>`, where
#     <base> is parsed from the command (`--base X`, `--base=X`, `-B X`, `-BX`,
#     `-B=X`) and defaults to `main`. An issue branch cut from a current feature
#     branch is therefore permitted even after `main` moves — the base-blind
#     version denied that, which is confusing rather than actionable. The
#     property the base-blind version did buy is not lost: a `feature/*` branch
#     opening a PR onto `main` is measured against `main` like anything else, so
#     it still cannot open its umbrella PR while behind.
#
#   * It judges the working copy the command will run in, taken from the payload's
#     `cwd`, NOT the directory this hook process happens to start in. Those differ
#     whenever a subagent or another worktree issues the command, and the process
#     cwd was measuring an unrelated checkout: a branch provably 0 commits behind
#     its base was denied three times in one sitting because a different worktree
#     in the same session was 11 behind. Worktrees share one ref store, so only
#     HEAD is per-worktree — reading it from the right directory is the whole fix.
#     Every `cd`/`pushd` earlier in the same command is replayed in order too, since
#     the payload's cwd predates them. `--head <branch>` beats both: it names the
#     branch outright.
#
#   * It measures the ref the pull request will actually open from, which is
#     `origin/<head>` — `gh pr create` pushes nothing on your behalf. Measuring the
#     local branch let through anything that had merged the base but not pushed: 0
#     behind locally, still behind on the remote, and the PR that opened was stale.
#     The exception is a command that pushes before it creates; there the local
#     commits are the ones that land, so the local ref is judged instead.
#
#   * It reads the last-fetched remote-tracking ref and never fetches. A stale
#     remote-tracking ref makes the check wrong in both directions, so fetch
#     before relying on it.
#
#   * It fails closed. Anything that leaves the answer unknown — an unfetched or
#     misspelled base, an unresolvable head, a directory that is not a work tree,
#     no jq — denies and says what to do. The previous `|| echo 0` turned every
#     such case into a silent allow, and a guard whose failure mode is permission
#     is worse than one that is occasionally annoying.
#
# Matches on a substring, so a command that merely *mentions* the create command
# also trips it. Exits 0 on every path, allow and deny alike: a PreToolUse hook
# exiting non-zero is reported as a hook error even when it permits the call.
#
# Test it by piping a payload on stdin:
#   printf '%s' '{"cwd":"/path/to/worktree","tool_input":{"command":"gh pr …"}}' \
#     | .claude/hooks/deny-stale-pr.sh
#   printf '%s' '{"cwd":"…","tool_name":"mcp__github__create_pull_request","tool_input":{"head":"x","base":"main"}}' \
#     | .claude/hooks/deny-stale-pr.sh

# The plugin can be enabled at user scope, so this hook fires in every project.
# It acts only in a repository that has joined the factory.
[ -f "${CLAUDE_PROJECT_DIR:-.}/FACTORY.md" ] || exit 0

payload=$(cat)

# Emit a deny decision and stop. Every exit here is 0 by design.
deny() {
  jq -cn --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

# Without jq nothing can be parsed, so match the raw payload and deny rather than
# waving the command through. The JSON is inlined because jq is what is missing.
if ! command -v jq >/dev/null 2>&1; then
  case $payload in
    *"gh pr create"*)
      printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"deny-stale-pr.sh needs jq on PATH to check whether this branch is behind its base. Install jq, or check by hand with: git rev-list --count HEAD..origin/<base>"}}'
      ;;
  esac
  exit 0
fi

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)

# A connector call carries head and base as arguments. Rewriting it as the
# equivalent `gh pr create --head H --base B` lets the one parser and the one
# set of checks below judge both paths, so they cannot drift apart. The
# arguments are re-quoted with jq's @sh, so a value cannot inject a token.
case $tool in
  mcp__*github*__create_pull_request)
    cmd=$(printf '%s' "$payload" | jq -r '"gh pr create --head \(.tool_input.head // "" | @sh) --base \(.tool_input.base // "" | @sh)"' 2>/dev/null)
    if [ -z "$(printf '%s' "$payload" | jq -r '.tool_input.head // empty' 2>/dev/null)" ]; then
      deny "Cannot check staleness: the create_pull_request call names no head branch, so there is nothing to compare against its base."
    fi
    ;;
esac

case $cmd in
  *"gh pr create"*) ;;
  *) exit 0 ;;
esac

# --- tokenise -----------------------------------------------------------------
# Quote-aware, so that a --base mentioned inside a quoted --body is text and not a
# flag, while a quoted base value is still read. Nothing is evaluated: the command
# string is never executed, expanded or sourced here - only read as characters.
#
# Newlines reach awk intact (RS is a byte the input cannot contain), because a
# backslash-newline is a line continuation and must vanish, whereas a bare newline
# separates tokens. Folding newlines to spaces beforehand conflated the two: the
# continuation in
#     gh pr create \
#     --base feature/x
# became `\` + space, the escape branch ate the space as an escaped character, and
# the token emerged as " --base" - matching no flag, so the base silently fell back
# to main and staleness was measured against the wrong branch.
#
# A newline inside quotes becomes a space so every emitted token stays on one line;
# the reader below is line-based and would re-split a multi-line token.
tokenize() {
  printf '%s' "$1" | awk '
BEGIN { RS = "\034"; SQ = sprintf("%c", 39) }
{
  n = length($0); tok = ""; has = 0; q = ""
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (q == "") {
      if (c == SQ || c == "\"") { q = c; has = 1; continue }
      if (c == "\\") {
        i++
        if (i <= n && substr($0, i, 1) != "\n") { tok = tok substr($0, i, 1); has = 1 }
        continue
      }
      if (c == " " || c == "\t" || c == "\n") { if (has) print tok; tok = ""; has = 0; continue }
      tok = tok c; has = 1
    } else {
      if (c == q) { q = ""; continue }
      if (q == "\"" && c == "\\") {
        i++
        if (i <= n && substr($0, i, 1) != "\n") { tok = tok substr($0, i, 1) }
        continue
      }
      if (c == "\n") { tok = tok " "; continue }
      tok = tok c
    }
  }
  if (has) print tok
}'
}

# --- which working copy -------------------------------------------------------
# The payload's cwd is where the Bash tool will run the command, which is the
# directory a previous `cd` left it in. A `cd` inside *this* command runs before
# gh does, though, and the payload cannot know about it - so replay every `cd` and
# `pushd` appearing before the create command, in order, each against the running
# directory. Keeping only the last one was wrong: `cd src && cd ..` returns the
# shell to where it started, but resolving just `..` against the payload's cwd
# lands a level above it - a false deny, or a false allow onto a sibling worktree.
#
# Not modelled, and documented as such: a `cd` in a subshell, `popd`, `pushd -n`,
# and a path built from a variable. Those leave the running directory untouched.
dir=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  dir=${CLAUDE_PROJECT_DIR:-$PWD}
fi

oldd=$dir
prev=""
while IFS= read -r tok; do
  case $prev in
    cd|pushd)
      cand=""
      case $tok in
        '-')  cand=$oldd ;;                        # cd - returns to the previous dir
        ''|-*|'&&'|'||'|';'|'|'|'|&') ;;           # cd with no usable argument
        /*)   cand=$tok ;;
        *)    cand="$dir/$tok" ;;
      esac
      if [ -n "$cand" ] && [ -d "$cand" ]; then
        oldd=$dir
        dir=$cand
      fi
      ;;
  esac
  prev=$tok
done <<EOF
$(tokenize "${cmd%%gh pr create*}")
EOF

# Collapse any .. segments so the deny message names a readable path.
dir=$(cd -- "$dir" 2>/dev/null && pwd -P) || dir=${CLAUDE_PROJECT_DIR:-$PWD}

if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  deny "Cannot check staleness: $dir is not a git working copy, so the branch this PR is for cannot be determined. Run the command from the repository the pull request is for."
fi

# --- parse the create command -------------------------------------------------
base=""
head_branch=""
want=""
while IFS= read -r tok; do
  case $want in
    base) base=$tok; want=""; continue ;;
    head) head_branch=$tok; want=""; continue ;;
  esac
  case $tok in
    # A shell operator ends the create command; anything after it is another one.
    '&&'|'||'|';'|'|'|'|&') break ;;
    --base=*) base=${tok#--base=} ;;
    --base)   want=base ;;
    -B=*)     base=${tok#-B=} ;;
    -B)       want=base ;;
    -B?*)     base=${tok#-B} ;;
    --head=*) head_branch=${tok#--head=} ;;
    --head)   want=head ;;
    -H=*)     head_branch=${tok#-H=} ;;
    -H)       want=head ;;
    -H?*)     head_branch=${tok#-H} ;;
  esac
done <<EOF
$(tokenize "${cmd#*gh pr create}")
EOF

base=${base:-main}

# --- resolve the two ends -----------------------------------------------------
# `gh pr create` does not push on your behalf: the pull request is opened from
# whatever origin/<head> points at right now. So the REMOTE ref is what decides
# whether the PR will be stale, not the local branch. Measuring the local ref let
# a branch through whenever it had merged the base in but not pushed - it read 0
# behind while the pull request that actually opened was still behind. That is the
# same fail-open this guard exists to close, just from the other side.
#
# The exception is a command that pushes before it creates: there the local commits
# become the remote ones, so the local ref is what the PR will contain.
case ${cmd%%gh pr create*} in
  *"git push"*) pushes_first=yes ;;
  *)            pushes_first=no ;;
esac

if [ -n "$head_branch" ]; then
  head_branch=${head_branch#*:}   # gh accepts owner:branch; refnames cannot contain ':'
  head_label=$head_branch
else
  head_label=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  head_branch=$head_label
  if [ -z "$head_branch" ] || [ "$head_branch" = HEAD ]; then
    # Detached HEAD: there is no branch name to look up on the remote, and gh
    # cannot open a PR from one either.
    deny "Cannot check staleness: $dir is not on a named branch (detached HEAD), so the branch this PR would be opened from cannot be determined."
  fi
fi

remote_rev=$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$head_branch^{commit}" 2>/dev/null)
local_rev=$(git -C "$dir" rev-parse --verify --quiet "refs/heads/$head_branch^{commit}" 2>/dev/null)

if [ "$pushes_first" = yes ] && [ -n "$local_rev" ]; then
  head_rev=$local_rev
  head_desc="$head_label (local, being pushed by this command)"
elif [ -n "$remote_rev" ]; then
  head_rev=$remote_rev
  head_desc="origin/$head_label"
elif [ -n "$local_rev" ]; then
  # No remote ref at all: gh cannot open a PR from this branch until it is pushed,
  # and when it is, the local commits are what lands. Judge those.
  head_rev=$local_rev
  head_desc="$head_label (local; not yet on origin)"
else
  deny "Cannot check staleness: '$head_label' is not a known local or origin ref in $dir, so there is nothing to compare against origin/$base. Push that branch first."
fi

base_rev=$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$base^{commit}" 2>/dev/null)
if [ -z "$base_rev" ]; then
  deny "Cannot check staleness: origin/$base is not a known ref in $dir, so it is unknown whether ${head_label:-this branch} is behind it. Fetch it first: git fetch origin $base - then open the PR. (Check the base spelling if the fetch does not create it.)"
fi

behind=$(git -C "$dir" rev-list --count "$head_rev..$base_rev" 2>/dev/null)
case $behind in
  ''|*[!0-9]*)
    deny "Cannot check staleness: could not count commits between ${head_label:-HEAD} and origin/$base in $dir. Resolve that before opening the PR."
    ;;
esac

[ "$behind" -gt 0 ] || exit 0

# --- deny, naming the remedy --------------------------------------------------
# head_desc names the ref actually measured, so "origin/x is behind" cannot be
# misread as a claim about the local branch - they are often not the same commit.
remedy="$head_desc is $behind commit(s) behind origin/$base, the branch this PR targets. The pull request opens from origin/$head_label, so merge the base in and push before opening it:

  git fetch origin $base
  git merge origin/$base
  git push

Resolve any conflicts and re-run the build and tests before pushing."

case $base in
  main) ;;
  *) remedy="$remedy

Note this checks the base you named, not main. Make sure origin/$base is itself merged up with main before you merge it down here, or you will do the same merge twice - see .claude/skills/implement-feature." ;;
esac

deny "$remedy"
