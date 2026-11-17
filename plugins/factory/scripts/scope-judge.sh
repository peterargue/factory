#!/usr/bin/env bash
# Judge whether a branch's diff does what its PR asked for, and nothing it didn't.
#
#   ${CLAUDE_PLUGIN_ROOT}/scripts/scope-judge.sh [--dir <worktree>] [--pr <n>] [--base <branch>]
#                                  [--issue-file <path>] [--rerun]
#   ${CLAUDE_PLUGIN_ROOT}/scripts/scope-judge.sh --accept "<why the findings are wrong or were asked for>"
#                                  [--dir <worktree>]
#
# Two passes over the diff from the merge base with origin/<base> to HEAD:
#
#   1. Deterministic: added lines that skip or narrow tests (t.Skip, it.skip,
#      describe.only, xit, @pytest.mark.skip, //go:build ignore, a workflow's
#      continue-on-error: true), deleted test files, and removed Go Test functions.
#      Code, not a prompt: a pattern either matched or it didn't.
#   2. A model judge (native `claude -p`, so it runs on the session's own Claude
#      login, never an API key) reads the request (PR title and body, the OpenSpec
#      change it names, any --issue-file) beside the diff and flags clear scope
#      creep: changes the request does not need and did not ask for.
#
# Verdict JSON goes to stdout: {"verdict":"pass"|"flag","findings":[…],"summary":…}.
# Exit 0 on pass (or an accepted flag), 1 on flag, 2 when the judge could not run.
# The ready-gate hook (${CLAUDE_PLUGIN_ROOT}/hooks/deny-unverified-ready.sh) treats 1 and 2 alike:
# not ready. A pass is cached per tree in $(git rev-parse --git-common-dir)/factory/,
# so re-marking the same tree ready does not pay for a second judgement.
#
# --accept records an override for HEAD's tree. Use it only when a finding is wrong
# or the flagged change was asked for, and put the same sentence in the PR body
# under "Scope judge" so the reviewer sees it. Disabled or deleted tests need the
# repo owner's say-so before you accept them (FACTORY.md repo.owner).
#
# Settings, from FACTORY.md's ci: block: judge_model (default sonnet).
# SCOPE_JUDGE_LLM, if set, is a command run instead of `claude -p`: it gets the
# prompt on stdin and must print the verdict JSON. The fixture test uses it.

set -uo pipefail

dir=$PWD pr="" base="" issue_file="" rerun=0 accept=""
while [ $# -gt 0 ]; do
  case $1 in
    --dir) shift; dir=${1:-} ;;
    --dir=*) dir=${1#--dir=} ;;
    --pr) shift; pr=${1:-} ;;
    --pr=*) pr=${1#--pr=} ;;
    --base) shift; base=${1:-} ;;
    --base=*) base=${1#--base=} ;;
    --issue-file) shift; issue_file=${1:-} ;;
    --issue-file=*) issue_file=${1#--issue-file=} ;;
    --rerun) rerun=1 ;;
    --accept) shift; accept=${1:-}; [ -n "$accept" ] || { echo "scope-judge: --accept needs a reason." >&2; exit 2; } ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "scope-judge: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "scope-judge: $1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "needs jq on PATH."

top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || die "$dir is not a git working copy."
common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir) || die "cannot find the git dir for $top."
tree=$(git -C "$top" rev-parse --verify --quiet 'HEAD^{tree}') || die "$top has no HEAD commit."
head=$(git -C "$top" rev-parse HEAD)
stamp="$common/factory/judge-$tree"
mkdir -p "$common/factory" || die "cannot write under $common/factory."

if [ -n "$accept" ]; then
  jq -cn --arg reason "$accept" --arg head "$head" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{verdict: "accepted", reason: $reason, head: $head, at: $at, findings: []}' > "$stamp"
  echo "scope-judge: override recorded for HEAD $head. Put this reason in the PR body under \"Scope judge\": $accept" >&2
  cat "$stamp"
  exit 0
fi

if [ "$rerun" -eq 0 ] && [ -f "$stamp" ] && jq -e '.verdict == "pass" or .verdict == "accepted"' "$stamp" >/dev/null 2>&1; then
  cat "$stamp"
  exit 0
fi

factory="$top/FACTORY.md"
# Read `  key: value` from a top-level block of the contract (block, key).
contract_value() {
  [ -f "$factory" ] || return 0
  awk -v block="$1" -v key="$2" '
    $0 ~ "^" block ":" { inblock = 1; next }
    inblock && /^[^ ]/ { inblock = 0 }
    inblock && $0 ~ "^  " key ":" {
      sub("^  " key ":[ \t]*", ""); sub("[ \t]+#.*$", ""); print; exit
    }' "$factory"
}

# --- the PR, when there is one ---------------------------------------------------
# REST, not `gh pr view`: cloud sessions refuse GitHub's GraphQL endpoint.
repo_slug=$(contract_value repo github)
if [ -z "$repo_slug" ]; then
  repo_slug=$(git -C "$top" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')
fi
pr_json=""
if command -v gh >/dev/null 2>&1 && [ -n "$repo_slug" ]; then
  if [ -n "$pr" ]; then
    pr_json=$(gh api "repos/$repo_slug/pulls/$pr" 2>/dev/null) || pr_json=""
  else
    branch=$(git -C "$top" rev-parse --abbrev-ref HEAD 2>/dev/null)
    owner=${repo_slug%%/*}
    if [ -n "$branch" ] && [ "$branch" != HEAD ]; then
      pr_json=$(gh api "repos/$repo_slug/pulls?head=$owner:$branch&state=open" --jq '.[0] // empty' 2>/dev/null) || pr_json=""
    fi
  fi
fi
if [ -n "$pr_json" ]; then
  [ -n "$base" ] || base=$(jq -r '.base.ref // empty' <<<"$pr_json")
  pr=${pr:-$(jq -r '.number // empty' <<<"$pr_json")}
fi
[ -n "$base" ] || base=$(contract_value repo default_branch)
base=${base:-main}

# Never fetch: like deny-stale-pr.sh, judge against what was last fetched.
base_rev=$(git -C "$top" rev-parse --verify --quiet "refs/remotes/origin/$base^{commit}") \
  || die "origin/$base is not a known ref in $top. Fetch it first: git fetch origin $base"
mb=$(git -C "$top" merge-base "$base_rev" HEAD 2>/dev/null) \
  || die "no merge base between HEAD and origin/$base (a shallow clone? git fetch --deepen=200 origin $base)."

# --- pass 1: deterministic ------------------------------------------------------
# Test and CI files only, so prose and these scripts' own pattern lists never match.
code_paths=('*.go' '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.py' '.github/workflows/*')
added=$(git -C "$top" diff -U0 --no-color --no-ext-diff "$mb" HEAD -- "${code_paths[@]}" | awk '
  /^\+\+\+ / { file = substr($0, 7); next }
  /^\+/ && !/^\+\+\+/ { print file "\t" substr($0, 2) }')
removed=$(git -C "$top" diff -U0 --no-color --no-ext-diff "$mb" HEAD -- '*_test.go' | awk '
  /^--- / { file = substr($0, 7); next }
  /^-func Test[A-Za-z0-9_]*\(/ { name = $2; sub(/\(.*/, "", name); print file "\t" name }')
added_tests=$(git -C "$top" diff -U0 --no-color --no-ext-diff "$mb" HEAD -- '*_test.go' | awk '
  /^\+func Test[A-Za-z0-9_]*\(/ { name = $2; sub(/\(.*/, "", name); print name }')

skip_re='\bt\.Skip(Now|f)?\(|^//go:build ignore|\b(it|test|describe|context|suite)\.(skip|only|todo)\(|\b(xit|xdescribe|xtest|fit|fdescribe)\(|@pytest\.mark\.(skip|xfail)|@unittest\.skip|continue-on-error:[[:space:]]*true'

findings='[]'
add_finding() { # kind file why
  findings=$(jq -c --arg k "$1" --arg f "$2" --arg w "$3" '. + [{kind: $k, file: $f, why: $w, source: "pattern"}]' <<<"$findings")
}
while IFS=$'\t' read -r file line; do
  [ -n "$file" ] || continue
  if printf '%s' "$line" | grep -qE "$skip_re"; then
    add_finding disabled_test "$file" "adds a line that skips or narrows tests: $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-160)"
  fi
done <<<"$added"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  add_finding disabled_test "$file" "deletes a test file"
done < <(git -C "$top" diff --name-only --diff-filter=D "$mb" HEAD | grep -E '(_test\.go|\.(test|spec)\.(ts|tsx|js|jsx|mjs)|(^|/)test_[^/]*\.py)$')
while IFS=$'\t' read -r file name; do
  [ -n "$name" ] || continue
  grep -qx "$name" <<<"$added_tests" && continue   # moved or rewritten, not removed
  add_finding disabled_test "$file" "removes test function $name"
done <<<"$removed"

# --- pass 2: the model judge ----------------------------------------------------
request=""
if [ -n "$pr_json" ]; then
  request+=$(jq -r '"PR #\(.number): \(.title)\n\n\(.body // "")"' <<<"$pr_json")
fi
change=$(jq -r '.body // ""' <<<"${pr_json:-{\}}" | grep -oE 'OpenSpec change:[[:space:]]*`?[a-z0-9-]+' | head -1 | sed -E 's/.*:[[:space:]]*`?//')
if [ -z "$change" ]; then
  change=$(git -C "$top" diff --name-only "$mb" HEAD -- openspec/changes | grep -v '/archive/' | sed -nE 's#^openspec/changes/([^/]+)/.*#\1#p' | head -1)
fi
if [ -n "$change" ] && [ -d "$top/openspec/changes/$change" ]; then
  for doc in proposal.md tasks.md; do
    f="$top/openspec/changes/$change/$doc"
    [ -f "$f" ] && request+=$'\n\n'"=== openspec/changes/$change/$doc ==="$'\n'"$(head -c 40000 "$f")"
  done
fi
if [ -n "$issue_file" ]; then
  [ -f "$issue_file" ] || die "--issue-file $issue_file does not exist."
  request+=$'\n\n'"=== issue ==="$'\n'"$(head -c 40000 "$issue_file")"
fi
if [ -z "$request" ]; then
  request="(No PR, OpenSpec change or issue text was found. Judge from the commit messages below; flag only what plainly does not belong together.)"
fi
commits=$(git -C "$top" log --format='- %s' "$mb..HEAD" | head -100)

# Generated files and lockfiles are noise to a reader and cost the most tokens.
diff_limit=150000
diff=$(git -C "$top" diff --no-color --no-ext-diff "$mb" HEAD -- . \
  ':(exclude)*package-lock.json' ':(exclude)*go.sum' ':(exclude)*.snap' ':(exclude)*/testdata/*')
diff_note=""
if [ "${#diff}" -gt "$diff_limit" ]; then
  diff="${diff:0:$diff_limit}"
  diff_note="(The diff is cut at $diff_limit characters. Judge only what you can see, and say in the summary that it was cut.)"
fi
stat=$(git -C "$top" diff --stat=200 "$mb" HEAD | tail -60)

prompt=$(cat <<EOF
You are the scope judge for a pull request. You compare what was asked for with what
the diff does. You do not review code quality, style or correctness: a separate
reviewer does that.

Flag a finding only when you are confident a reasonable reviewer would agree:
- scope_creep: a change the request neither asks for nor needs. Examples: a refactor
  of an untouched area, a new feature or endpoint nobody asked for, unrelated CI,
  config or dependency changes, reformatting of files the work did not otherwise touch.
- disabled_test: a test skipped, deleted, weakened (assertions loosened, a check
  turned advisory) or excluded from CI, unless the request asks for exactly that.
- missing_work: a part of the request the diff plainly does not attempt. Only when
  the request is explicit; tasks a later PR owns are not missing.

Not findings: tests, fixtures and docs for the requested change; small fixes inside
lines the change already touches; lint or type fixes the change forced; updates to
OpenSpec artifacts (design.md, tasks.md, proposal.md) that record the work.
When in doubt, do not flag. Verdict is "flag" if there is at least one finding,
otherwise "pass". Keep each "why" to one sentence a busy reviewer can act on.

<request>
$request
</request>

<commits>
$commits
</commits>

<diffstat>
$stat
</diffstat>

$diff_note
<diff>
$diff
</diff>
EOF
)

schema='{"type":"object","additionalProperties":false,"required":["verdict","findings","summary"],"properties":{"verdict":{"type":"string","enum":["pass","flag"]},"summary":{"type":"string"},"findings":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["kind","file","why"],"properties":{"kind":{"type":"string","enum":["scope_creep","disabled_test","missing_work"]},"file":{"type":"string"},"why":{"type":"string"}}}}}}'

model=$(contract_value ci judge_model)
model=${model:-sonnet}

if [ -n "${SCOPE_JUDGE_LLM:-}" ]; then
  verdict=$(printf '%s' "$prompt" | bash -c "$SCOPE_JUDGE_LLM" 2>/dev/null) || verdict=""
else
  command -v claude >/dev/null 2>&1 || die "needs the claude CLI on PATH for the model judge."
  # No tools, no settings, run outside the repo: the judge reads only what it is
  # given, and loads no project hooks, CLAUDE.md or plugins of its own.
  raw=$(cd "${TMPDIR:-/tmp}" && printf '%s' "$prompt" | timeout 240 claude -p \
    --model "$model" --output-format json --json-schema "$schema" \
    --tools "" --setting-sources "" --no-session-persistence --disable-slash-commands 2>/dev/null) || raw=""
  verdict=$(jq -c '.structured_output // empty' <<<"$raw" 2>/dev/null)
fi
jq -e '(.verdict == "pass" or .verdict == "flag") and (.findings | type == "array")' <<<"$verdict" >/dev/null 2>&1 \
  || die "the model judge returned no usable verdict (model $model). Run it again; if it keeps failing, record why the PR is in scope with --accept."

result=$(jq -c --argjson pattern "$findings" --arg head "$head" --arg base "$base" --arg pr "$pr" '
  .findings = ($pattern + (.findings | map(. + {source: "judge"})))
  | .verdict = (if (.findings | length) > 0 then "flag" else "pass" end)
  | . + {head: $head, base: $base, pr: $pr}' <<<"$verdict")

printf '%s\n' "$result" > "$stamp"
printf '%s\n' "$result"
jq -e '.verdict == "pass"' <<<"$result" >/dev/null
