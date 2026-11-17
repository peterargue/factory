#!/usr/bin/env bash
# Run the repo gate and stamp the tree it passed on, or check for that stamp.
#
#   ${CLAUDE_PLUGIN_ROOT}/scripts/gate-stamp.sh [--dir <worktree>]           run the gate; stamp on green
#   ${CLAUDE_PLUGIN_ROOT}/scripts/gate-stamp.sh --record [--dir <worktree>]  stamp only, after your own green run
#   ${CLAUDE_PLUGIN_ROOT}/scripts/gate-stamp.sh --check [--dir <worktree>]   exit 0 if HEAD's tree is stamped
#
# The gate is FACTORY.md's `commands.gate`, run from `commands.cwd`. A stamp is the
# file $(git rev-parse --git-common-dir)/factory/gate-<tree sha>, where the tree is
# HEAD^{tree}. Keying by tree in the shared git dir means a gate run in any worktree
# counts for every worktree whose HEAD has the same content, which is what an
# orchestrator gating a delegate's branch from its own checkout needs.
#
# A stamp is only written, and --check only passes, when tracked files match HEAD:
# a gate run over uncommitted edits proves nothing about the commit that ships.
# Untracked files are ignored; they are not in the PR.
#
# The ready-gate hook (${CLAUDE_PLUGIN_ROOT}/hooks/deny-unverified-ready.sh) refuses to mark a PR
# ready without a stamp, and ${CLAUDE_PLUGIN_ROOT}/scripts/pr-cycle.sh calls this script. Exit
# codes: the gate's own exit when running it; 0/1 for --record and --check; 2 for
# usage or setup errors. Reasons go to stderr.

set -uo pipefail

mode=run
dir=${PWD}
while [ $# -gt 0 ]; do
  case $1 in
    --record) mode=record ;;
    --check) mode=check ;;
    --dir) shift; dir=${1:-} ;;
    --dir=*) dir=${1#--dir=} ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "gate-stamp: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || {
  echo "gate-stamp: $dir is not a git working copy." >&2; exit 2; }
common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
  echo "gate-stamp: cannot find the git dir for $top." >&2; exit 2; }
tree=$(git -C "$top" rev-parse --verify --quiet 'HEAD^{tree}') || {
  echo "gate-stamp: $top has no HEAD commit." >&2; exit 2; }
head=$(git -C "$top" rev-parse HEAD)
stamp="$common/factory/gate-$tree"

# 0 when tracked files (staged or not) match HEAD.
clean() {
  git -C "$top" diff --quiet HEAD -- 2>/dev/null
}

if ! clean; then
  echo "gate-stamp: $top has uncommitted changes to tracked files. Commit or stash them first: a gate over a dirty tree says nothing about HEAD ($head)." >&2
  exit 1
fi

write_stamp() {
  mkdir -p "$common/factory" || return 1
  printf '%s %s %s %s\n' "$tree" "$head" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:-recorded}" > "$stamp"
}

case $mode in
  check)
    if [ -f "$stamp" ]; then exit 0; fi
    echo "gate-stamp: no green gate recorded for HEAD $head (tree $tree) in $top. Run $0 there; it runs the FACTORY.md gate and stamps on green." >&2
    exit 1
    ;;
  record)
    write_stamp recorded || { echo "gate-stamp: could not write $stamp" >&2; exit 2; }
    echo "gate-stamp: recorded a green gate for HEAD $head (tree $tree)." >&2
    exit 0
    ;;
esac

# --- run the gate ---------------------------------------------------------------
factory="$top/FACTORY.md"
[ -f "$factory" ] || { echo "gate-stamp: $factory not found; it names the gate command." >&2; exit 2; }

# Read a `  key: value   # comment` line from the commands: block of the contract.
contract_value() {
  awk -v key="$1" '
    /^commands:/ { inblock = 1; next }
    inblock && /^[^ ]/ { inblock = 0 }
    inblock && $0 ~ "^  " key ":" {
      sub("^  " key ":[ \t]*", ""); sub("[ \t]+#.*$", ""); print; exit
    }' "$factory"
}

gate=$(contract_value gate)
cwd=$(contract_value cwd)
[ -n "$gate" ] || { echo "gate-stamp: FACTORY.md has no commands.gate." >&2; exit 2; }
cwd=${cwd%/}
run_dir="$top/${cwd:-.}"
[ -d "$run_dir" ] || { echo "gate-stamp: commands.cwd '$cwd' is not a directory under $top." >&2; exit 2; }

echo "gate-stamp: running '$gate' in $run_dir for HEAD $head" >&2
(cd "$run_dir" && bash -c "$gate")
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "gate-stamp: gate failed (exit $rc); nothing stamped." >&2
  exit "$rc"
fi

# The gate must not have changed tracked files (a formatter, a regenerated file):
# then what passed is not HEAD.
if ! clean; then
  echo "gate-stamp: the gate passed but changed tracked files; commit them and run it again. Nothing stamped." >&2
  exit 1
fi

write_stamp "$gate" || { echo "gate-stamp: could not write $stamp" >&2; exit 2; }
echo "gate-stamp: green; stamped HEAD $head (tree $tree)." >&2
exit 0
